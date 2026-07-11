import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, HTTPException, Query, UploadFile, status
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..db import get_session
from ..deps import request_user_dep
from ..journal_pipeline import (
    generate_example_sentences,
)
from ..models import User
from ..pipeline_runner import (
    run_entry_graph_draft,
    run_graph_ingest_pipeline,
    run_journal_fast_pipeline,
    run_journal_text_pipeline,
)
from ..pipeline_trace import PipelineTracer
from ..workers.quiz_refill import refill_user_quizzes
from ..quiz_pipeline import run_quiz_generate_pipeline
from ..quiz_types import ENABLED_QUIZ_TYPES, validate_quiz_type
from ..rag import hybrid_retrieve
from ..speaker_confirmation import (
    build_speaker_summaries_for_entry,
    unconfirmed_speaker_labels,
)
from ..schemas import (
    ExamplesResponse,
    ExampleSentence,
    GraphApplyRequest,
    GraphBuildOut,
    GraphSummaryOut,
    JournalEntryOut,
    RecommendedNodeOut,
    AttributionUpdate,
    SourceTypeUpdate,
    SpeakerRemapRequest,
    SpeakerSummaryOut,
    QuizGenerateOut,
    QuizGenerateRequest,
    ReviewItemOut,
    ReviewResultRequest,
    JournalTextEntryRequest,
    SpeakerProfileOut,
)

router = APIRouter(prefix="/journal", tags=["journal"])


def _schedule_graph_ingest(
    background_tasks: BackgroundTasks,
    entry_id: uuid.UUID,
    user_id: uuid.UUID,
) -> None:
    from ..workers.graph_processor import enqueue_graph_ingest

    if enqueue_graph_ingest(entry_id, user_id) is None:
        background_tasks.add_task(run_graph_ingest_pipeline, entry_id, user_id)


async def _entry_out(
    session: AsyncSession, user_id: uuid.UUID, entry
) -> JournalEntryOut:
    """Journal entry + per-session speaker confirmation status for STT UI."""
    out = JournalEntryOut.model_validate(entry)
    trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
    entry_source = trace.get("entry_source")
    if entry_source is None and entry.audio_url is None:
        from ..precision_text import is_precision_text_entry

        if is_precision_text_entry(entry):
            entry_source = "precision_text"
    if entry_source:
        out = out.model_copy(update={"entry_source": str(entry_source)})

    trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
    graph_status = trace.get("graph_status")
    if graph_status is None and entry.status in (
        "graph_processing",
        "graph_staging_ready",
        "graph_ready",
        "graph_failed",
    ):
        graph_status = entry.status
    # Authoritative override: if graph nodes are actually committed for this entry,
    # the graph IS ready — self-heal a stuck 'graph_processing'/'graph_failed'.
    if graph_status != "graph_ready":
        if await crud.entry_has_graph_nodes(session, entry.id):
            graph_status = "graph_ready"
    ingest_summary = trace.get("ingest_summary")
    if graph_status or ingest_summary:
        out = out.model_copy(
            update={
                "graph_status": graph_status,
                "ingest_summary": ingest_summary,
            }
        )

    from ..speaker_profiles import (
        entry_speaker_bindings_mismatched,
        entry_speaker_bindings_need_repair,
        repair_entry_speaker_bindings,
    )

    segments = entry.transcript_segments
    if isinstance(segments, list) and segments:
        needs_repair = entry_speaker_bindings_need_repair(entry) or await entry_speaker_bindings_mismatched(
            session, user_id, entry
        )
        if needs_repair:
            await repair_entry_speaker_bindings(session, user_id, entry)

    summaries = await build_speaker_summaries_for_entry(session, user_id, entry.id)
    if not summaries:
        return out
    return out.model_copy(
        update={
            "speaker_summaries": [
                SpeakerSummaryOut(
                    session_label=s.session_label,
                    speaker_profile_id=s.speaker_profile_id,
                    needs_confirmation=s.needs_confirmation,
                    confirmed_node=(
                        RecommendedNodeOut(
                            id=s.confirmed_node.id,
                            name=s.confirmed_node.name,
                        )
                        if s.confirmed_node is not None
                        else None
                    ),
                    suggested_node=(
                        RecommendedNodeOut(
                            id=s.suggested_node.id,
                            name=s.suggested_node.name,
                        )
                        if s.suggested_node is not None
                        else None
                    ),
                    auto_assigned=s.auto_assigned,
                )
                for s in summaries
            ]
        }
    )


