"""Orchestrates journal Fast Path + Slow Path with full pipeline tracing."""

from __future__ import annotations

import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

from . import crud
from .audio_trim import TrimReport, trim_audio_file
from .config import get_settings
from .db import async_session_factory
from .journal_pipeline import (
    apply_cleaned_text_to_segments,
    build_cleanup_only_system_prompt,
    cleanup_only,
    gate_source_type,
    transcribe_audio,
)
from .pipeline_trace import PipelineTracer
from .speaker_diarization import diarize_audio, segments_to_labeled_transcript
from .speaker_profiles import process_entry_speaker_profiles
from .storage import local_path, save_audio


async def run_journal_fast_pipeline(
    session: AsyncSession,
    user_id: uuid.UUID,
    file_bytes: bytes,
    filename: str,
    source_type: str | None = None,
) -> tuple[object, dict]:
    """Audio → STT → translate. Returns quickly with status=ready."""
    entry = await crud.create_journal_entry(session, user_id, audio_url=None)
    if source_type:
        # Dedicated column — the tracer overwrites pipeline_trace later.
        entry = await crud.update_journal_entry(
            session, entry, source_type=source_type
        )
    tracer = PipelineTracer(entry.id)

    step = tracer.begin_step(
        "audio_ingest",
        "storage",
        phase="fast_path",
        input_data={"filename": filename, "size_bytes": len(file_bytes)},
    )
    try:
        audio_key = await save_audio(file_bytes, filename, user_id)
        path = local_path(audio_key)
        art = tracer.save_audio_bytes(file_bytes, filename)
        tracer.finish_step(
            step,
            output={
                "storage_key": audio_key,
                "absolute_path": str(path.resolve()),
                "debug_copy": art.relative_path,
                "size_bytes": len(file_bytes),
                "estimated_duration_sec": round(len(file_bytes) / 32000, 1)
                if filename.endswith(".wav")
                else None,
            },
            artifacts=[
                (
                    "metadata.json",
                    {"storage_key": audio_key, "path": str(path)},
                    "application/json",
                )
            ],
        )
        await crud.update_journal_entry(session, entry, audio_url=audio_key)
    except Exception as exc:
        tracer.finish_step(step, error=str(exc))
        trace = tracer.finish("failed")
        await crud.update_journal_entry(
            session,
            entry,
            status="failed",
            pipeline_trace=trace,
            debug_run_dir=tracer.debug_dir_relative,
        )
        raise

    settings = get_settings()
    skip_trim = (
        not settings.audio_trim_enabled
        or (
            settings.audio_trim_skip_when_diarization
            and settings.speaker_diarization_enabled
            and bool(settings.deepgram_api_key or settings.pyannote_hf_token)
        )
    )
    skip_reason = (
        "disabled"
        if not settings.audio_trim_enabled
        else "skipped_for_diarization"
    )

    step = tracer.begin_step(
        "audio_vad_trim",
        "transform",
        phase="fast_path",
        input_data={
            "source": str(path.resolve()),
            "skip_trim": skip_trim,
            "diarization_enabled": settings.speaker_diarization_enabled,
            "has_diarization_provider": bool(
                settings.deepgram_api_key or settings.pyannote_hf_token
            ),
            "note": "Skipped when Deepgram/pyannote enabled; else conservative edge trim only",
        },
    )
    trim_dir = tracer.root / "audio"
    stt_path = path
    try:
        if skip_trim:
            trim_report = TrimReport(
                applied=False,
                source_path=str(path.resolve()),
                output_path=str(path.resolve()),
                original_duration_sec=0,
                trimmed_duration_sec=0,
                saved_sec=0,
                saved_ratio=0,
                segment_count=0,
                segments_sec=[],
                reason=skip_reason,
            )
            trim_dict = trim_report.to_dict()
            tracer.finish_step(
                step,
                output=trim_dict,
                artifacts=[("trim_report.json", trim_dict, "application/json")],
            )
        else:
            stt_path, trim_report = trim_audio_file(path, output_dir=trim_dir)
            trim_dict = trim_report.to_dict()
            artifacts: list[tuple[str, str | dict | bytes, str]] = [
                ("trim_report.json", trim_dict, "application/json"),
            ]
            if trim_report.applied and stt_path != path:
                artifacts.append(("trimmed.wav", stt_path.read_bytes(), "audio/wav"))
            tracer.finish_step(step, output=trim_dict, artifacts=artifacts)
    except Exception as exc:
        tracer.finish_step(step, error=str(exc), output={"fallback": str(path)})
        stt_path = path

    transcript_segments: list | None = None
    diarize_step = tracer.begin_step(
        "speaker_diarize",
        "transform",
        phase="fast_path",
        input_data={
            "audio_path": str(stt_path.resolve()),
            "enabled": get_settings().speaker_diarization_enabled,
        },
    )
    diarized_text: str | None = None
    refine_meta: dict = {}
    diarize_provider: str = "disabled"
    try:
        segments, provider, refine_meta = await diarize_audio(stt_path)
        diarize_provider = provider
        if segments:
            diarized_text = segments_to_labeled_transcript(segments)
            transcript_segments = [s.to_dict() for s in segments]

        diarize_output = {
            "provider": provider,
            "segment_count": len(segments),
            "used_for_stt": bool(diarized_text),
        }
        if refine_meta:
            diarize_output["refinement"] = refine_meta

        tracer.finish_step(
            diarize_step,
            output=diarize_output,
            artifacts=(
                [("segments.json", transcript_segments, "application/json")]
                if transcript_segments
                else None
            ),
        )
    except Exception as exc:
        tracer.finish_step(diarize_step, error=str(exc), output={"skipped": True})
        segments = []

    # Unified flow (no diary/external mode split): every audio entry is diarized
    # and voice-matched, and speaker identity is ALWAYS user-confirmed. We never
    # auto-label a speaker as '나' — a single-speaker recording might be someone
    # else (a lecture, a forwarded voice memo), so the owner is confirmed via the
    # identity sheet (its '나(본인)' action) just like any other speaker.
    # source_type is now only a content label, not a processing mode.
    if segments and get_settings().speaker_voice_memory_enabled:
        try:
            _, transcript_segments = await process_entry_speaker_profiles(
                session,
                user_id,
                entry.id,
                stt_path,
                segments,
                tracer=tracer,
            )
        except Exception as exc:
            voice_step = tracer.begin_step(
                "speaker_voice_memory",
                "embed",
                phase="fast_path",
                input_data={"fallback": True},
            )
            tracer.finish_step(voice_step, error=str(exc), output={"skipped": True})

    raw_transcript_ko: str | None = diarized_text
    # Keep diarization labels for GPT — voice-linked names applied after user confirms.
    llm_transcript_ko: str | None = raw_transcript_ko

    if raw_transcript_ko:
        whisper_step = tracer.begin_step(
            "whisper_stt",
            "api",
            phase="fast_path",
            model="whisper-1",
            input_data={"skipped": True, "reason": "speaker_diarize provided transcript"},
        )
        tracer.finish_step(
            whisper_step,
            output={
                "transcript_ko": raw_transcript_ko,
                "llm_transcript_ko": llm_transcript_ko,
                "source": "diarization",
            },
            artifacts=[("output.txt", raw_transcript_ko, "text/plain")],
        )
        transcript_ko = raw_transcript_ko
    else:
        transcript_ko = None

    if transcript_ko is None:
        step = tracer.begin_step(
            "whisper_stt",
            "api",
            phase="fast_path",
            model="whisper-1",
            input_data={
                "audio_path": str(stt_path.resolve()),
                "original_path": str(path.resolve()),
                "language": "ko",
                "trim_applied": stt_path != path,
                "fallback_reason": (
                    "deepgram_empty_transcript"
                    if diarize_provider.startswith("deepgram")
                    else "diarization_unavailable"
                    if diarize_provider in ("disabled", "no_provider_configured")
                    else f"diarization_no_segments:{diarize_provider}"
                ),
            },
        )
        try:
            transcript_ko = await transcribe_audio(stt_path)
            llm_transcript_ko = transcript_ko
            tracer.finish_step(
                step,
                output={
                    "transcript_ko": transcript_ko,
                    "source": "whisper_fallback",
                },
                artifacts=[("output.txt", transcript_ko, "text/plain")],
            )
        except Exception as exc:
            tracer.finish_step(step, error=str(exc))
            trace = tracer.finish("failed")
            await crud.update_journal_entry(
                session,
                entry,
                status="failed",
                pipeline_trace=trace,
                debug_run_dir=tracer.debug_dir_relative,
            )
            raise

    # 번역 제거(2026-07-04): 쓰기 경로는 정제만 — 번역은 학습 파이프라인(표현 추출)
    # 쪽에서 문장 단위로 다루고, 일기 자체를 통번역하는 기능은 사용하지 않기로 결정.
    gpt_input = llm_transcript_ko or transcript_ko
    _active_prompt = build_cleanup_only_system_prompt()
    step = tracer.begin_step(
        "gpt_cleanup",
        "llm",
        phase="fast_path",
        model=get_settings().openai_model,
        system_prompt=_active_prompt,
        input_data={"user_message": gpt_input, "translate": False},
    )
    try:
        cleaned = await cleanup_only(gpt_input)
        tracer.finish_step(
            step,
            output=cleaned,
            artifacts=[
                ("system_prompt.txt", _active_prompt, "text/plain"),
                ("input.txt", gpt_input, "text/plain"),
                ("output.json", cleaned, "application/json"),
            ],
        )
    except Exception as exc:
        tracer.finish_step(step, error=str(exc))
        trace = tracer.finish("failed")
        await crud.update_journal_entry(
            session,
            entry,
            status="failed",
            transcript_ko=transcript_ko,
            pipeline_trace=trace,
            debug_run_dir=tracer.debug_dir_relative,
        )
        raise

    summary = tracer.begin_step(
        "fast_path_complete",
        "policy",
        phase="fast_path",
        input_data={"chain": "LangChain RunnableSequence: audio_ingest | whisper_stt | gpt_cleanup"},
    )
    tracer.finish_step(
        summary,
        output={
            "transcript_ko_len": len(transcript_ko),
            "transcript_clean_ko_len": len(cleaned.get("transcript_clean_ko", "")),
            "next": "auto_graph_ingest",
        },
    )
    # Map the cleaned wording back onto segments so the speaker-selection UI and
    # the graph both show STT-corrected text (마차→말차), not the raw mishearing.
    if transcript_segments:
        transcript_segments = apply_cleaned_text_to_segments(
            transcript_segments, cleaned.get("transcript_clean_ko") or ""
        )

    trace = tracer.finish_fast()

    # Speaker count is the hard signal for the type gate: the classification LLM
    # drifts toward 대화 whenever it sees [Speaker_N] labels, so reconcile its guess
    # with the actual number of distinct diarized speakers before suggesting a type.
    distinct = {
        str(s.get("speaker", "")).strip()
        for s in (transcript_segments or [])
        if isinstance(s, dict) and str(s.get("speaker", "")).strip()
    }
    effective_single = bool(cleaned.get("single_speaker")) or len(distinct) <= 1
    gated_source_type = gate_source_type(
        cleaned.get("content_type"), single_speaker=effective_single
    )

    entry = await crud.update_journal_entry(
        session,
        entry,
        transcript_ko=transcript_ko,
        transcript_clean_ko=cleaned["transcript_clean_ko"],
        translation_en=cleaned["translation_en"],
        translation_de=cleaned.get("translation_de", ""),
        translations=cleaned.get("translations") or {},
        status="ready",
        transcript_segments=transcript_segments,
        suggested_source_type=gated_source_type,
        pipeline_trace=trace,
        debug_run_dir=tracer.debug_dir_relative,
    )

    # Phase 3: if the LLM judged this a single first-person diary but diarization
    # over-split it into multiple speakers, collapse them in the background (fully
    # reversible — speaker_original is preserved, so the user can split back).
    if cleaned.get("single_speaker") and len(distinct) > 1:
        try:
            await crud.remap_entry_speakers(session, user_id, entry, merge_all=True)
            await session.refresh(entry)
        except Exception:
            logger.exception("auto merge_all failed for entry %s", entry.id)

    return entry, trace


