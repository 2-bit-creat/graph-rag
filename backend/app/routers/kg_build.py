"""KG Build pipeline — two-stage HITL graph construction.

Stage 1 (POST /kg/extract): LLM extracts draft claims from Korean text.
  - diary mode  : single claim, speaker fixed to '나'
  - external mode: multi-claim, speakers auto-detected from text

Stage 2 (POST /kg/commit): persists human-verified claims to PostgreSQL.
  Speaker → Statement → Concept(s)  (no Vocab / no Subject nodes)

GET /kg/stats   — activity heatmap + source distribution for Insight tab
GET /kg/debug/runs — recent pipeline run traces for Debug tab
"""

from __future__ import annotations

import json
import logging
import re
import time
import uuid as _uuid
from collections import deque
from datetime import datetime, timezone, timedelta
from functools import lru_cache
from typing import Any, Literal

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from openai import AsyncOpenAI
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..config import get_settings
from ..db import get_session
from ..dev_user import dev_user_dep
from ..journal_pipeline import transcribe_audio
from ..models import User
from ..speaker_diarization import SpeakerSegment, diarize_audio
from ..storage import save_audio, local_path

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/kg", tags=["kg-build"])

# ─── In-memory run log (last 50 extract calls) ───────────────────────────────

_run_log: deque[dict] = deque(maxlen=50)


# ─── OpenAI client (shared, cached) ──────────────────────────────────────────

@lru_cache
def _llm_client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


# ─── Request / Response schemas ──────────────────────────────────────────────

class KgExtractRequest(BaseModel):
    mode: Literal["diary", "external"]
    fixed_speaker: str | None = None        # diary mode: defaults to '나'
    source_category: str | None = None      # external mode: 회의록 / 책 / 뉴스 etc.
    text: str = Field(min_length=1, max_length=8000)
    existing_nodes: list[str] = Field(default_factory=list)


class KgClaimIn(BaseModel):
    speaker: str
    title: str = ""          # short node label (5-7 words); falls back to truncated statement
    statement: str           # full 1-2 sentence content; stored in node description
    concepts: list[str] = Field(default_factory=list)


class KgCommitRequest(BaseModel):
    claims: list[KgClaimIn] = Field(min_length=1)
    context_type: str  # e.g. 'diary', 'meeting', 'book'
    original_text: str = ""
    journal_entry_id: _uuid.UUID | None = None  # optional link for transcript provenance


# ─── Statement description helpers ────────────────────────────────────────────

def _make_stmt_description(context_type: str, content: str) -> str:
    """Serialize context_type + content as JSON for Statement node description."""
    return json.dumps({"context_type": context_type, "content": content}, ensure_ascii=False)


def _parse_stmt_description(description: str | None) -> tuple[str, str]:
    """Return (context_type, content) from a Statement node description.

    Handles both new JSON format and legacy 'context_type\\ncontent' format.
    """
    if not description:
        return "미분류", ""
    try:
        data = json.loads(description)
        return (data.get("context_type") or "미분류").strip(), (data.get("content") or "").strip()
    except (json.JSONDecodeError, AttributeError):
        # legacy: "context_type\nfull statement"
        parts = description.split("\n", 1)
        return parts[0].strip() or "미분류", parts[1].strip() if len(parts) > 1 else ""


class KgCommitOut(BaseModel):
    ok: bool
    claims_saved: int
    nodes_upserted: int
    edges_created: int


# ─── LLM system prompts ───────────────────────────────────────────────────────