@router.post("/upload", response_model=JournalEntryOut, status_code=status.HTTP_201_CREATED)
async def upload_journal(
    file: UploadFile = File(...),
    # The client sends source_type as a multipart form field — must be Form(), not
    # a query param, or FastAPI silently drops it (timeline → 미분류).
    source_type: str | None = Form(None),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    """Fast Path only: STT → cleanup/translate. GraphRAG is manual per entry."""
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty file")

    try:
        entry, _trace = await run_journal_fast_pipeline(
            session,
            user.id,
            data,
            file.filename or "recording.m4a",
            source_type=source_type,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Processing failed: {exc}") from exc

    await session.refresh(entry)
    return await _entry_out(session, user.id, entry)


@router.post("/entries", response_model=JournalEntryOut, status_code=status.HTTP_201_CREATED)
async def create_text_journal_entry(
    payload: JournalTextEntryRequest,
    background_tasks: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    """Precision text path: user-labeled paragraph or dialogue."""
    try:
        if payload.paragraph_text and payload.paragraph_text.strip():
            entry, _trace = await run_journal_text_pipeline(
                session,
                user.id,
                paragraph_text=payload.paragraph_text.strip(),
                source_type=payload.source_type,
                attribution_kind=payload.attribution_kind,
                attribution_name=payload.attribution_name,
            )
        else:
            dialogue = [line.model_dump() for line in (payload.dialogue or [])]
            entry, _trace = await run_journal_text_pipeline(
                session,
                user.id,
                dialogue,
                source_type=payload.source_type,
                attribution_kind=payload.attribution_kind,
                attribution_name=payload.attribution_name,
            )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Processing failed: {exc}") from exc

    await session.refresh(entry)
    return await _entry_out(session, user.id, entry)


@router.delete("/entries")
async def delete_all_entries(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Delete ALL of the user's journal entries, then GC orphaned voice profiles."""
    deleted = await crud.delete_all_journal_entries(session, user.id)
    await crud.sanitize_stale_voice_links(session, user.id)
    return {"deleted": deleted}


@router.delete("/entries/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_journal_entry(
    entry_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
):
    """Delete an entry and its cascaded data, then GC orphaned voice profiles."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    await crud.delete_journal_entry(session, entry)
    # Remove voice profiles/embeddings left with no node and no other entry.
    await crud.sanitize_stale_voice_links(session, user.id)


async def _reject_if_graph_locked(session: AsyncSession, entry) -> None:
    """Block edits to graph inputs (source type, speaker grouping/identity) once a
    knowledge graph has been committed for the entry — they'd silently desync the
    already-built graph. The user must delete the graph and rebuild to change them.
    """
    if await crud.entry_has_graph_nodes(session, entry.id):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "graph_locked",
                "message": "지식그래프가 생성되어 유형·화자는 잠겼습니다. "
                "수정하려면 그래프를 삭제 후 다시 생성하세요.",
            },
        )


@router.patch("/entries/{entry_id}/source-type", response_model=JournalEntryOut)
async def set_source_type(
    entry_id: uuid.UUID,
    payload: SourceTypeUpdate,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    """Confirm/override the entry's content type (the LLM-suggested label)."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    await _reject_if_graph_locked(session, entry)
    await crud.update_journal_entry(
        session, entry, source_type=payload.source_type.strip() or None
    )
    return await _entry_out(session, user.id, entry)


@router.patch("/entries/{entry_id}/attribution", response_model=JournalEntryOut)
async def set_attribution(
    entry_id: uuid.UUID,
    payload: AttributionUpdate,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    """Change who the entry's statements are attributed to (self/person/source).

    Locked once a graph is committed — the head node is already immutable.
    """
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    await _reject_if_graph_locked(session, entry)
    name = (payload.attribution_name or "").strip() or None
    if payload.attribution_kind == "source" and not name:
        from datetime import UTC as _UTC, datetime as _dt

        name = f"출처 미상 {_dt.now(_UTC):%Y-%m-%d %H:%M}"
    await crud.update_journal_entry(
        session,
        entry,
        attribution_kind=payload.attribution_kind,
        attribution_name=None if payload.attribution_kind == "self" else name,
    )
    return await _entry_out(session, user.id, entry)


@router.post("/entries/{entry_id}/speakers/remap")
async def remap_speakers(
    entry_id: uuid.UUID,
    payload: SpeakerRemapRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Reversibly fix diarization over-split: merge speakers, collapse all to '나',
    or reset to the original diarization. Returns the resulting speaker summaries."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    await _reject_if_graph_locked(session, entry)
    result = await crud.remap_entry_speakers(
        session,
        user.id,
        entry,
        group_map=payload.group_map,
        merges=payload.merges,
        merge_all=payload.merge_all,
        to_self=payload.to_self,
        reset=payload.reset,
    )
    summaries = await build_speaker_summaries_for_entry(session, user.id, entry_id)
    return {
        **result,
        "speaker_summaries": [
            {
                "session_label": s.session_label,
                "speaker_profile_id": str(s.speaker_profile_id),
                "needs_confirmation": s.needs_confirmation,
                "confirmed_node": (
                    {"id": str(s.confirmed_node.id) if s.confirmed_node.id else None,
                     "name": s.confirmed_node.name}
                    if s.confirmed_node else None
                ),
                "auto_assigned": s.auto_assigned,
            }
            for s in summaries
        ],
    }


@router.post("/entries/{entry_id}/graph", response_model=GraphBuildOut)
async def build_entry_graph(
    entry_id: uuid.UUID,
    background_tasks: BackgroundTasks,
    force: bool = False,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphBuildOut:
    """Manually trigger GraphRAG slow path (batch background job)."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    # GraphRAG는 한국어 정제 텍스트로 추출한다(번역 불필요) — 쓰기는 정제만 하고
    # 번역은 온디맨드이므로, 여기서는 정제 텍스트 유무만 확인한다.
    if not ((entry.transcript_clean_ko or "").strip() or (entry.transcript_ko or "").strip()):
        raise HTTPException(status_code=400, detail="정제된 텍스트가 아직 없습니다")

    # 화자 확인 게이트 — 텍스트도 음성과 동일하게 적용(사후 귀속 통일 흐름).
    # 단, 엔트리 귀속이 이미 명시된 경우(self / source·person+이름)는 head가
    # 확정돼 있으므로 미확정 화자 라벨이 남아 있어도 막지 않는다(레거시 경로 보호).
    _attr_kind = (entry.attribution_kind or "").strip().lower()
    _attr_name = (entry.attribution_name or "").strip()
    attribution_resolved = _attr_kind == "self" or (
        _attr_kind in ("source", "person") and bool(_attr_name)
    )
    if not attribution_resolved:
        pending = await unconfirmed_speaker_labels(session, user.id, entry_id)
        if pending:
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "speakers_unconfirmed",
                    "message": "화자 확인 후 GraphRAG를 실행할 수 있습니다.",
                    "pending_labels": pending,
                },
            )

    if await crud.entry_has_graph_nodes(session, entry_id) and not force:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "graph_locked",
                "message": "이미 확정된 지식그래프가 있습니다. 수정하려면 삭제 후 다시 생성하세요.",
            },
        )

    if entry.status == "graph_processing" and not force:
        return GraphBuildOut(
            entry_id=entry_id,
            status="graph_processing",
            message="GraphRAG draft already in progress",
        )

    await crud.update_journal_entry(
        session,
        entry,
        graph_build_requested_at=datetime.now(UTC),
        status="graph_processing",
    )

    # Two-phase HITL: build a STAGING draft only. The user reviews/edits it, then
    # POST .../graph/apply commits it (and only then are expressions extracted).
    background_tasks.add_task(run_entry_graph_draft, entry_id, user.id)
    return GraphBuildOut(
        entry_id=entry_id,
        status="graph_processing",
        message="그래프 드래프트 생성 시작 (검토 후 확정)",
    )


@router.post("/entries/{entry_id}/graph/apply", response_model=GraphBuildOut)
async def apply_entry_graph(
    entry_id: uuid.UUID,
    payload: GraphApplyRequest | None = None,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    *,
    background_tasks: BackgroundTasks,
) -> GraphBuildOut:
    """Commit a reviewed graph draft into immutable graph nodes.

    Accepts the (possibly user-edited) claims from the review screen; falls back to
    the stored ``graph_staging`` draft. After commit the graph is locked and
    expression extraction is enqueued from the confirmed Statement nodes.
    """
    from ..routers.kg_build import persist_entry_claims

    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")

    if await crud.entry_has_graph_nodes(session, entry_id):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "graph_locked",
                "message": "이미 확정된 지식그래프가 있습니다.",
            },
        )

    staging = entry.graph_staging if isinstance(entry.graph_staging, dict) else {}
    claims = (payload.claims if payload else None) or staging.get("claims")
    context_type = (
        (payload.context_type if payload else None)
        or staging.get("context_type")
        or (entry.source_type or "").strip()
        or "대화"
    )
    if not claims:
        raise HTTPException(
            status_code=400,
            detail="검토할 그래프 드래프트가 없습니다. 먼저 그래프를 생성하세요.",
        )

    # Trace the commit step so the pipeline flow view shows the full
    # draft(LLM) → apply(commit) picture, not just the draft half.
    tracer = PipelineTracer.resume(entry_id, entry.pipeline_trace)
    tracer.run.current_phase = "slow_path"
    step = tracer.begin_step(
        "graph_apply",
        "graph",
        phase="slow_path",
        input_data={
            "claim_count": len(claims),
            "context_type": context_type,
            "user_edited": bool(payload and payload.claims),
        },
    )
    try:
        summary = await persist_entry_claims(
            session, user.id, entry_id, claims, context_type
        )
    except ValueError as exc:
        tracer.finish_step(step, error=str(exc))
        entry = await crud.get_journal_entry(session, entry_id, user.id)
        if entry is not None:
            await crud.update_journal_entry(
                session, entry, pipeline_trace=tracer.checkpoint()
            )
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    tracer.finish_step(step, output=summary)
    trace = tracer.finish("completed")
    trace["graph_status"] = "graph_ready"
    trace["ingest_summary"] = summary

    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is not None:
        await crud.update_journal_entry(
            session,
            entry,
            status="graph_ready",
            graph_staging=None,
            pipeline_trace=trace,
        )

    # Quizzes are generated straight from Statement nodes (no expression
    # extraction). Top up the per-language quiz queues off the confirmed graph.
    background_tasks.add_task(refill_user_quizzes, user.id)

    return GraphBuildOut(
        entry_id=entry_id,
        status="graph_ready",
        message="지식그래프 확정 완료",
    )


@router.get("/entries", response_model=list[JournalEntryOut])
async def list_entries(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[JournalEntryOut]:
    entries = await crud.list_journal_entries(session, user.id)
    return [await _entry_out(session, user.id, e) for e in entries]


@router.get("/entries/{entry_id}", response_model=JournalEntryOut)
async def get_entry(
    entry_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    return await _entry_out(session, user.id, entry)


@router.post("/entries/{entry_id}/examples", response_model=ExamplesResponse)
async def generate_examples(
    entry_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> ExamplesResponse:
    """GraphRAG-backed personalized example sentences (5)."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    if not entry.translation_en:
        raise HTTPException(status_code=400, detail="Entry not yet translated")

    query = entry.translation_en[:200]
    rc = await hybrid_retrieve(session, query, user.id)
    raw = await generate_example_sentences(
        entry.translation_en,
        entry.transcript_clean_ko or entry.transcript_ko or "",
        rc.context,
    )
    examples = [ExampleSentence(**e) for e in raw]
    while len(examples) < 5:
        examples.append(ExampleSentence(en="(placeholder)", ko="", note=""))
    return ExamplesResponse(
        examples=examples[:5],
        graph_context_used=bool(rc.context.strip()),
        retrieval_preview=rc.context[:500] if rc.context else "",
    )


@router.post("/entries/{entry_id}/quiz/generate", response_model=QuizGenerateOut)
async def generate_quiz_item(
    entry_id: uuid.UUID,
    quiz_type: str = Query(..., description="cloze | scramble | mcq_nuance"),
    body: QuizGenerateRequest | None = None,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizGenerateOut:
    try:
        quiz_type = validate_quiz_type(quiz_type)
        if quiz_type not in ENABLED_QUIZ_TYPES:
            raise HTTPException(status_code=410, detail="이 퀴즈 유형은 비활성화되었습니다.")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    try:
        quiz, trace = await run_quiz_generate_pipeline(
            session,
            user.id,
            quiz_type,
            entry_id=entry_id,
            is_freedom_on=body.is_freedom_on if body else None,
            selected_vocab_id=body.selected_vocab_id if body else None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return QuizGenerateOut(
        quiz_id=quiz.id,
        quiz_type=quiz.quiz_type,
        difficulty_level=quiz.difficulty_level,
        trace_step_count=len(trace.get("steps") or []),
    )


@router.get("/reviews", response_model=list[ReviewItemOut])
async def list_reviews(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[ReviewItemOut]:
    schedules = await crud.list_due_reviews(session, user.id)
    return [
        ReviewItemOut(
            journal_entry_id=s.journal_entry_id,
            next_review_at=s.next_review_at,
            interval_days=s.interval_days,
            repetitions=s.repetitions,
        )
        for s in schedules
    ]


@router.post("/reviews/{entry_id}/complete")
async def complete_review(
    entry_id: uuid.UUID,
    payload: ReviewResultRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
):
    from sqlalchemy import select

    from ..models import ReviewSchedule

    result = await session.execute(
        select(ReviewSchedule).where(
            ReviewSchedule.user_id == user.id,
            ReviewSchedule.journal_entry_id == entry_id,
        )
    )
    sched = result.scalar_one_or_none()
    if sched is None:
        raise HTTPException(status_code=404, detail="Review schedule not found")
    await crud.record_review_result(session, sched, payload.quality)
    return {"status": "ok"}


@router.get("/graph/summary", response_model=GraphSummaryOut)
async def graph_summary(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphSummaryOut:
    data = await crud.get_graph_summary(session, user.id)
    return GraphSummaryOut(**data)


@router.get("/speaker-profiles", response_model=list[SpeakerProfileOut])
async def list_speaker_profiles(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[SpeakerProfileOut]:
    """Voice memory profiles — linked to Person nodes after GraphRAG."""
    profiles = await crud.list_speaker_profiles(session, user.id)
    return profiles