async def _mark_graph_failed(
    session: AsyncSession,
    entry_id: uuid.UUID,
    user_id: uuid.UUID,
    trace: dict,
) -> None:
    """Persist status=graph_failed, falling back to a fresh session.

    The build session may still be unusable even after rollback (e.g. the
    connection is broken), so a fresh session is the last-resort guarantee that
    the entry leaves 'graph_processing' instead of spinning on the client forever.
    """
    try:
        entry = await crud.get_journal_entry(session, entry_id, user_id)
        if entry is not None:
            await crud.update_journal_entry(
                session, entry, status="graph_failed", pipeline_trace=trace
            )
            return
    except Exception:
        logger.exception("graph_failed write failed on build session; retrying fresh")

    async with async_session_factory() as recovery:
        entry = await crud.get_journal_entry(recovery, entry_id, user_id)
        if entry is not None:
            await crud.update_journal_entry(
                recovery, entry, status="graph_failed", pipeline_trace=trace
            )


async def enqueue_entry_expression_extraction(
    session: AsyncSession, user_id: uuid.UUID
) -> None:
    """Enqueue language-expression extraction for the user's committed Statement nodes.

    Runs only AFTER the graph is committed (one-shot build or HITL apply), so the
    expensive per-node LLM extraction targets confirmed content — never a draft.
    """
    try:
        from .models import User as _User
        from .crud import get_effective_target_languages, get_all_statement_nodes
        from .extraction_queue import enqueue_bulk

        user = await session.get(_User, user_id)
        if user is not None:
            langs = get_effective_target_languages(user)
            all_stmts = await get_all_statement_nodes(session, user_id)
            await enqueue_bulk(user_id, all_stmts, langs)
    except Exception as _eq_exc:
        logger.warning("Failed to enqueue extraction: %s", _eq_exc)