_DIARY_SYSTEM = """You are a knowledge graph assistant for a Korean language learning app.

Extract the **core Korean statement** and **concept tags** from the user's personal diary text.
The speaker is always pre-fixed — never change or infer a different speaker.

Return ONLY valid JSON in this exact shape (no markdown, no commentary):
{
  "nodes": {
    "title": "핵심 내용을 담은 5-7단어 한국어 제목",
    "statement": "정제된 핵심 한국어 진술 (1-2문장 전체 내용)"
  },
  "concepts": ["개념1", "개념2"],
  "isExistingNodeMatched": {"concepts": [true, false]}
}

Rules:
- title: 5–7 Korean words that capture the essence. Used as the graph node label.
- statement: 1–2 clean Korean sentences preserving the full meaning (stored as node description).
- concepts: 2–5 domain terms or proper nouns relevant to the statement.
- Do NOT create Vocab nodes or Subject nodes.
- Entity resolution: if a concept closely matches a name in existing_nodes, reuse that exact name and mark matched=true."""


_EXTERNAL_SYSTEM = """You are a knowledge graph assistant. Extract speaker-attributed claims from Korean source text.

Return ONLY valid JSON in this exact shape (no markdown, no commentary):
{
  "contextTypeOptions": ["추천매체1", "추천매체2"],
  "claims": [
    {
      "speaker": "화자명 또는 출처명",
      "title": "핵심 내용을 담은 5-7단어 한국어 제목",
      "statement": "정제된 핵심 한국어 진술 (1-2문장 전체 내용)",
      "concepts": ["개념1", "개념2"],
      "speaker_matched": false,
      "concepts_matched": [false, false]
    }
  ]
}

Rules:
- Split on speaker change OR semantic topic shift within the same speaker.
- speaker: person or media who made this claim. Match existing_nodes if semantically identical.
- title: 5–7 Korean words capturing the essence of this claim. Used as the graph node label.
- statement: 1–2 clean Korean sentences (remove filler, preserve full meaning).
- concepts: 2–5 domain terms / proper nouns per claim.
- speaker_matched: true only when speaker name was reused from existing_nodes.
- concepts_matched: per-concept boolean, true if reused from existing_nodes.
- contextTypeOptions: top 2 guesses from [대화, 회의록, 책, 논문, 뉴스, 강연, 잡지]. For casual multi-person talk with no clear medium, use 대화.
- Do NOT create Vocab nodes or Subject nodes."""


# ─── User prompt builders ─────────────────────────────────────────────────────

def _diary_user_prompt(text: str, fixed_speaker: str, existing_nodes: list[str]) -> str:
    nodes_hint = ", ".join(existing_nodes[:50]) if existing_nodes else "(없음)"
    return (
        f"Fixed speaker: {fixed_speaker}\n"
        f"Existing nodes for concept matching: {nodes_hint}\n\n"
        f"--- Diary text ---\n{text}"
    )


def _external_user_prompt(text: str, source_category: str, existing_nodes: list[str]) -> str:
    nodes_hint = ", ".join(existing_nodes[:50]) if existing_nodes else "(없음)"
    return (
        f"Source category: {source_category}\n"
        f"Existing nodes for entity resolution: {nodes_hint}\n\n"
        f"--- Source text ---\n{text}"
    )


# ─── JSON helper ─────────────────────────────────────────────────────────────

def _parse_llm_json(raw: str) -> Any:
    """Strip markdown code fences then parse JSON."""
    cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw.strip(), flags=re.DOTALL)
    return json.loads(cleaned)


# ─── DB-verified concept matching ─────────────────────────────────────────────