async def run_entry_graph_draft(
    entry_id: uuid.UUID,
    user_id: uuid.UUID,
) -> dict | None:
    """Build a STAGING draft for HITL review — extraction only, NO commit.

    Stores the draft claims in ``entry.graph_staging`` and sets status to
    ``graph_staging_ready``. The user reviews/edits the draft, then the
    ``/graph/apply`` endpoint commits it (and only then extracts expressions).
    """
    from .routers.kg_build import extract_statement_graph_draft

    async with async_session_factory() as session:
        entry = await crud.get_journal_entry(session, entry_id, user_id)
        if entry is None:
            return None

        tracer = PipelineTracer.resume(entry_id, entry.pipeline_trace)
        tracer.run.current_phase = "slow_path"

        step = tracer.begin_step(
            "statement_graph_draft",
            "graph",
            phase="slow_path",
            input_data={"entry_id": str(entry_id)},
        )
        try:
            draft = await extract_statement_graph_draft(session, entry_id, user_id)
            # Pull the prompt debug fields off before persisting graph_staging —
            # they're for the pipeline flow trace only, not the reviewable draft.
            system_prompt = draft.pop("system_prompt", None)
            user_prompt = draft.pop("user_prompt", None)
            step.system_prompt = system_prompt
            step.input = {**step.input, "user_prompt": user_prompt}
            tracer.finish_step(
                step,
                output={
                    "claims": draft.get("claims"),
                    "context_type": draft.get("context_type"),
                    "speaker_count": draft.get("speaker_count"),
                },
            )
            trace = tracer.finish("completed")
            trace["graph_status"] = "graph_staging_ready"
            entry = await crud.get_journal_entry(session, entry_id, user_id)
            if entry is not None:
                await crud.update_journal_entry(
                    session,
                    entry,
                    status="graph_staging_ready",
                    graph_staging=draft,
                    pipeline_trace=trace,
                )
            return draft
        except Exception as exc:
            logger.exception("graph draft failed for entry %s", entry_id)
            try:
                await session.rollback()
            except Exception:
                logger.exception("rollback failed after graph draft error")
            tracer.finish_step(step, error=str(exc))
            trace = tracer.finish("completed_with_errors")
            trace["graph_status"] = "graph_failed"
            await _mark_graph_failed(session, entry_id, user_id, trace)
            raise