async def _verify_concept_matches(
    result: dict,
    session: AsyncSession,
    user_id: _uuid.UUID,
) -> None:
    """Override LLM's isExistingNodeMatched with ground truth from the DB.

    LLMs hallucinate matched=true even when the existing_nodes list is empty
    or when a similarly-named (but deleted) node was seen in training data.
    This function replaces every match flag with an actual DB lookup, so only
    active (non-deleted) nodes count as existing.
    """
    concepts: list[str] = result.get("concepts") or []
    # Diary mode: single-node result
    nodes_block = result.get("nodes")
    if isinstance(nodes_block, dict) and concepts:
        matched_flags = [False] * len(concepts)
        for i, name in enumerate(concepts):
            hits = await crud.find_nodes_by_name(session, user_id, name)
            matched_flags[i] = len(hits) > 0
        existing_matched = result.get("isExistingNodeMatched") or {}
        existing_matched["concepts"] = matched_flags
        result["isExistingNodeMatched"] = existing_matched
        return

    # External mode: list of claims
    claims: list[dict] = result.get("claims") or []
    for claim in claims:
        c_names: list[str] = claim.get("concepts") or []
        matched_flags = [False] * len(c_names)
        for i, name in enumerate(c_names):
            hits = await crud.find_nodes_by_name(session, user_id, name)
            matched_flags[i] = len(hits) > 0
        existing_matched = claim.get("isExistingNodeMatched") or {}
        existing_matched["concepts"] = matched_flags
        claim["isExistingNodeMatched"] = existing_matched

        # Speaker match
        speaker_name: str = (claim.get("speaker") or "").strip()
        if speaker_name:
            hits = await crud.find_nodes_by_name(session, user_id, speaker_name)
            existing_matched["speaker"] = len(hits) > 0


# ─── Endpoints ────────────────────────────────────────────────────────────────

@router.post("/extract")
async def kg_extract(
    body: KgExtractRequest,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Stage 1 — LLM drafts nodes/claims from Korean text. Nothing persisted yet.

    isExistingNodeMatched is re-verified against the actual DB after the LLM responds,
    so hallucinated matches are always corrected.
    """
    settings = get_settings()

    if body.mode == "diary":
        speaker = (body.fixed_speaker or "").strip() or "나"
        system_prompt = _DIARY_SYSTEM
        user_prompt = _diary_user_prompt(body.text, speaker, body.existing_nodes)
    else:
        category = (body.source_category or "텍스트").strip()
        system_prompt = _EXTERNAL_SYSTEM
        user_prompt = _external_user_prompt(body.text, category, body.existing_nodes)

    t0 = time.monotonic()
    run_id = str(_uuid.uuid4())[:8]
    raw = "{}"
    try:
        resp = await _llm_client().chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.2,
            response_format={"type": "json_object"},
        )
        raw = resp.choices[0].message.content or "{}"
        result = _parse_llm_json(raw)

        # ── Re-verify matched flags against actual DB (LLMs hallucinate) ────────
        await _verify_concept_matches(result, session, user.id)

        latency_ms = int((time.monotonic() - t0) * 1000)
        _run_log.appendleft({
            "run_id": run_id,
            "mode": body.mode,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": "ok",
            "latency_ms": latency_ms,
            "token_in": resp.usage.prompt_tokens if resp.usage else None,
            "token_out": resp.usage.completion_tokens if resp.usage else None,
            "system_prompt": system_prompt,
            "user_prompt": user_prompt,
            "raw_response": raw,
        })
        return result
    except json.JSONDecodeError as exc:
        _run_log.appendleft({
            "run_id": run_id, "mode": body.mode,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": "json_error", "latency_ms": int((time.monotonic() - t0) * 1000),
            "system_prompt": system_prompt, "user_prompt": user_prompt, "raw_response": raw,
        })
        logger.warning("kg_extract JSON parse error: %s | raw=%s", exc, raw[:200])
        raise HTTPException(status_code=502, detail=f"LLM 응답 파싱 실패: {exc}")
    except Exception as exc:
        _run_log.appendleft({
            "run_id": run_id, "mode": body.mode,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": "error", "latency_ms": int((time.monotonic() - t0) * 1000),
            "system_prompt": system_prompt, "user_prompt": user_prompt, "raw_response": "",
        })
        logger.exception("kg_extract LLM call failed")
        raise HTTPException(status_code=502, detail=f"LLM 호출 실패: {exc}")


@router.post("/commit", response_model=KgCommitOut)
async def kg_commit(
    body: KgCommitRequest,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> KgCommitOut:
    """Stage 2 — persist human-verified claims into the graph (PostgreSQL).

    Graph structure per claim:
        (Person/Speaker) --SPOKE_OR_PUBLISHED--> (Statement) --CONTEXT--> (Concept...)
    """
    node_ids: set[str] = set()
    edge_ids: set[str] = set()

    for claim in body.claims:
        speaker_name = (claim.speaker or "").strip()
        statement_text = (claim.statement or "").strip()
        if not speaker_name or not statement_text:
            logger.debug("kg_commit: skipping empty claim")
            continue

        # ── Speaker / Source node ────────────────────────────────────────────
        speaker_node = await crud._get_or_create_node(
            session,
            name=speaker_name,
            type_="Person",
            user_id=user.id,
        )
        node_ids.add(str(speaker_node.id))

        # ── Statement node ───────────────────────────────────────────────────
        # name        = short title (5-7 words) — graph node label
        # description = JSON {"context_type": ..., "content": ...}
        title = (claim.title or "").strip() or statement_text[:40]
        stmt_description = _make_stmt_description(body.context_type, statement_text)
        stmt_node = await crud._get_or_create_node(
            session,
            name=title,
            type_="Statement",
            description=stmt_description,
            user_id=user.id,
        )
        node_ids.add(str(stmt_node.id))

        # ── Speaker → Statement ──────────────────────────────────────────────
        edge = await crud.create_edge(
            session,
            source_id=speaker_node.id,
            target_id=stmt_node.id,
            relation="SPOKE_OR_PUBLISHED",
            user_id=user.id,
        )
        if edge:
            edge_ids.add(str(edge.id))

        # ── Concept nodes + Statement → Concept edges ────────────────────────
        for raw_concept in claim.concepts:
            concept_name = (raw_concept or "").strip()
            if not concept_name:
                continue
            concept_node = await crud._get_or_create_node(
                session,
                name=concept_name,
                type_="Concept",
                user_id=user.id,
            )
            node_ids.add(str(concept_node.id))
            c_edge = await crud.create_edge(
                session,
                source_id=stmt_node.id,
                target_id=concept_node.id,
                relation="CONTEXT",
                user_id=user.id,
            )
            if c_edge:
                edge_ids.add(str(c_edge.id))

    await session.commit()
    logger.info(
        "kg_commit user=%s claims=%d nodes=%d edges=%d",
        user.id, len(body.claims), len(node_ids), len(edge_ids),
    )

    # ── Create JournalGraphLink entries if entry id was provided ───────────────
    if body.journal_entry_id is not None:
        try:
            node_uuid_list = [_uuid.UUID(nid) for nid in node_ids]
            edge_uuid_list = [_uuid.UUID(eid) for eid in edge_ids]
            await crud.record_journal_graph_links(
                session, body.journal_entry_id, node_uuid_list, edge_uuid_list
            )
        except Exception as _link_exc:
            logger.warning("kg_commit: failed to record journal graph links: %s", _link_exc)

    # ── Enqueue expression extraction for newly committed Statement nodes ──────
    try:
        from ..extraction_queue import enqueue_bulk
        from ..crud import get_effective_target_languages, get_all_statement_nodes

        langs = get_effective_target_languages(user)
        all_stmts = await get_all_statement_nodes(session, user.id)
        await enqueue_bulk(user.id, all_stmts, langs)
    except Exception as _eq_exc:
        logger.warning("kg_commit: failed to enqueue expression extraction: %s", _eq_exc)

    return KgCommitOut(
        ok=True,
        claims_saved=len(body.claims),
        nodes_upserted=len(node_ids),
        edges_created=len(edge_ids),
    )


# ─── Shared claim persistence ─────────────────────────────────────────────────

async def _persist_claims(
    session: AsyncSession,
    user_id: _uuid.UUID,
    claims: list[dict],
    context_type: str,
) -> tuple[set[str], set[str]]:
    """Persist claims as (Person)-SPOKE_OR_PUBLISHED->(Statement)-CONTEXT->(Concept).

    Returns (node_ids, edge_ids) as string sets. Shared by /kg/commit and the
    journal-entry graph builder. NEVER creates Vocab nodes (architecture rule #1).
    """
    node_ids: set[str] = set()
    edge_ids: set[str] = set()

    for claim in claims:
        speaker_name = (claim.get("speaker") or "").strip()
        statement_text = (claim.get("statement") or "").strip()
        if not speaker_name or not statement_text:
            continue

        speaker_node = await crud._get_or_create_node(
            session, name=speaker_name, type_="Person", user_id=user_id,
        )
        node_ids.add(str(speaker_node.id))

        title = (claim.get("title") or "").strip() or statement_text[:40]
        stmt_description = _make_stmt_description(context_type, statement_text)
        stmt_node = await crud._get_or_create_node(
            session, name=title, type_="Statement",
            description=stmt_description, user_id=user_id,
        )
        node_ids.add(str(stmt_node.id))

        edge = await crud.create_edge(
            session, source_id=speaker_node.id, target_id=stmt_node.id,
            relation="SPOKE_OR_PUBLISHED", user_id=user_id,
        )
        if edge:
            edge_ids.add(str(edge.id))

        for raw_concept in (claim.get("concepts") or []):
            concept_name = (raw_concept or "").strip()
            if not concept_name:
                continue
            concept_node = await crud._get_or_create_node(
                session, name=concept_name, type_="Concept", user_id=user_id,
            )
            node_ids.add(str(concept_node.id))
            c_edge = await crud.create_edge(
                session, source_id=stmt_node.id, target_id=concept_node.id,
                relation="CONTEXT", user_id=user_id,
            )
            if c_edge:
                edge_ids.add(str(c_edge.id))

    return node_ids, edge_ids


# ─── Journal-entry → Statement graph (used by 내 일기 "지식 그래프 생성") ──────────

async def build_statement_graph_from_entry(
    session: AsyncSession,
    entry_id: _uuid.UUID,
    user_id: _uuid.UUID,
) -> dict:
    """Build the Statement graph from a journal entry's transcript.

    This is the ONE correct graph pipeline for journal entries:
      diary (1 speaker)  → diary extraction  → single Statement
      dialogue (N speakers) → external extraction → multi Statement

    Produces ONLY Person/Statement/Concept nodes (no Chunk, no Vocab), so the
    Timeline & Calendar (which query Statement nodes) reflect the result.
    """
    from ..precision_text import segments_to_paragraph_text

    entry = await crud.get_journal_entry(session, entry_id, user_id)
    if entry is None:
        raise ValueError("entry not found")

    segments = entry.transcript_segments if isinstance(entry.transcript_segments, list) else []
    speakers: list[str] = []
    for seg in segments:
        if isinstance(seg, dict):
            sp = str(seg.get("speaker", "")).strip()
            if sp and sp not in speakers:
                speakers.append(sp)

    diary_text = (entry.transcript_clean_ko or entry.transcript_ko or "").strip()
    labeled_text = segments_to_paragraph_text(segments) if segments else diary_text
    if not labeled_text.strip() and not diary_text:
        raise ValueError("empty transcript for graph build")

    # Existing node names for entity resolution
    all_nodes = await crud.get_all_nodes(session, user_id)
    existing_names = [n.name for n in all_nodes if n.name]

    is_diary = len(speakers) <= 1
    settings = get_settings()

    # User-selected source category (대화/회의록/책/뉴스/강연/논문) is stored in the
    # pipeline trace; honor it as the Statement context_type instead of hardcoding.
    trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
    source_category = str(trace.get("source_type") or "").strip() or "대화"

    if is_diary:
        speaker_name = speakers[0] if speakers else "나"
        context_type = "개인일기"
        system_prompt = _DIARY_SYSTEM
        user_prompt = _diary_user_prompt(diary_text or labeled_text, speaker_name, existing_names)
    else:
        context_type = source_category
        system_prompt = _EXTERNAL_SYSTEM
        user_prompt = _external_user_prompt(labeled_text, source_category, existing_names)

    resp = await _llm_client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0.2,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or "{}"
    result = _parse_llm_json(raw)
    await _verify_concept_matches(result, session, user_id)

    # Build claim dicts
    claims: list[dict] = []
    if is_diary:
        nodes_block = result.get("nodes") if isinstance(result.get("nodes"), dict) else {}
        statement = (nodes_block.get("statement") or "").strip()
        title = (nodes_block.get("title") or "").strip()
        if statement:
            claims.append({
                "speaker": speakers[0] if speakers else "나",
                "title": title,
                "statement": statement,
                "concepts": result.get("concepts") or [],
            })
    else:
        for c in (result.get("claims") or []):
            if not isinstance(c, dict):
                continue
            claims.append({
                "speaker": (c.get("speaker") or "").strip(),
                "title": (c.get("title") or "").strip(),
                "statement": (c.get("statement") or "").strip(),
                "concepts": c.get("concepts") or [],
            })

    if not claims:
        raise ValueError("LLM produced no statements")

    node_ids, edge_ids = await _persist_claims(session, user_id, claims, context_type)
    await session.commit()

    # Provenance links so 노드 ↔ 일기 추적이 유지됨
    try:
        node_uuid_list = [_uuid.UUID(nid) for nid in node_ids]
        edge_uuid_list = [_uuid.UUID(eid) for eid in edge_ids]
        await crud.record_journal_graph_links(
            session, entry_id, node_uuid_list, edge_uuid_list
        )
    except Exception as link_exc:
        logger.warning("build_statement_graph: link recording failed: %s", link_exc)

    statement_count = sum(1 for c in claims if c.get("statement"))
    return {
        "statement_count": statement_count,
        "speaker_count": len(speakers) if speakers else 1,
        "concept_count": sum(len(c.get("concepts") or []) for c in claims),
        "node_count": len(node_ids),
        "edge_count": len(edge_ids),
        "context_type": context_type,
    }


# ─── Transcribe endpoint ──────────────────────────────────────────────────────

@router.post("/transcribe")
async def kg_transcribe(
    file: UploadFile = File(...),
    user: User = Depends(dev_user_dep),
) -> dict:
    """STT + speaker diarization for audio uploaded to the KG build flow.

    Returns transcript text, unique speaker count, and per-segment details so
    the frontend can decide:
    - diary mode  → 1 speaker expected; warn user if speaker_count > 1
    - external mode → show speaker segments for labeling before KG extraction
    """
    file_bytes = await file.read()
    filename = file.filename or "audio.wav"

    audio_key = await save_audio(file_bytes, filename, user.id)
    audio_path = local_path(audio_key)

    # Run diarization first (non-blocking if disabled)
    segments: list[SpeakerSegment]
    segments, _, _ = await diarize_audio(audio_path)

    # STT transcription
    transcript = await transcribe_audio(audio_path)

    # If diarization ran, overlay text onto segments; otherwise single-speaker
    if segments:
        # Map whisper transcript words to diarization time windows (best-effort)
        # For now return the labeled transcript already merged by diarize_audio
        from ..speaker_diarization import segments_to_labeled_transcript
        labeled = segments_to_labeled_transcript(segments)
        unique_speakers = len({s.speaker for s in segments})
        segments_out = [
            {
                "speaker": s.speaker,
                "text": s.text,
                "start_sec": round(s.start_sec, 2),
                "end_sec": round(s.end_sec, 2),
            }
            for s in segments
        ]
        return {
            "transcript": labeled or transcript,
            "plain_transcript": transcript,
            "speaker_count": unique_speakers,
            "segments": segments_out,
        }
    else:
        # Diarization disabled / unavailable — treat as single speaker
        return {
            "transcript": transcript,
            "plain_transcript": transcript,
            "speaker_count": 1,
            "segments": [{"speaker": "Speaker_0", "text": transcript, "start_sec": 0.0, "end_sec": 0.0}],
        }


# ─── Stats endpoint ────────────────────────────────────────────────────────────

@router.get("/stats")
async def kg_stats(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Returns aggregated stats for the Insight dashboard."""
    nodes = await crud.get_all_nodes(session, user.id)

    statements = [n for n in nodes if n.type == "Statement"]
    concepts   = [n for n in nodes if n.type == "Concept"]
    speakers   = [n for n in nodes if n.type == "Person"]

    # daily_activity: count Statement nodes per UTC date (last 365 days)
    today = datetime.now(timezone.utc).date()
    cutoff = today - timedelta(days=364)
    day_counts: dict[str, int] = {}
    for n in statements:
        d = n.created_at.astimezone(timezone.utc).date() if n.created_at.tzinfo else n.created_at.date()
        if d >= cutoff:
            key = d.isoformat()
            day_counts[key] = day_counts.get(key, 0) + 1
    daily_activity = [{"date": k, "count": v} for k, v in sorted(day_counts.items())]

    # streak: consecutive days with at least 1 statement up to today
    streak = 0
    check = today
    while True:
        if day_counts.get(check.isoformat(), 0) > 0:
            streak += 1
            check -= timedelta(days=1)
        else:
            break

    # source_distribution: parse context_type from structured description
    src_counts: dict[str, int] = {}
    for n in statements:
        src, _ = _parse_stmt_description(n.description)
        src_counts[src] = src_counts.get(src, 0) + 1
    source_distribution = [
        {"source": k, "count": v}
        for k, v in sorted(src_counts.items(), key=lambda x: -x[1])
    ]

    return {
        "total_statements": len(statements),
        "total_concepts": len(concepts),
        "total_speakers": len(speakers),
        "streak_days": streak,
        "daily_activity": daily_activity,
        "source_distribution": source_distribution,
    }


# ─── Debug runs endpoint ───────────────────────────────────────────────────────

@router.get("/debug/runs")
async def kg_debug_runs(
    _user: User = Depends(dev_user_dep),
) -> list[dict]:
    """Returns recent KG extract pipeline runs (in-memory, last 50)."""
    return list(_run_log)


# ─── Calendar data endpoint ────────────────────────────────────────────────────

@router.get("/calendar-data")
async def kg_calendar_data(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Per-day breakdown with context_types for calendar + heatmap sync.

    Returns last 365 days. Each day includes list of context_types present
    so the calendar can render colored indicator dots per source type.
    """
    nodes = await crud.get_all_nodes(session, user.id)
    statements = [n for n in nodes if n.type == "Statement"]

    today = datetime.now(timezone.utc).date()
    cutoff = today - timedelta(days=364)

    # Build per-day map: date → {types: set, ids: list}
    day_map: dict[str, dict] = {}
    for n in statements:
        d = n.created_at.astimezone(timezone.utc).date() if n.created_at.tzinfo else n.created_at.date()
        if d < cutoff:
            continue
        key = d.isoformat()
        if key not in day_map:
            day_map[key] = {"context_types": [], "statement_ids": []}
        ctx, _ = _parse_stmt_description(n.description)
        if ctx not in day_map[key]["context_types"]:
            day_map[key]["context_types"].append(ctx)
        day_map[key]["statement_ids"].append(str(n.id))

    days = [
        {
            "date": k,
            "total": len(v["statement_ids"]),
            "context_types": v["context_types"],
            "statement_ids": v["statement_ids"],
        }
        for k, v in sorted(day_map.items())
    ]
    return {"days": days}