async def run_graph_ingest_pipeline(
    entry_id: uuid.UUID,
    user_id: uuid.UUID,
) -> dict:
    """Build the Statement graph (Person → Statement → Concept) from a journal entry.

    Uses the kg_build pipeline — the SINGLE source of truth for graph structure.
    Produces NO Vocab/Chunk nodes, so the Timeline & Calendar (Statement-based)
    reflect every journal entry's graph.
    """
    from .routers.kg_build import build_statement_graph_from_entry

    async with async_session_factory() as session:
        entry = await crud.get_journal_entry(session, entry_id, user_id)
        if entry is None:
            raise ValueError("entry not found")

        tracer = PipelineTracer.resume(entry_id, entry.pipeline_trace)
        tracer.run.current_phase = "slow_path"

        await crud.update_journal_entry(session, entry, status="graph_processing")

        step = tracer.begin_step(
            "statement_graph_build",
            "graph",
            phase="slow_path",
            input_data={"entry_id": str(entry_id)},
        )
        try:
            summary = await build_statement_graph_from_entry(session, entry_id, user_id)
            tracer.finish_step(step, output=summary)
            trace = tracer.finish("completed")
            trace["ingest_summary"] = summary
            trace["graph_status"] = "graph_ready"
            entry = await crud.get_journal_entry(session, entry_id, user_id)
            if entry is not None:
                await crud.update_journal_entry(
                    session,
                    entry,
                    status="graph_ready",
                    pipeline_trace=trace,
                )

            # Enqueue expression extraction for newly added Statement nodes.
            await enqueue_entry_expression_extraction(session, user_id)

            return summary
        except Exception as exc:
            logger.exception("graph ingest failed for entry %s", entry_id)
            # A DB error during the build leaves `session` in a failed-transaction
            # state. Without recovering it here, the graph_failed write below
            # silently fails too and the entry is stuck in 'graph_processing'
            # forever — the client just keeps spinning (infinite buffering).
            try:
                await session.rollback()
            except Exception:
                logger.exception("rollback failed after graph ingest error")
            tracer.finish_step(step, error=str(exc))
            trace = tracer.finish("completed_with_errors")
            trace["graph_status"] = "graph_failed"
            await _mark_graph_failed(session, entry_id, user_id, trace)
            raise


async def run_journal_slow_pipeline(entry_id: uuid.UUID, user_id: uuid.UUID) -> None:
    """Graph ingest — ONLY after manual GraphRAG button or auto text ingest."""
    settings = get_settings()
    async with async_session_factory() as session:
        entry = await crud.get_journal_entry(session, entry_id, user_id)
        if entry is None:
            return

        if settings.graph_manual_only and entry.graph_build_requested_at is None:
            # Reset status so it doesn't stay stuck in graph_processing.
            if entry.status == "graph_processing":
                await crud.update_journal_entry(session, entry, status="ready")
            return

    try:
        await run_graph_ingest_pipeline(entry_id, user_id)
    except Exception:
        pass


async def run_journal_text_pipeline(
    session: AsyncSession,
    user_id: uuid.UUID,
    dialogue: list[dict] | None = None,
    *,
    paragraph_text: str | None = None,
    source_type: str | None = None,
    attribution_kind: str | None = None,
    attribution_name: str | None = None,
) -> tuple[object, dict]:
    """Labeled text → cleanup/translate. No audio, no voice embeddings."""
    import re as _re
    from datetime import UTC, datetime

    from .journal_pipeline import build_cleanup_only_system_prompt, cleanup_only
    from .precision_text import (
        dialogue_to_transcript,
        normalize_dialogue,
        pre_slice_by_speaker_lines,
        segments_from_dialogue,
    )

    # Resolve the attribution head label before slicing: with an attribution the
    # whole text belongs to one asserter, so unlabeled paste needs no [화자]: lines.
    attribution_kind = (attribution_kind or "").strip().lower() or None
    attribution_name = (attribution_name or "").strip() or None
    if attribution_kind == "source" and not attribution_name:
        # Per-entry fallback — never a shared "미상" hub node (hub pollution).
        attribution_name = f"출처 미상 {datetime.now(UTC):%Y-%m-%d %H:%M}"
    attribution_label = (
        "나" if attribution_kind == "self" else attribution_name
    ) if attribution_kind else None

    if paragraph_text and paragraph_text.strip():
        pre_lines = pre_slice_by_speaker_lines(paragraph_text)
        if not pre_lines:
            # Plain prose (no "[이름]: …" lines): one line per blank-line paragraph.
            # 귀속이 지정됐으면 그 이름을, 아니면 '글쓴이'를 화자로 — 음성의
            # Speaker_N처럼 미확정 화자를 만들어 저장 후 칩에서 지정하게 한다
            # (나/사람/외부 출처). 업프론트 귀속 질문을 없애는 통일 흐름의 핵심.
            owner = attribution_label or "글쓴이"
            paras = [p.strip() for p in _re.split(r"\n\s*\n", paragraph_text) if p.strip()]
            # 문단 안에서도 사용자가 넣은 줄바꿈을 살린다 — 각 줄의 가로 공백만
            # 접고 줄바꿈은 유지해 목록·시 같은 구조가 뭉개지지 않게.
            pre_lines = [
                {
                    "speaker": owner,
                    "text": "\n".join(
                        " ".join(ln.split()) for ln in p.splitlines() if ln.strip()
                    ),
                }
                for p in paras
            ]
        lines = normalize_dialogue(pre_lines)
        labeled = dialogue_to_transcript(lines) if lines else paragraph_text.strip()
    else:
        lines = normalize_dialogue(dialogue or [])
        labeled = dialogue_to_transcript(lines)
    entry = await crud.create_journal_entry(session, user_id, audio_url=None)
    if source_type or attribution_kind:
        # Dedicated columns — the tracer overwrites pipeline_trace later.
        entry = await crud.update_journal_entry(
            session,
            entry,
            source_type=source_type,
            attribution_kind=attribution_kind,
            attribution_name=attribution_name,
        )
    tracer = PipelineTracer(entry.id)

    step = tracer.begin_step(
        "precision_text_ingest",
        "transform",
        phase="fast_path",
        input_data={"line_count": len(lines), "entry_source": "precision_text"},
    )
    segments = segments_from_dialogue(lines)
    tracer.finish_step(
        step,
        output={"transcript_preview": labeled[:500], "segment_count": len(segments)},
    )

    # 쓰기 = 정제만(빠름). 번역은 학습 시 온디맨드(POST .../translate)로 분리 —
    # 긴 글을 다국어로 동기 번역하면 지연이 과도하고, 정작 먼저 보고 싶은 건 정제된
    # 일기이기 때문. 그래프 빌드는 한국어 정제 텍스트를 쓰므로 영향 없음.
    _active_prompt2 = build_cleanup_only_system_prompt()

    step = tracer.begin_step(
        "gpt_cleanup",
        "llm",
        phase="fast_path",
        model=get_settings().openai_model,
        system_prompt=_active_prompt2,
        input_data={"transcript_ko": labeled, "translate": False},
    )
    try:
        cleaned = await cleanup_only(labeled)
        tracer.finish_step(
            step,
            output=cleaned,
            artifacts=[
                ("system_prompt.txt", _active_prompt2, "text/plain"),
                ("input.txt", labeled, "text/plain"),
                ("output.json", cleaned, "application/json"),
            ],
        )
    except Exception as exc:
        tracer.finish_step(step, error=str(exc))
        trace = tracer.finish("failed")
        await crud.update_journal_entry(
            session,
            entry,
            transcript_ko=labeled,
            transcript_segments=segments,
            status="failed",
            pipeline_trace={**trace, "entry_source": "precision_text"},
            debug_run_dir=tracer.debug_dir_relative,
        )
        raise

    summary = tracer.begin_step(
        "fast_path_complete",
        "policy",
        phase="fast_path",
        input_data={"chain": "precision_text_ingest | gpt_cleanup_translate"},
    )
    tracer.finish_step(
        summary,
        output={
            "transcript_ko_len": len(labeled),
            "translation_en_len": len(cleaned.get("translation_en", "")),
            "translation_de_len": len(cleaned.get("translation_de", "")),
            "translation_langs": sorted((cleaned.get("translations") or {}).keys()),
            "entry_source": "precision_text",
            "next": "auto_graph_ingest",
        },
    )
    trace = tracer.finish_fast()
    trace["entry_source"] = "precision_text"
    trace["graph_status"] = "graph_pending"

    # Reconcile the LLM's type guess with the actual speaker count (see gate above).
    # A typed entry with no explicit speakers is treated as a single-speaker diary.
    distinct = {
        str(s.get("speaker", "")).strip()
        for s in (segments or [])
        if isinstance(s, dict) and str(s.get("speaker", "")).strip()
    }
    effective_single = bool(cleaned.get("single_speaker")) or len(distinct) <= 1
    gated_source_type = (
        source_type
        or gate_source_type(
            cleaned.get("content_type"),
            single_speaker=effective_single,
            source_attributed=attribution_kind == "source",
        )
    )

    await crud.update_journal_entry(
        session,
        entry,
        transcript_ko=labeled,
        transcript_clean_ko=cleaned.get("transcript_clean_ko") or labeled,
        translation_en=cleaned.get("translation_en") or "",
        translation_de=cleaned.get("translation_de") or "",
        translations=cleaned.get("translations") or {},
        transcript_segments=segments,
        status="ready",
        suggested_source_type=gated_source_type,
        pipeline_trace=trace,
        debug_run_dir=tracer.debug_dir_relative,
    )
    refreshed = await crud.get_journal_entry(session, entry.id, user_id)
    return refreshed or entry, trace


async def run_journal_pipeline(
    session: AsyncSession,
    user_id: uuid.UUID,
    file_bytes: bytes,
    filename: str,
) -> tuple[object, dict]:
    """Fast path only — slow path requires explicit manual GraphRAG request."""
    entry, trace = await run_journal_fast_pipeline(
        session, user_id, file_bytes, filename
    )
    refreshed = await crud.get_journal_entry(session, entry.id, user_id)
    return refreshed or entry, refreshed.pipeline_trace if refreshed else trace
