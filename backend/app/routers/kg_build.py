"""KG Build pipeline — two-stage HITL graph construction.

Stage 1 (POST /kg/extract): LLM extracts draft claims from Korean text.
  - diary mode   : speaker fixed (usually '나'); claim count follows content (1..N)
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
from datetime import date as _date, datetime, timezone, timedelta
from functools import lru_cache
from typing import Any, Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, UploadFile
from openai import AsyncOpenAI
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..config import get_settings
from ..db import get_session
from ..deps import daily_quota, request_user_dep, require_debug_enabled
from ..rate_limit import KIND_KG_EXTRACT, KIND_STT
from ..entity_types import (
    IDENTITY_ENTITY_TYPE,
    SOURCE_ENTITY_TYPE,
    canonical_identity_type,
    identity_types_compatible,
    is_identity_type,
    is_source_like_type,
    normalize_entity_type,
)
from ..journal_pipeline import transcribe_audio
from ..graph_schema import REL_SPOKE_OR_PUBLISHED
from ..models import Edge, JournalEntry, JournalGraphLink, Node, SpeakerProfile, User
from ..text_coverage import native_ngram_coverage, split_statement_units
from ..speaker_diarization import SpeakerSegment, diarize_audio
from ..storage import save_audio_workfile
from ..temporal import EVENT_STATUSES, resolve_event_temporal

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/kg", tags=["kg-build"])

# Concept auto-linking thresholds (see crud.find_similar_concepts_with_distance).
# Identities use a dedicated alias index at 0.25; concept name_embeddings embed
# "name\ndescription" which adds noise, so we start looser. Every hit is a
# SUGGESTION gated by human review, so a loose threshold only costs noise — it
# never merges nodes silently. Centralized here for one-line tuning.
CONCEPT_SUGGEST_MAX_DISTANCE = 0.35
CONCEPT_SUGGEST_TOP_K = 3


def _ms_since(started: float) -> int:
    """Elapsed milliseconds since a ``time.perf_counter()`` mark."""
    return int((time.perf_counter() - started) * 1000)

# ─── In-memory run log (last 50 extract calls) ───────────────────────────────

_run_log: deque[dict] = deque(maxlen=50)


def _log_run(entry: dict) -> None:
    """Record a run trace only when debug is on — the entries hold raw prompts
    and responses, so production keeps nothing in memory."""
    from ..config import get_settings

    if get_settings().debug_enabled:
        _run_log.appendleft(entry)


# ─── OpenAI client (shared, cached) ──────────────────────────────────────────

@lru_cache
def _llm_client() -> AsyncOpenAI:
    settings = get_settings()
    # Bound the request so a hung OpenAI call fails fast (→ graph_failed) rather
    # than buffering for the SDK default (600s × retries).
    #
    # No retries: extraction runs inside the request (FastAPI BackgroundTasks are
    # awaited by Mangum before the Lambda response returns), so the whole call
    # must fit the 120s function timeout. One retry at the 90s timeout needs 180s
    # — the function is killed first, which skips `_mark_graph_failed` entirely
    # and strands the entry in 'graph_processing' with the client polling forever.
    # A single bounded attempt always leaves room to record the failure.
    return AsyncOpenAI(
        api_key=settings.openai_api_key,
        timeout=settings.openai_timeout_sec,
        max_retries=0,
    )


# ─── Request / Response schemas ──────────────────────────────────────────────

class KgExtractRequest(BaseModel):
    mode: Literal["diary", "external"]
    fixed_speaker: str | None = None        # diary mode: defaults to '나'
    source_category: str | None = None      # external mode: 회의록 / 책 / 뉴스 etc.
    # 4,000자 — 추출 품질이 급격히 떨어지는 지점 이전으로 캡.
    text: str = Field(min_length=1, max_length=4_000)
    existing_nodes: list[str] = Field(default_factory=list)


class ConceptResolutionIn(BaseModel):
    """User's decision for a person-kind concept at commit time (from the review UI).

    action:
      - "link"       → attach the mention to an existing node (`node_id`), aliasing the surface name.
      - "new_person" → create a fresh Identity node for this name. (Wire-format
                       name kept for compatibility with the review UI and older
                       clients; there is no Person type any more.)
      - "concept"    → keep it an ordinary Concept node (downgrade / not an identity after all).
    """
    action: Literal["link", "new_person", "concept"] = "new_person"
    node_id: _uuid.UUID | None = None


class ConceptIn(BaseModel):
    name: str
    # 1-5: how central this concept is to the statement (LLM-assigned, clamped).
    importance: int = Field(default=3, ge=1, le=5)
    # "person" → a named identity (resolves to an Identity/self node, MENTIONS edge);
    # "concept" → an ordinary idea/thing (Concept node, CONTEXT edge).
    # The LLM contract keeps the "person" wording; the server maps it to Identity.
    kind: Literal["person", "concept"] = "concept"
    # Only meaningful for kind="person"; carries the reviewer's resolution decision.
    resolution: ConceptResolutionIn | None = None


class KgClaimIn(BaseModel):
    speaker: str
    # Head-node entity type: "Identity" (화자·개체) or "Source" (매체·기관·AI 출처).
    # Legacy "Person"/"Speaker" from stored drafts and older clients is coerced
    # by _claim_head_type.
    speaker_type: str = IDENTITY_ENTITY_TYPE
    title: str = ""          # short node label (5-7 words); falls back to truncated statement
    statement: str           # full 1-2 sentence content; stored in node description
    concepts: list[ConceptIn] = Field(default_factory=list)
    event_time_text: str | None = None
    temporal_precision: Literal["exact", "day", "range", "month", "relative", "unknown"] = "unknown"
    temporal_confidence: float = Field(default=0.0, ge=0.0, le=1.0)
    event_status: Literal["happened", "planned", "cancelled", "hypothetical", "unknown"] = "happened"
    # Reviewer-confirmed event day. Nothing in the text can tell us when an entry
    # written in plain past tense actually happened ("어제 정리한 대화를 오늘 씀"),
    # so the reviewer's answer outranks every inference when it is present.
    event_date_override: _date | None = None


class KgCommitRequest(BaseModel):
    claims: list[KgClaimIn] = Field(min_length=1)
    context_type: str  # e.g. 'diary', 'meeting', 'book'
    original_text: str = ""
    journal_entry_id: _uuid.UUID | None = None  # optional link for transcript provenance


class TemporalBackfillRequest(BaseModel):
    dry_run: bool = True


# Allowed statement head-node types. Identity and Source never merge by name
# alone (see entity_types.identity_merge_group) — both are valid "화자" (speaker)
# picks, Source included, e.g. an external entity like 기업은행 publishing a
# statement with no voice of its own.
_HEAD_NODE_TYPES = frozenset({IDENTITY_ENTITY_TYPE, SOURCE_ENTITY_TYPE})


def _claim_head_type(raw: str | None) -> str:
    """Sanitize a claim's speaker_type to a valid head-node entity type.

    The compatibility funnel: legacy "Person"/"Speaker"/"화자" from stored
    graph_staging drafts and older review clients all land on "Identity" here,
    which is why this coerces rather than rejects.
    """
    return canonical_identity_type(raw or IDENTITY_ENTITY_TYPE)


async def _resolve_head_node(
    session: AsyncSession,
    user_id: _uuid.UUID,
    name: str,
    head_type: str,
) -> Node:
    """Resolve a statement head (화자/출처) to an existing identity, never forking.

    A head is created by name+type, but a mentioned identity may already exist under
    the same name (e.g. '엄마' first appeared as a MENTIONS target → Identity node).
    Blindly creating a head would fork it. So resolve across the whole 정체성
    category first and reuse whenever the merge groups agree — an Identity head
    reuses an Identity node, a Source head reuses a Source node.

    Speaking does NOT change the node's type. An identity that turns out to be a
    person is marked by its bound voice profile, not by a type promotion.
    An identity↔source name clash falls through to a fresh node.
    """
    name = (name or "").strip()
    head_type = _claim_head_type(head_type)

    existing = await crud.find_identity_node_by_name_or_alias(session, user_id, name)
    if existing is not None:
        if identity_types_compatible(head_type, existing.type):
            crud.add_node_alias(existing, name)
            await session.flush()
            await crud.index_identity_alias(session, user_id, existing, name)
            return existing
        # incompatible role (identity↔source name clash) → create a fresh head node.

    node = await crud._get_or_create_node(
        session, name=name, type_=head_type, user_id=user_id
    )
    await crud.index_identity_alias(session, user_id, node, name)
    return node


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


def _claim_key(entry_id: _uuid.UUID | None, index: int, statement: str) -> str:
    """Stable identity for an event claim; display title is deliberately excluded."""
    namespace = entry_id or _uuid.UUID("00000000-0000-0000-0000-000000000000")
    return str(_uuid.uuid5(namespace, f"{index}:{statement.strip()}"))


def _parse_override_date(raw: Any) -> _date | None:
    """Coerce a reviewer-supplied event day from a model field or JSON string."""
    if raw is None or raw == "":
        return None
    if isinstance(raw, _date) and not isinstance(raw, datetime):
        return raw
    if isinstance(raw, datetime):
        return raw.date()
    try:
        return _date.fromisoformat(str(raw).strip()[:10])
    except ValueError:
        return None


def _claim_temporal_values(claim: Any, recorded_at: datetime) -> dict[str, Any]:
    """Resolve relative times server-side, regardless of whether claim is a dict or model."""
    get = claim.get if isinstance(claim, dict) else lambda key, default=None: getattr(claim, key, default)

    # A reviewer-confirmed day is ground truth: text written in plain past tense
    # carries no signal about when it happened, so no amount of parsing can
    # recover it. Skip resolution entirely rather than let it overwrite them.
    override = _parse_override_date(get("event_date_override"))
    if override is not None:
        tz = ZoneInfo(get_settings().chat_timezone)
        start = datetime(override.year, override.month, override.day, tzinfo=tz)
        anchor = recorded_at if recorded_at.tzinfo is not None else recorded_at.replace(tzinfo=timezone.utc)
        status = (get("event_status") or "happened").strip().lower()
        return {
            "occurred_at": override,
            "recorded_at": recorded_at,
            "event_start_at": start,
            "event_end_at": start + timedelta(days=1),
            "temporal_precision": "user_set",
            "temporal_confidence": 1.0,
            "temporal_source_text": None,
            "temporal_anchor_at": anchor.astimezone(tz),
            "event_status": status if status in EVENT_STATUSES else "happened",
            "event_timezone": get_settings().chat_timezone,
        }

    values = resolve_event_temporal(
        statement=(get("statement", "") or "").strip(),
        entry_at=recorded_at,
        tz_name=get_settings().chat_timezone,
        event_time_text=get("event_time_text"),
        event_status=get("event_status"),
        claimed_precision=get("temporal_precision"),
        claimed_confidence=get("temporal_confidence"),
    )
    return {
        "occurred_at": values.occurred_at,
        "recorded_at": recorded_at,
        "event_start_at": values.start_at,
        "event_end_at": values.end_at,
        "temporal_precision": values.precision,
        "temporal_confidence": values.confidence,
        "temporal_source_text": values.source_text,
        "temporal_anchor_at": values.anchor_at,
        "event_status": values.status,
        "event_timezone": values.timezone,
    }


class KgCommitOut(BaseModel):
    ok: bool
    claims_saved: int
    nodes_upserted: int
    edges_created: int


# ─── LLM system prompt ────────────────────────────────────────────────────────
# Diary (single fixed speaker) and external (multi-speaker source) both emit the
# SAME "claims" list shape — there is no separate single-node schema. Claim COUNT
# is never fixed: a short single-topic diary entry naturally yields 1 claim, a
# longer multi-topic entry yields several. The content_type table below tells the
# LLM what to prioritize per medium (a diary's emotions/actions differ from a
# meeting's agenda/decisions).

_CONTENT_TYPE_GUIDANCE: dict[str, str] = {
    "일기": "감정 상태·변화, 오늘 한 일과 사건, 사람과의 상호작용, 다짐·계획·성찰, 컨디션/몸 상태",
    "대화": "화자별 주장·의견, 화제 전환점, 합의된 것과 이견, 상대에 대한 새 정보(취향·근황), 약속·할 일",
    "회의록": "안건별 결정사항, 담당자·기한이 있는 액션아이템, 쟁점이 된 의견 차이, 다음으로 미뤄진 논의",
    "책": "핵심 주장/개념 정의, 저자의 논증 근거, 인상적 인용구, 챕터의 결론",
    "뉴스": "핵심 사실(누가/무엇을/언제/어디서), 원인과 결과, 이해관계자 반응, 수치·통계",
    "강연": "강연자의 핵심 메시지, 핵심 개념 설명, 예시·사례, 청중을 위한 실천적 조언",
    "논문": "연구 질문/가설, 방법론 핵심, 주요 결과, 결론과 한계",
    "잡지": "기사 핵심 정보, 트렌드·현상 설명, 전문가 인용",
    "자료": "핵심 개념·정의, 요점 정리, 분류·목록의 구조, 실무 적용 포인트, 배경 지식",
}


def _content_type_guidance_block(content_type: str) -> str:
    table = "\n".join(f"- {name}: {rules}" for name, rules in _CONTENT_TYPE_GUIDANCE.items())
    focus = _CONTENT_TYPE_GUIDANCE.get(content_type, "")
    # NOT "above all else". That wording turned this table into a filter: a diary
    # sentence about something outside its list (a data-usage number, a bill, a
    # commute time) scored below the listed items and was dropped from the output
    # entirely. The table decides how claims are SPLIT and TITLED — never whether
    # a sentence survives.
    focus_line = (
        f'\nThis text\'s content_type is "{content_type}" — use the items listed for it as '
        "the primary axis for deciding where one claim ends and the next begins, and for "
        "writing each claim's title. This is a priority order, NOT a filter: content that "
        "falls outside the list must still appear in some claim's statement."
        if focus
        else ""
    )
    return (
        "[CONTENT-TYPE EXTRACTION FOCUS]\n"
        "Different media carry different important information. Use this table to "
        "decide what deserves its own statement:\n"
        f"{table}{focus_line}"
    )


def _build_extraction_system_prompt(
    *, content_type: str, fixed_speaker: str | None, native_language: str = "korean"
) -> str:
    from ..tutor import _lang_label

    native_label = _lang_label(native_language)
    if fixed_speaker:
        speaker_rule = (
            f'- speaker: every claim\'s "speaker" MUST be exactly "{fixed_speaker}" — the '
            "one confirmed narrator. Never invent, infer, or switch to a different "
            "speaker, even if the text seems to quote or mention someone else."
        )
    else:
        speaker_rule = (
            "- speaker: the person or media source who made this claim. Match "
            "existing_nodes if semantically identical."
        )
    return f"""You are a knowledge graph assistant for a {native_label} language learning app.
Extract speaker-attributed statements from the {native_label} source text below.

Return ONLY valid JSON in this exact shape (no markdown, no commentary):
{{
  "contextTypeOptions": ["추천매체1", "추천매체2"],
  "claims": [
    {{
      "speaker": "화자명 또는 출처명",
      "title": "핵심 내용을 담은 5-7단어 제목 (written in {native_label})",
      "statement": "정제된 핵심 진술 (1-2문장 전체 내용, written in {native_label})",
      "event_time_text": "사건 시점을 가리키는 원문 표현; 없으면 null",
      "temporal_precision": "exact | day | range | month | relative | unknown",
      "temporal_confidence": 0.0,
      "event_status": "happened | planned | cancelled | hypothetical | unknown",
      "concepts": [{{"name": "개념1", "importance": 4, "kind": "concept"}}, {{"name": "제니", "importance": 3, "kind": "person"}}]
    }}
  ]
}}

[HOW MANY CLAIMS]
- Split on speaker change OR semantic topic shift within the same speaker.
- Produce as many claims as the content actually contains — there is NO fixed
  count. A short single-topic entry naturally yields 1 claim. A longer entry that
  covers several distinct topics/events/emotions naturally yields several claims.
  Never force everything into 1 claim just because there is only one speaker, and
  never fragment a single coherent thought into multiple claims just to pad the count.

[COVERAGE — NOTHING MAY BE DROPPED]
- Every proposition in the source text MUST appear in exactly one claim's "statement".
- Before you answer, re-read the source sentence by sentence and confirm that each
  one's content is present somewhere in your output. A sentence that fits none of
  your existing claims means you need ANOTHER claim, not that the sentence can go.
- Never keep only the opening sentence of a topic and discard the rest of it.
- Do not repeat the same proposition across two claims either.

{_content_type_guidance_block(content_type)}

[FIELDS]
{speaker_rule}
- title: 5–7 {native_label} words capturing the essence of this claim. Used as the graph node label.
- statement: one self-contained {native_label} statement carrying this claim's FULL
  content. Use as many sentences as the claim actually needs — there is NO sentence
  limit. Remove only filler (어…, 음…, stutters, verbatim repetition); never drop a
  fact, number, time, or consequence, and never truncate to the first sentence.
- event_time_text: copy only the phrase that states when this event happened
  (for example "어제", "지난주 월요일", "tomorrow"). Never invent a date.
- temporal_precision: use "relative" for expressions relative to the entry,
  "day" for one calendar day, "range" for a period, "month" for a month,
  and "unknown" when no timing is stated.
- temporal_confidence: 1.0 for an explicit unambiguous expression, lower only
  when the text itself is ambiguous. The server, not you, resolves relative dates.
- event_status: whether the action the claim describes ALREADY TOOK PLACE.
  Default to "happened" and depart from it only when the text clearly demands it.
  Saying, thinking, worrying, realising, proposing, deciding and discussing are
  themselves completed acts: "체크리스트를 열어두는 방향을 고민해 봤습니다" and
  "깊게 고려하지 못했네요" are both "happened" — the thinking happened, even
  though its subject is a future change. Use "planned" only for an action still
  ahead of the speaker ("내일 보고서를 쓸 예정이다"), "cancelled" only when the
  text says it was called off, "hypothetical" only for an explicitly
  counterfactual or conditional case ("만약 …했다면"), and "unknown" only when
  the text genuinely does not reveal whether it occurred. When in doubt about a
  reflective or conversational claim, choose "happened".
- concepts: 1–5 concrete nouns per claim — NEVER an empty array. Every claim has
  at least one concept: for emotional/reflective claims, extract the TARGET or
  CAUSE of the feeling (e.g. "면접이 생각나 기분이 안 좋았다" → concepts: 면접;
  "사업이 잘 안 된다" → concepts: 사업), not just the emotion word. Each concept
  is an object:
  - name: the concept/entity name.
    NEVER a referring phrase. "두 방법", "둘 다", "그것", "이 부분", "위 내용",
    "전자", "후자" are not concepts — they only mean something inside their own
    sentence, while a concept node is permanent and shared across the entire
    graph, so such a name becomes a dead node that can never match anything.
    Read the OTHER claims and name what the phrase refers to:
      "나는 멀티플보다 현금 흐름이 중요하다고 봤다" / "결국 둘 다 넣기로 했다"
        → the second claim's concepts are 멀티플 and 현금 흐름, NOT "둘 다".
      "결국 두 방법을 모두 적용하기로 했다", after claims about 비교기업 분석 and
        DCF → concepts 비교기업 분석 and DCF, NOT "두 방법".
    If the referent genuinely cannot be recovered from the text, use the claim's
    other nouns; never emit the placeholder itself.
  - importance: 1-5 — how central this concept is to THIS statement (5 = the
    statement is essentially about this concept, 1 = mentioned only in passing).
  - kind: "person" if the name is a PROPER NOUN denoting a specific named entity —
    a person (제니, 재석), a relational term for one real person (엄마, 할머니,
    사장님), a named pet (마야), a company/organization (앤톡, 기업은행), a
    service/AI (Gemini), or a named event/product/place (CES2025, 아이폰). Use
    "concept" for COMMON NOUNS: ideas, emotions, activities, objects, generic
    categories (면접, 두통, 농구, 회의, 사업). When unsure, use "concept".
  - MANDATORY: every person or named entity MENTIONED inside the statement MUST
    appear in concepts with kind "person", IN ADDITION TO the topical nouns —
    never drop a mentioned name because the statement is mainly about something
    else (e.g. "장세영 전임과 함께 대분류를 설계했다" → concepts MUST include
    {{"name": "장세영", "kind": "person"}} alongside 대분류). Strip titles/
    honorifics from the name (장세영 전임 → 장세영, 김 부장님 → 김 부장 is NOT ok,
    use the bare name when one exists).
    The ONLY exception: do NOT tag the statement's own speaker; only OTHER
    entities referred to inside the statement.
- contextTypeOptions: top 2 guesses from [일기, 대화, 회의록, 책, 논문, 뉴스, 강연, 잡지, 자료].
  For casual multi-person talk with no clear medium, use 대화. Use 자료 for AI-generated
  summaries, curated notes, or knowledge compiled from mixed sources.
- Do NOT create Vocab nodes or Subject nodes."""


# ─── User prompt builders ─────────────────────────────────────────────────────

def _diary_user_prompt(
    text: str,
    fixed_speaker: str,
    existing_nodes: list[str],
    *,
    header: str = "Diary text",
) -> str:
    nodes_hint = ", ".join(existing_nodes[:50]) if existing_nodes else "(없음)"
    # "for concept matching" 문구는 작은 모델이 "이 목록에서만 골라라"(닫힌
    # 어휘)로 오해해 concepts를 통째로 비우는 퇴행을 유발한다 — dedup 참고용임을
    # 명시해야 텍스트에 없는 목록이어도 새 개념을 자유롭게 생성한다.
    return (
        f"Fixed speaker: {fixed_speaker}\n"
        f"Existing nodes (dedup reference ONLY — reuse a name if the SAME concept "
        f"appears in the text; otherwise ALWAYS create new concepts freely from "
        f"the text itself): {nodes_hint}\n\n"
        f"--- {header} ---\n{text}"
    )


_CLEAN_LABEL_LINE_RE = re.compile(r"^\s*\[([^\]]+)\]\s*:?\s*(.+)$")


def _clean_text_as_labeled(clean_text: str, speakers: list[str]) -> str | None:
    """정제 전사를 다화자 추출의 라벨 원본으로 승격할 수 있으면 정규화해 돌려준다.

    조건은 둘뿐이다: 모든 줄이 "[이름] 발화" 형태이고, 등장하는 이름이 세그먼트의
    화자 집합 안에 있을 것. 정제 프롬프트는 라벨을 그대로 두라고 지시하지만
    프롬프트는 지켜지지 않을 수 있고, 없는 이름 하나가 그래프의 인물 노드가 되기
    때문에 파이썬에서 다시 검증한다(OCR 화자 검증과 같은 원칙). 줄 수가 세그먼트와
    달라도 괜찮다 — 여기서 필요한 건 1:1 매핑이 아니라 화자가 붙은 정제 본문이다.
    """
    if not clean_text.strip() or not speakers:
        return None
    known = {s.strip() for s in speakers if s.strip()}
    out: list[str] = []
    for raw_line in clean_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        m = _CLEAN_LABEL_LINE_RE.match(line)
        if not m:
            return None
        name = m.group(1).strip()
        if name not in known:
            return None
        out.append(f"[{name}]: {m.group(2).strip()}")
    return "\n".join(out) if out else None


def _external_user_prompt(
    text: str,
    source_category: str,
    existing_nodes: list[str],
    corrected_text: str = "",
) -> str:
    nodes_hint = ", ".join(existing_nodes[:50]) if existing_nodes else "(없음)"
    parts = [
        f"Source category: {source_category}",
        # dedup 참고용임을 명시 — _diary_user_prompt와 같은 이유.
        f"Existing nodes (dedup reference ONLY — reuse a name if the SAME "
        f"entity/concept appears in the text; otherwise ALWAYS create new "
        f"concepts freely from the text itself): {nodes_hint}",
    ]
    if corrected_text.strip():
        # The labeled text keeps speaker attribution but may carry raw STT
        # mishearings; the corrected reference has the fixed wording (e.g. 말차).
        # Use the corrected wording while keeping each [Speaker] attribution.
        parts.append(
            "\n--- Corrected wording reference (use this wording, e.g. 마차→말차) ---\n"
            + corrected_text
        )
    parts.append(f"\n--- Source text (speaker-labeled) ---\n{text}")
    return "\n".join(parts)


# ─── JSON helper ─────────────────────────────────────────────────────────────

# Structured-outputs schema: 프롬프트 순종에 기대지 않고 디코딩 레벨에서
# "concepts 빈 배열"을 불가능하게 만든다 (minItems=1). gpt-4o-mini에서
# 검증 완료 — 2026-07-03 concepts 전량 유실 사고의 재발 방지 1차 방어선.
#
# speaker_matched / concepts_matched are deliberately ABSENT. strict mode forces
# every declared property to be generated, and `_verify_concept_matches` then
# overwrote both from the DB anyway — so asking for them bought nothing and cost
# ~15 decoded tokens per claim on the one call the user actually waits for.
# Output tokens are the whole latency budget here (a 8-claim draft measured 42 s),
# so the flags are computed server-side only.
_EXTRACTION_RESPONSE_FORMAT: dict = {
    "type": "json_schema",
    "json_schema": {
        "name": "kg_claims",
        "strict": True,
        "schema": {
            "type": "object",
            "properties": {
                "contextTypeOptions": {"type": "array", "items": {"type": "string"}},
                "claims": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "properties": {
                            "speaker": {"type": "string"},
                            "title": {"type": "string"},
                            "statement": {"type": "string"},
                            "event_time_text": {"type": ["string", "null"]},
                            "temporal_precision": {
                                "type": "string",
                                "enum": ["exact", "day", "range", "month", "relative", "unknown"],
                            },
                            "temporal_confidence": {"type": "number", "minimum": 0, "maximum": 1},
                            "event_status": {
                                "type": "string",
                                "enum": ["happened", "planned", "cancelled", "hypothetical", "unknown"],
                            },
                            "concepts": {
                                "type": "array",
                                "minItems": 1,
                                "maxItems": 5,
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "name": {"type": "string"},
                                        "importance": {
                                            "type": "integer",
                                            "minimum": 1,
                                            "maximum": 5,
                                        },
                                        "kind": {
                                            "type": "string",
                                            "enum": ["person", "concept"],
                                        },
                                    },
                                    "required": ["name", "importance", "kind"],
                                    "additionalProperties": False,
                                },
                            },
                        },
                        "required": [
                            "speaker",
                            "title",
                            "statement",
                            "event_time_text",
                            "temporal_precision",
                            "temporal_confidence",
                            "event_status",
                            "concepts",
                        ],
                        "additionalProperties": False,
                    },
                },
            },
            "required": ["contextTypeOptions", "claims"],
            "additionalProperties": False,
        },
    },
}


def _parse_llm_json(raw: str) -> Any:
    """Strip markdown code fences then parse JSON."""
    cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw.strip(), flags=re.DOTALL)
    return json.loads(cleaned)


def _require_complete_completion(choice: Any) -> None:
    """Fail with the real reason when the model stopped short of valid JSON.

    A response cut off at the token limit still parses as "text", so json.loads
    raises a JSONDecodeError about some byte offset — which then reaches the user
    as an unexplained graph failure. The finish_reason says exactly what happened.
    """
    reason = getattr(choice, "finish_reason", None)
    if reason == "length":
        raise ValueError(
            "LLM response hit the token limit before finishing the JSON — "
            "the entry is too long or too dense to extract in one call"
        )
    if reason == "content_filter":
        raise ValueError("LLM refused the content (content_filter)")


# ─── Source-coverage guard ────────────────────────────────────────────────────
#
# The prompt asks for every proposition to survive into some claim's statement.
# It is a request, and a model that has decided an entry is "about" one thing
# will still answer with that thing's first sentence and drop the rest. This
# measures what actually came back and spends one repair call when it is short.
#
# A statement-level check, not a word-level one: native_ngram_coverage tolerates
# 어미 changes and filler removal (small tail edits) while a whole missing clause
# takes a large share of the source bigrams with it. See kg_extract_coverage_min.

# A source unit counts as covered well below the whole-entry threshold — partial
# rephrasing of one sentence is normal, wholesale absence is not.
_UNIT_COVERED_MIN = 0.6

# Speaker labels ("[박병준]: …") are attribution, not content: they live on the
# claim's `speaker`, never inside its statement. Scoring them made every
# multi-speaker entry look like it had lost content — a short chat turn is mostly
# label — and bought a full second extraction call on entries that had lost
# nothing. Strip them before measuring.
_SPEAKER_LABEL_RE = re.compile(r"^\s*\[[^\]]{1,40}\]\s*:?\s*")

# Units with no proposition to lose: laughter, interjections, bare
# acknowledgements, emoji/punctuation. A model that folds "ㅋㅋㅋ" into the next
# turn has dropped nothing, so these must not trigger a repair call either.
_FILLER_UNIT_RE = re.compile(
    r"^(?:[ㅋㅎㅠㅜㅡㆍ~!?.,\-…\s]|[0-9]{0,2}"
    r"|음|어|아|와|오|헐|응|네|넵|예|웅|ㅇㅇ|ㄴㄴ|ok|okay|yeah|lol|haha)+$",
    re.IGNORECASE,
)


def _strip_speaker_label(unit: str) -> str:
    return _SPEAKER_LABEL_RE.sub("", unit or "").strip()


def _is_propositional(unit: str) -> bool:
    """True when this source unit asserts something a claim could drop."""
    body = _strip_speaker_label(unit)
    if _FILLER_UNIT_RE.match(body):
        return False
    # Two content characters is the floor for anything nameable; below it the
    # n-gram ratio is noise anyway.
    return len(re.findall(r"[A-Za-z0-9가-힣]", body)) >= 2


def _claim_statements(result: Any) -> list[str]:
    """Every non-empty statement string in an extraction result, in order."""
    if not isinstance(result, dict):
        return []
    return [
        text
        for claim in (result.get("claims") or [])
        if isinstance(claim, dict) and (text := (claim.get("statement") or "").strip())
    ]


def _coverage_report(source: str, result: Any) -> dict[str, Any] | None:
    """Score how much of ``source`` survived, and name what did not.

    Returns None when the entry is too short for the n-gram ratio to mean
    anything — see ``kg_extract_coverage_min_chars``.
    """
    text = (source or "").strip()
    if len(re.sub(r"\s+", "", text)) < get_settings().kg_extract_coverage_min_chars:
        return None
    statements = _claim_statements(result)
    joined = " ".join(statements)
    uncovered: list[str] = []
    ignored: list[str] = []
    for unit in split_statement_units(text):
        body = _strip_speaker_label(unit)
        if native_ngram_coverage(body, joined) >= _UNIT_COVERED_MIN:
            continue
        (uncovered if _is_propositional(unit) else ignored).append(body or unit)
    scored = "\n".join(
        _strip_speaker_label(unit) for unit in split_statement_units(text)
    )
    return {
        "score": round(native_ngram_coverage(scored, joined), 4),
        "uncovered": uncovered,
        # Uncovered but contentless (laughter, "ㅇㅇ", emoji). Kept visible so a
        # skipped repair is explainable, never silent.
        "ignored": ignored,
        "claims": len(statements),
    }


def _coverage_repair_prompt(report: dict[str, Any], native_label: str) -> str:
    missing = "\n".join(f"- {unit}" for unit in report["uncovered"])
    return (
        "Your extraction dropped content from the source text. These source "
        f"sentences do not appear in any claim's statement:\n{missing}\n\n"
        "Return the COMPLETE JSON again, corrected. Rules for the correction:\n"
        "- Do not delete any existing claim and do not change any claim's speaker.\n"
        "- Put each missing sentence's content into the claim it belongs to by "
        "extending that claim's statement, or add a new claim for it when it "
        "belongs to none.\n"
        f"- Statements stay in {native_label}. Keep every fact, number and time "
        "from the missing sentences.\n"
        "- Do not repeat the same proposition in two claims."
    )


async def _ensure_source_coverage(
    *,
    source: str,
    result: Any,
    raw: str,
    system_prompt: str,
    user_prompt: str,
    native_language: str,
    model: str,
) -> tuple[Any, dict[str, Any] | None]:
    """Repair an extraction that lost source content. At most one extra call.

    Returns ``(result, coverage)``. ``coverage`` rides along to the caller so a
    still-incomplete extraction is visible in the run log and the pipeline trace
    rather than looking like a clean success.

    Deliberately does NOT synthesise claims from the missing sentences: a claim
    with no title, concepts or temporal fields would pollute the graph worse than
    the omission does. The human review UI is the real backstop.
    """
    report = _coverage_report(source, result)
    if report is None:
        return result, None
    # The repair is a SECOND full extraction — the single most expensive thing in
    # the draft — so it fires only on a named, propositional loss (`uncovered`).
    # A low global score with every proposition individually present means the
    # model compressed wording, which is what it was asked to do; re-running it
    # there doubled the user's wait and changed nothing. kg_extract_coverage_min
    # still decides what counts as a complete draft in the report.
    if not report["uncovered"]:
        return result, report

    # Local import for the same reason _build_extraction_system_prompt does it.
    from ..tutor import _lang_label

    native_label = _lang_label(native_language)
    repair_started = time.perf_counter()
    try:
        repaired_resp = await _llm_client().chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
                {"role": "assistant", "content": raw},
                {"role": "user", "content": _coverage_repair_prompt(report, native_label)},
            ],
            temperature=0.1,
            response_format=_EXTRACTION_RESPONSE_FORMAT,
        )
        _require_complete_completion(repaired_resp.choices[0])
        repaired = _parse_llm_json(repaired_resp.choices[0].message.content or "{}")
    except Exception as exc:  # noqa: BLE001 — a failed repair must not lose the draft
        logger.warning("kg_extract coverage repair failed: %s", exc)
        return result, {**report, "repaired": False, "repair_ms": _ms_since(repair_started)}

    repair_ms = _ms_since(repair_started)
    repaired_report = _coverage_report(source, repaired)
    # Never accept a repair that covers less than what it replaced. A model asked
    # to add content can restructure and drop something else on the way.
    if repaired_report is None or repaired_report["score"] < report["score"]:
        logger.warning(
            "kg_extract coverage repair regressed (%.3f -> %s); keeping original",
            report["score"],
            None if repaired_report is None else f"{repaired_report['score']:.3f}",
        )
        return result, {**report, "repaired": False, "repair_ms": repair_ms}
    return repaired, {**repaired_report, "repaired": True, "repair_ms": repair_ms}


# ─── Person-mention enrichment (draft review) ─────────────────────────────────

def _existing_nodes_hint(all_nodes: list[Node]) -> list[str]:
    """Node-name hints for the extraction prompt, with identity aliases inlined.

    Identity-category nodes render as "이름 (별칭: a, b)" so the LLM can map a variant
    surface form to the canonical identity even before that variant is learned.
    """
    hints: list[str] = []
    for n in all_nodes:
        name = (n.name or "").strip()
        if not name:
            continue
        aliases = [a for a in (n.aliases or []) if isinstance(a, str) and a.strip()]
        if aliases and is_identity_type(n.type):
            shown = ", ".join(aliases[:4])
            hints.append(f"{name} (별칭: {shown})")
        else:
            hints.append(name)
    return hints




def _iter_concepts(claims: list[dict]):
    """Yield every concept dict across all claims."""
    for claim in claims:
        for c in (claim.get("concepts") or []):
            if isinstance(c, dict):
                yield c


async def _enrich_person_concepts(
    session: AsyncSession,
    user_id: _uuid.UUID,
    claims: list[dict],
) -> None:
    """Auto-resolve each mentioned name against known identities, in place.

    Two passes, both leave any name the reviewer already decided (has ``resolution``)
    untouched:

    1. EXACT (name or learned alias) — a certain match. Promotes the concept to
       kind=person and pre-selects resolution={action:"link", …}. Applies even to
       LLM-tagged concept names (갭 A): '장세영' tagged concept still surfaces as a
       linked identity when it's a known alias of 나.
    2. FUZZY (name-embedding similarity) — an uncertain guess for names still
       unmatched. Emits resolution={action:"suggest", …}; never auto-links, so a
       homonym can't silently merge. The user confirms with one tap (→ link), which
       learns the alias so the same surface auto-resolves next time.
    """
    unresolved: list[dict] = []
    # One lookup per DISTINCT surface, not per occurrence. A draft repeats the
    # same name across turns (a 9-turn chat log asked for 이영호 four times), and
    # every repeat was a separate sequential round trip on the request the user
    # is watching.
    seen: dict[str, list] = {}
    for c in _iter_concepts(claims):
        if isinstance(c.get("resolution"), dict):
            continue  # reviewer/prior pass already decided
        name = str(c.get("name") or "").strip()
        if not name:
            continue
        if name in seen:
            candidates = seen[name]
        else:
            candidates = await crud.find_identity_candidates_by_base_name(
                session, user_id, name
            )
            seen[name] = candidates
        if len(candidates) == 1 and candidates[0][1]:
            # Exactly one identity shares this name, and it agrees down to
            # whitespace (covers both an exact match and a pure spacing variant
            # like "하승목 연구원" vs "하승목연구원") — safe to auto-link.
            match = candidates[0][0]
            c["kind"] = "person"
            c["resolution"] = {
                "action": "link",
                "node_id": str(match.id),
                "matched_name": match.name,
                "is_self": bool(match.is_self),
            }
        elif candidates:
            # Either >=2 identities share this base name (homonym risk) or the
            # single match only agrees after stripping a title/honorific —
            # both are surface-level ambiguity the reviewer should confirm,
            # never a silent auto-merge. Self-first ordering already puts the
            # owner's own identity first when it's among the candidates.
            match = candidates[0][0]
            c["kind"] = "person"
            c["resolution"] = {
                "action": "suggest",
                "node_id": str(match.id),
                "matched_name": match.name,
                "matched_alias": match.name,
                "is_self": bool(match.is_self),
            }
        else:
            unresolved.append(c)

    await _suggest_identity_by_embedding(session, user_id, unresolved)


async def _suggest_identity_by_embedding(
    session: AsyncSession,
    user_id: _uuid.UUID,
    unresolved: list[dict],
) -> None:
    """Fuzzy pass: for names with no exact identity match, embed each and find the
    nearest indexed identity. A hit becomes a SUGGESTION (action="suggest") — never
    an auto-link — so a homonym can't silently merge; the user confirms with one tap.

    Best-effort and cost-gated: skipped entirely when the user has no alias
    embeddings yet, and all names are embedded in a single batch call.
    """
    pairs = [
        (c, str(c.get("name") or "").strip())
        for c in unresolved
        if str(c.get("name") or "").strip()
    ]
    if not pairs:
        return
    if not await crud.user_has_alias_embeddings(session, user_id):
        return

    from ..rag import embed_texts

    # Embed and search each distinct surface once — a repeated mention costs one
    # embedding slot and one vector query, not one per occurrence.
    names = list(dict.fromkeys(name for _, name in pairs))
    try:
        vectors = await embed_texts(names)
    except Exception:
        logger.warning("identity alias fuzzy-match: embedding call failed", exc_info=True)
        return

    hits: dict[str, Any] = {}
    for name, vec in zip(names, vectors):
        hits[name] = await crud.find_identity_by_alias_embedding(session, user_id, vec)

    for c, name in pairs:
        hit = hits.get(name)
        if hit is None:
            continue
        node, matched_text, dist = hit
        c["kind"] = "person"
        c["resolution"] = {
            "action": "suggest",
            "node_id": str(node.id),
            "matched_name": node.name,
            "matched_alias": matched_text,
            "is_self": bool(node.is_self),
            "distance": round(dist, 4),
        }


async def _enrich_plain_concepts(
    session: AsyncSession,
    user_id: _uuid.UUID,
    claims: list[dict],
) -> None:
    """Link plain concepts to existing Concept nodes, in place — the Concept-side
    mirror of :func:`_enrich_person_concepts`. Runs AFTER it so identity resolution
    always wins (a name resolved to an identity is left alone).

    Two passes, both skipping any concept the reviewer/a prior pass already decided
    (has ``resolution``):

    1. EXACT (canonical name or learned alias) — a certain match. ``action="link"``.
       An alias hit (surface differs from the node's canonical name) MUST be honored
       at commit by node_id, otherwise name-based get_or_create would fork a node.
    2. FUZZY (name-embedding similarity) — an uncertain guess for the rest.
       ``action="suggest"`` with a candidate list; never auto-links (homonyms like
       "면접"=interview vs a company named "면접" must not silently merge). One tap
       confirms → the surface is learned as an alias for next time.
    """
    unresolved: list[dict] = []
    exact: dict[str, Any] = {}  # one lookup per distinct surface (see identity pass)
    for c in _iter_concepts(claims):
        if isinstance(c.get("resolution"), dict):
            continue  # identity pass / reviewer already decided
        if str(c.get("kind") or "concept").strip().lower() != "concept":
            continue  # only plain concepts (person mentions handled elsewhere)
        name = str(c.get("name") or "").strip()
        if not name:
            continue
        if name in exact:
            existing = exact[name]
        else:
            existing = await crud.find_concept_node_by_name_or_alias(
                session, user_id, name
            )
            exact[name] = existing
        if existing is not None:
            match = "exact" if crud._norm_surface(existing.name) == crud._norm_surface(
                name
            ) else "alias"
            c["resolution"] = {
                "action": "link",
                "node_id": str(existing.id),
                "matched_name": existing.name,
                "match": match,
            }
        else:
            unresolved.append(c)

    if not unresolved:
        return
    if not await crud.user_has_concept_embeddings(session, user_id):
        return

    from ..rag import embed_texts

    names = list(
        dict.fromkeys(str(c.get("name") or "").strip() for c in unresolved)
    )
    try:
        vectors = await embed_texts(names)
    except Exception:
        logger.warning("concept fuzzy-match: embedding call failed", exc_info=True)
        return

    by_name: dict[str, list] = {}
    for name, vec in zip(names, vectors):
        by_name[name] = await crud.find_similar_concepts_with_distance(
            session,
            user_id,
            vec,
            limit=CONCEPT_SUGGEST_TOP_K,
            max_distance=CONCEPT_SUGGEST_MAX_DISTANCE,
        )

    for c in unresolved:
        hits = by_name.get(str(c.get("name") or "").strip()) or []
        if not hits:
            continue
        best, best_dist = hits[0]
        c["resolution"] = {
            "action": "suggest",
            "node_id": str(best.id),
            "matched_name": best.name,
            "distance": round(best_dist, 4),
            "candidates": [
                {
                    "node_id": str(n.id),
                    "name": n.name,
                    "distance": round(d, 4),
                    "description": (n.description or "")[:120],
                }
                for n, d in hits
            ],
        }


async def _person_candidates_payload(
    session: AsyncSession, user_id: _uuid.UUID
) -> list[dict]:
    """Existing identity nodes (self / Person / Source / Identity) offered in the
    review picker for a mention."""
    nodes = await crud.list_identity_reference_candidates(session, user_id)
    return [
        {"id": str(n.id), "name": n.name, "is_self": bool(n.is_self)}
        for n in nodes
    ]


# ─── Referring-phrase concepts ────────────────────────────────────────────────

# Phrases that only denote something inside their own sentence. The extraction
# prompt asks for 1–5 concepts and the response schema enforces minItems=1 (see
# the 2026-07-03 concept-loss guard), so a claim whose real subject was named in
# an EARLIER claim — "결국 두 방법을 모두 적용하기로 했다" — leaves the model no
# way to comply except to emit the placeholder. Committed, it becomes a
# permanent node that can never match anything and that quizzes can be built
# from. The prompt now asks for the referent instead; this is the net under it.
_REFERRING_CONCEPTS = frozenset(
    {
        "두 방법", "세 방법", "두 가지", "세 가지", "두 안", "양쪽", "둘 다",
        "그것", "그거", "이것", "이거", "저것", "저거", "그 부분", "이 부분",
        "그 점", "이 점", "그 내용", "이 내용", "위 내용", "해당 내용",
        "그 이야기", "이 이야기", "그 얘기", "이 얘기", "해당 부분",
        "전자", "후자", "위의 것", "앞서 말한 것",
        "it", "this", "that", "these", "those", "the former", "the latter",
        "both", "both ways", "the two", "the above",
    }
)


def _drop_referring_concepts(claims: list[dict]) -> int:
    """Strip placeholder concepts in place; returns how many were removed.

    A claim CAN end up with zero concepts here — "결국 둘 다 넣기로 했다" carries
    nothing else — and that is the intended outcome. _persist_claims still writes
    the Statement node and its speaker edge; only the CONTEXT edge is skipped. The
    minItems=1 response schema is untouched, so the wholesale concept loss it
    guards against remains impossible; this drops only phrases that are
    provably contentless outside their own sentence.
    """
    removed = 0
    for claim in claims:
        if not isinstance(claim, dict):
            continue
        concepts = [c for c in (claim.get("concepts") or []) if isinstance(c, dict)]
        kept = [
            c
            for c in concepts
            if (c.get("name") or "").strip().casefold() not in _REFERRING_CONCEPTS
        ]
        if len(kept) == len(concepts):
            continue
        # concepts_matched is positional — rebuild it against the kept concepts
        # or every downstream flag shifts onto the wrong name.
        flags = claim.get("concepts_matched")
        if isinstance(flags, list) and len(flags) == len(concepts):
            keep_ids = {id(c) for c in kept}
            claim["concepts_matched"] = [
                f for c, f in zip(concepts, flags) if id(c) in keep_ids
            ]
        removed += len(concepts) - len(kept)
        claim["concepts"] = kept
    return removed


# ─── DB-verified concept matching ─────────────────────────────────────────────

async def _verify_concept_matches(
    result: dict,
    session: AsyncSession,
    user_id: _uuid.UUID,
) -> None:
    """Override LLM's matched flags with ground truth from the DB.

    LLMs hallucinate matched=true even when the existing_nodes list is empty
    or when a similarly-named (but deleted) node was seen in training data.
    Writes verified flags directly onto each claim's speaker_matched/
    concepts_matched — the fields the frontend reads.
    """
    claims: list[dict] = result.get("claims") or []
    known: dict[str, bool] = {}

    async def _exists(name: str) -> bool:
        # Names repeat heavily across claims (every turn carries its speaker), and
        # this used to issue one query per occurrence.
        if name not in known:
            known[name] = bool(await crud.find_nodes_by_name(session, user_id, name))
        return known[name]

    for claim in claims:
        if not isinstance(claim, dict):
            continue
        concepts = [c for c in (claim.get("concepts") or []) if isinstance(c, dict)]
        matched_flags: list[bool] = []
        for c in concepts:
            name = (c.get("name") or "").strip()
            matched_flags.append(await _exists(name) if name else False)
        claim["concepts_matched"] = matched_flags

        speaker_name: str = (claim.get("speaker") or "").strip()
        if speaker_name:
            claim["speaker_matched"] = await _exists(speaker_name)


# ─── Endpoints ────────────────────────────────────────────────────────────────

@router.post("/extract")
async def kg_extract(
    body: KgExtractRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _quota: None = Depends(daily_quota(KIND_KG_EXTRACT)),
) -> dict:
    """Stage 1 — LLM drafts claims from Korean text. Nothing persisted yet.

    speaker_matched/concepts_matched are re-verified against the actual DB after
    the LLM responds, so hallucinated matches are always corrected.
    """
    settings = get_settings()
    native_language = getattr(user, "native_language", "korean") or "korean"

    if body.mode == "diary":
        speaker = (body.fixed_speaker or "").strip() or "나"
        system_prompt = _build_extraction_system_prompt(
            content_type="개인일기", fixed_speaker=speaker, native_language=native_language
        )
        user_prompt = _diary_user_prompt(body.text, speaker, body.existing_nodes)
    else:
        category = (body.source_category or "텍스트").strip()
        system_prompt = _build_extraction_system_prompt(
            content_type=category, fixed_speaker=None, native_language=native_language
        )
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
            response_format=_EXTRACTION_RESPONSE_FORMAT,
        )
        _require_complete_completion(resp.choices[0])
        raw = resp.choices[0].message.content or "{}"
        result = _parse_llm_json(raw)

        # Before anything downstream reshapes the claims: check that the entry's
        # sentences actually survived, and spend one repair call if they did not.
        result, coverage = await _ensure_source_coverage(
            source=body.text,
            result=result,
            raw=raw,
            system_prompt=system_prompt,
            user_prompt=user_prompt,
            native_language=native_language,
            model=settings.openai_model,
        )

        # Diary mode: never trust the LLM's speaker field — it's fixed.
        # speaker_matched is recomputed against the DB just below anyway.
        if body.mode == "diary":
            for claim in result.get("claims") or []:
                if isinstance(claim, dict):
                    claim["speaker"] = speaker

        # ── Drop placeholder concepts before anything indexes them ─────────────
        _drop_referring_concepts(
            [c for c in (result.get("claims") or []) if isinstance(c, dict)]
        )

        # ── Re-verify matched flags against actual DB (LLMs hallucinate) ────────
        await _verify_concept_matches(result, session, user.id)

        # ── Pre-resolve person mentions + attach picker candidates ──────────────
        claims_list = [c for c in (result.get("claims") or []) if isinstance(c, dict)]
        await _enrich_person_concepts(session, user.id, claims_list)
        await _enrich_plain_concepts(session, user.id, claims_list)
        result["person_candidates"] = await _person_candidates_payload(session, user.id)

        latency_ms = int((time.monotonic() - t0) * 1000)
        # A draft that still lost sentences after its repair attempt is NOT "ok".
        # Naming it in the run log is what makes the loss findable later; the
        # reviewer's own eyes on the draft are the safety net in the moment.
        incomplete = bool(coverage and not coverage.get("repaired") and coverage["uncovered"])
        if coverage is not None:
            result["coverage"] = coverage
        _log_run({
            "run_id": run_id,
            "mode": body.mode,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": "low_coverage" if incomplete else "ok",
            "coverage": coverage,
            "latency_ms": latency_ms,
            "token_in": resp.usage.prompt_tokens if resp.usage else None,
            "token_out": resp.usage.completion_tokens if resp.usage else None,
            "system_prompt": system_prompt,
            "user_prompt": user_prompt,
            "raw_response": raw,
        })
        return result
    except json.JSONDecodeError as exc:
        _log_run({
            "run_id": run_id, "mode": body.mode,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": "json_error", "latency_ms": int((time.monotonic() - t0) * 1000),
            "system_prompt": system_prompt, "user_prompt": user_prompt, "raw_response": raw,
        })
        logger.warning("kg_extract JSON parse error: %s | raw=%s", exc, raw[:200])
        raise HTTPException(status_code=502, detail=f"LLM 응답 파싱 실패: {exc}")
    except Exception as exc:
        _log_run({
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
    background_tasks: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> KgCommitOut:
    """Stage 2 — persist human-verified claims into the graph (PostgreSQL).

    Graph structure per claim:
        (Identity/Source) --SPOKE_OR_PUBLISHED--> (Statement) --CONTEXT--> (Concept...)
    """
    node_ids: set[str] = set()
    edge_ids: set[str] = set()
    statement_node_ids: set[str] = set()

    recorded_at = datetime.now(timezone.utc)
    if body.journal_entry_id is not None:
        source_entry = await crud.get_journal_entry(session, body.journal_entry_id, user.id)
        if source_entry is not None and source_entry.created_at:
            recorded_at = source_entry.created_at

    for claim_index, claim in enumerate(body.claims):
        speaker_name = (claim.speaker or "").strip()
        statement_text = (claim.statement or "").strip()
        if not speaker_name or not statement_text:
            logger.debug("kg_commit: skipping empty claim")
            continue

        # ── Speaker / Source node (identity-resolved, never forked) ──────────
        speaker_node = await _resolve_head_node(
            session, user.id, speaker_name, claim.speaker_type
        )
        node_ids.add(str(speaker_node.id))

        # ── Statement node ───────────────────────────────────────────────────
        # name        = short title (5-7 words) — graph node label
        # description = JSON {"context_type": ..., "content": ...}
        title = (claim.title or "").strip() or statement_text[:40]
        stmt_description = _make_stmt_description(body.context_type, statement_text)
        temporal = _claim_temporal_values(claim, recorded_at)
        stmt_node = await crud._get_or_create_node(
            session,
            name=title,
            type_="Statement",
            description=stmt_description,
            user_id=user.id,
            claim_key=_claim_key(body.journal_entry_id, claim_index, statement_text),
            **temporal,
        )
        node_ids.add(str(stmt_node.id))
        statement_node_ids.add(str(stmt_node.id))

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

        # ── Concept / Person mention nodes + edges ───────────────────────────
        for concept in claim.concepts:
            await _persist_concept(
                session,
                user.id,
                stmt_node,
                name=concept.name,
                importance=concept.importance,
                kind=concept.kind,
                action=concept.resolution.action if concept.resolution else None,
                node_id=(
                    str(concept.resolution.node_id)
                    if concept.resolution and concept.resolution.node_id
                    else None
                ),
                node_ids=node_ids,
                edge_ids=edge_ids,
            )

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

    # ── Embed new Statement/Concept nodes so future drafts can fuzzy-link ──────
    try:
        from ..rag import ensure_statement_embeddings

        await ensure_statement_embeddings(session, user.id)
    except Exception:
        logger.warning("kg_commit: embedding backfill failed", exc_info=True)

    if statement_node_ids:
        from ..quiz_materials import analyse_nodes_and_refill_background

        background_tasks.add_task(
            analyse_nodes_and_refill_background,
            user.id,
            [_uuid.UUID(value) for value in statement_node_ids],
            crud.get_effective_target_languages(user),
        )

    return KgCommitOut(
        ok=True,
        claims_saved=len(body.claims),
        nodes_upserted=len(node_ids),
        edges_created=len(edge_ids),
    )


# ─── Concept ↔ Identity 재분류 ────────────────────────────────────────────────
# For nodes created before person-mention resolution existed: a name like '할머니'
# that was stored as a Concept can be promoted to an Identity node, or merged into
# an already-existing identity (reassigning its edges). See [[project_immutable_graph_model]]
# — this is an explicit user-driven correction, the one place edge surgery is allowed.

class ReclassifyNodeRequest(BaseModel):
    # "Person" is accepted only for older clients and is normalized to
    # "Identity" by the handler; there is no Person type any more.
    to_type: Literal["Person", "Identity", "Source", "Concept"] = "Identity"
    # When set, merge this node INTO the target identity instead of just retyping.
    merge_into: _uuid.UUID | None = None


@router.get("/nodes/person-migration-suggestions")
async def kg_person_migration_suggestions(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Concept nodes whose name exactly matches an existing identity (self /
    Person / Source / Identity) — likely identities mis-stored as concepts before
    resolution existed.

    Each suggestion offers merging the Concept into the matched identity node.
    """
    nodes = await crud.get_all_nodes(session, user.id)
    people = [n for n in nodes if is_identity_type(n.type) and n.deleted_at is None]
    person_by_key: dict[str, Node] = {}
    for p in people:
        person_by_key.setdefault((p.name or "").strip().lower(), p)
        for a in crud.node_alias_keys(p):
            person_by_key.setdefault(a, p)

    suggestions: list[dict] = []
    for n in nodes:
        if n.deleted_at is not None or normalize_entity_type(n.type) != "Concept":
            continue
        match = person_by_key.get((n.name or "").strip().lower())
        if match is None:
            continue
        suggestions.append({
            "concept_id": str(n.id),
            "concept_name": n.name,
            "person_id": str(match.id),
            "person_name": match.name,
            "is_self": bool(match.is_self),
        })
    return {"suggestions": suggestions}


@router.post("/aliases/reindex")
async def kg_reindex_aliases(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Backfill alias embeddings for identity nodes missing them (self-heal older
    data so fuzzy resolution covers already-learned aliases)."""
    indexed = await crud.backfill_alias_embeddings(session, user.id)
    await session.commit()
    return {"ok": True, "indexed": indexed}


@router.post("/nodes/{node_id}/reclassify")
async def kg_reclassify_node(
    node_id: _uuid.UUID,
    body: ReclassifyNodeRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Promote/retype a node, or merge it into another identity.

    - merge_into set → reassign this node's edges onto the target and delete it,
      carrying the old name over as an alias so future mentions auto-resolve.
    - otherwise → change the node's type in place (e.g. Concept → Identity),
      realigning its Statement relations and alias index to match.
    """
    node = await session.get(Node, node_id)
    if node is None or node.user_id != user.id or node.deleted_at is not None:
        raise HTTPException(status_code=404, detail="노드를 찾을 수 없습니다.")

    if body.merge_into is not None:
        if body.merge_into == node_id:
            raise HTTPException(status_code=400, detail="자기 자신과 병합할 수 없습니다.")
        if node.is_self:
            raise HTTPException(
                status_code=400,
                detail="'나' 노드는 다른 노드에 병합할 수 없습니다. 반대로 그 노드를 '나'에 병합하세요.",
            )
        target = await session.get(Node, body.merge_into)
        if target is None or target.user_id != user.id or target.deleted_at is not None:
            raise HTTPException(status_code=404, detail="대상 노드를 찾을 수 없습니다.")
        merged_name = node.name
        crud.add_node_alias(target, merged_name)
        reassigned = await crud.merge_node_into(session, user.id, node.id, target.id)
        await session.flush()
        # Learn the merged name as a fuzzy alias of the surviving identity.
        await crud.index_identity_alias(session, user.id, target, merged_name)
        await session.commit()
        return {
            "ok": True,
            "merged": True,
            "target_id": str(target.id),
            "edges_reassigned": reassigned,
        }

    requested = normalize_entity_type(body.to_type)
    # Legacy "Person" from an older client folds into Identity.
    if is_identity_type(requested):
        requested = canonical_identity_type(requested)
    # Realigns MENTIONS ↔ CONTEXT and the alias index along with the type.
    fixup = await crud.apply_type_change(session, user.id, node, requested)
    await session.commit()
    return {
        "ok": True,
        "merged": False,
        "node_id": str(node.id),
        "type": node.type,
        **fixup,
    }


# ─── Shared claim persistence ─────────────────────────────────────────────────

async def _confirmed_speaker_identity(
    session: AsyncSession,
    user_id: _uuid.UUID,
    entry_id: _uuid.UUID,
    session_label: str,
) -> tuple[str | None, str | None]:
    """Confirmed graph identity (name, entity type) for a diarization label, if any.

    Prefers the linked node's name/type (the canonical identity — Person, Source,
    or the self node), then a confirmed new-name display name with no type yet
    (node doesn't exist until commit). (None, None) when still unconfirmed.
    """
    appearance = await crud.get_speaker_appearance_for_label(
        session, entry_id, session_label
    )
    if appearance is None:
        return None, None
    profile = await session.get(SpeakerProfile, appearance.speaker_profile_id)
    if profile is None or profile.user_id != user_id:
        return None, None
    if profile.node_id is not None:
        node = await session.get(Node, profile.node_id)
        if node is not None and node.user_id == user_id:
            name = (node.name or "").strip() or None
            return name, (normalize_entity_type(node.type) if name else None)
    return (profile.display_name or "").strip() or None, None


async def _confirmed_speaker_name(
    session: AsyncSession,
    user_id: _uuid.UUID,
    entry_id: _uuid.UUID,
    session_label: str,
) -> str | None:
    """Confirmed graph identity NAME for a diarization label — see
    _confirmed_speaker_identity for the (name, type) pair."""
    name, _type = await _confirmed_speaker_identity(session, user_id, entry_id, session_label)
    return name


async def _entry_label_identity_map(
    session: AsyncSession,
    user_id: _uuid.UUID,
    entry_id: _uuid.UUID,
) -> tuple[dict[str, str], dict[str, str]]:
    """diarization label → (confirmed identity name, confirmed identity type).

    Lets statements attach to the CONFIRMED speaker (제니 / the self node / an
    external Source like 기업은행) instead of the raw 'Speaker_1' label the LLM
    sees in the transcript — so the statement edge and the voice link land on the
    SAME node, not two split ones. The type map lets a multi-speaker entry build a
    Source head for a confirmed Source speaker instead of defaulting every claim
    to Person (see _claim_head_type / _resolve_head_node).
    """
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    names: dict[str, str] = {}
    types: dict[str, str] = {}
    for app in appearances:
        label = (app.session_label or "").strip()
        if not label:
            continue
        name, node_type = await _confirmed_speaker_identity(session, user_id, entry_id, label)
        if name:
            names[label] = name
        if node_type:
            types[label] = node_type
    return names, types


async def _link_confirmed_voices_to_nodes(
    session: AsyncSession,
    user_id: _uuid.UUID,
    entry_id: _uuid.UUID,
) -> None:
    """Bind each confirmed speaker's voice profile to its graph node.

    Confirming a NEW name only stores the embedding on the profile (node created
    later at build). After _persist_claims has created the nodes, link the
    embedding to its node so e.g. '엄마' carries voice — not just the profile.
    Profiles already linked (existing node / as-self) or without an embedding or a
    confirmed name are skipped.

    If the name already exists as a mentioned ``Identity`` node it is reused
    rather than forking a second node — the mention and the voice converge. The
    node's type does not change: the bound voice profile IS the record that this
    identity is a real person. External ``Source`` nodes never receive a voice.
    """
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    for app in appearances:
        profile = await session.get(SpeakerProfile, app.speaker_profile_id)
        if profile is None or profile.user_id != user_id:
            continue
        if profile.node_id is not None or profile.embedding is None:
            continue
        name = (profile.display_name or "").strip()
        if not name or name == "나":
            continue
        node = await crud.find_identity_node_by_name_or_alias(session, user_id, name)
        if node is not None and is_source_like_type(node.type):
            node = None  # never attach a voice to an external 출처
        if node is None:
            node = await crud._get_or_create_node(
                session, name=name, type_=IDENTITY_ENTITY_TYPE, user_id=user_id
            )
        await crud.index_identity_alias(session, user_id, node, name)
        await crud.assign_exclusive_voice_profile_to_node(
            session, user_id, profile, node, display_name=name
        )


def _normalize_concept_dict(
    raw: Any,
) -> tuple[str, int, str, str | None, str | None]:
    """(name, importance 1-5, kind, resolution_action, resolution_node_id).

    Accepts a draft concept as a dict (new), or a bare string (legacy → concept).
    """
    if isinstance(raw, dict):
        name = str(raw.get("name") or "").strip()
        try:
            importance = int(raw.get("importance", 3))
        except (TypeError, ValueError):
            importance = 3
        kind = str(raw.get("kind") or "concept").strip().lower()
        if kind not in ("person", "concept"):
            kind = "concept"
        action: str | None = None
        node_id: str | None = None
        res = raw.get("resolution")
        if isinstance(res, dict):
            action = (str(res.get("action") or "").strip().lower()) or None
            nid = res.get("node_id")
            node_id = str(nid) if nid else None
        return name, max(1, min(5, importance)), kind, action, node_id
    if isinstance(raw, str):
        return raw.strip(), 3, "concept", None, None
    return "", 3, "concept", None, None


async def _resolve_person_concept(
    session: AsyncSession,
    user_id: _uuid.UUID,
    name: str,
    action: str | None,
    node_id: str | None,
) -> Node | None:
    """The identity node a person-mention attaches to, or None to fall back to an
    ordinary Concept node (the reviewer downgraded it).

    A genuinely-new mention becomes an ``Identity`` node — the general 정체성
    category. We can't tell a human (할머니) from a pet (마야) or a group here, and
    we don't need to: humanity is recorded by a bound voice profile, not by the
    type. ``Source`` is the only other identity type, for 외부 출처. Registers the
    surface name as an alias whenever it links to a differently-named identity.
    """
    if action == "concept":
        return None  # user decided it's not an identity after all

    if action == "link" and node_id:
        try:
            target = await session.get(Node, _uuid.UUID(str(node_id)))
        except (ValueError, TypeError):
            target = None
        if (
            target is not None
            and target.user_id == user_id
            and target.deleted_at is None
        ):
            # Learn the surface form: alias list (exact) + embedding index (fuzzy),
            # so this variant auto-resolves next time and its neighbours get suggested.
            crud.add_node_alias(target, name)
            await session.flush()
            await crud.index_identity_alias(session, user_id, target, name)
            return target
        # stale/invalid id → fall through to name resolution / creation

    # Auto-resolve by name or alias across the whole identity category (also covers
    # new_person that in fact already exists, and the no-resolution one-shot path).
    existing = await crud.find_identity_node_by_name_or_alias(session, user_id, name)
    if existing is not None:
        return existing

    # Genuinely new mention → an Identity node (NEVER a Concept).
    node = await crud._get_or_create_node(
        session, name=name, type_=IDENTITY_ENTITY_TYPE, user_id=user_id
    )
    await crud.index_identity_alias(session, user_id, node, name)
    return node


async def _resolve_linked_concept(
    session: AsyncSession,
    user_id: _uuid.UUID,
    name: str,
    node_id: str | None,
) -> Node | None:
    """The existing Concept node a reviewer-confirmed concept link points at, or
    None on a stale/foreign/non-concept id (caller falls back to name-based
    get_or_create). Learns this surface form as an alias so the next extraction
    exact-matches it. Unlike identities, concepts are NOT indexed in
    NodeAliasEmbedding — they already carry name_embedding for fuzzy hits."""
    if not node_id:
        return None
    try:
        target = await session.get(Node, _uuid.UUID(str(node_id)))
    except (ValueError, TypeError):
        return None
    if (
        target is None
        or target.user_id != user_id
        or target.deleted_at is not None
        or normalize_entity_type(target.type) != "Concept"
    ):
        return None
    crud.add_node_alias(target, name)
    await session.flush()
    return target


async def _persist_concept(
    session: AsyncSession,
    user_id: _uuid.UUID,
    stmt_node: Node,
    *,
    name: str,
    importance: int,
    kind: str,
    action: str | None,
    node_id: str | None,
    node_ids: set[str],
    edge_ids: set[str],
) -> None:
    """Attach one extracted concept to a Statement.

    person (정체성) → resolve to an identity node, Statement --MENTIONS--> identity.
    concept        → Concept node, Statement --CONTEXT--> Concept.
    Importance accumulates on ALL: recurring nodes matter like recurring themes.

    Two kinds of resolution can point this surface form at an EXISTING node:
      - identity_target: a person mention, or a kind=concept name that already
        resolved to an identity (stickiness). Edge = MENTIONS.
      - concept_target: a reviewer-confirmed link to an existing Concept node
        (Feature A auto-linking). Edge = CONTEXT — a linked concept is still a
        concept, so it must NOT get an identity-style MENTIONS edge.

    Precedence: an explicit reviewer concept-link (action="link" on a concept)
    wins over the implicit sticky-identity check. Stickiness otherwise holds:
    LLM tagging is inconsistent, so one promotion (review sheet / reclassify)
    must persist. The single opt-out is an EXPLICIT reviewer decision
    (action="concept"), which always yields a plain Concept node.
    """
    name = (name or "").strip()
    if not name:
        return
    explicit_concept = action == "concept"

    identity_target: Node | None = None
    concept_target: Node | None = None

    if kind == "person" and not explicit_concept:
        identity_target = await _resolve_person_concept(
            session, user_id, name, action, node_id
        )
    elif not explicit_concept:
        # kind=concept: an explicit reviewer link to an existing concept wins;
        # otherwise fall back to the sticky-identity check.
        if action == "link":
            concept_target = await _resolve_linked_concept(
                session, user_id, name, node_id
            )
        if concept_target is None:
            identity_target = await crud.find_identity_node_by_name_or_alias(
                session, user_id, name
            )

    if identity_target is not None:
        identity_target.importance_score = (identity_target.importance_score or 0) + importance
        node_ids.add(str(identity_target.id))
        m_edge = await crud.create_edge(
            session, source_id=stmt_node.id, target_id=identity_target.id,
            relation="MENTIONS", user_id=user_id,
        )
        if m_edge:
            edge_ids.add(str(m_edge.id))
        return

    # Plain concept: a reviewer-linked existing node, else get-or-create by name.
    if concept_target is not None:
        concept_target.importance_score = (concept_target.importance_score or 0) + importance
        concept_node = concept_target
    else:
        concept_node = await crud._get_or_create_node(
            session, name=name, type_="Concept", user_id=user_id,
            importance_delta=importance,
        )
    node_ids.add(str(concept_node.id))
    c_edge = await crud.create_edge(
        session, source_id=stmt_node.id, target_id=concept_node.id,
        relation="CONTEXT", user_id=user_id,
    )
    if c_edge:
        edge_ids.add(str(c_edge.id))


async def _persist_claims(
    session: AsyncSession,
    user_id: _uuid.UUID,
    claims: list[dict],
    context_type: str,
    recorded_at: datetime | None = None,
    entry_id: _uuid.UUID | None = None,
) -> tuple[set[str], set[str], set[str]]:
    """Persist claims as (Identity|Source)-SPOKE_OR_PUBLISHED->(Statement)-CONTEXT->(Concept).

    The head node is a Person for spoken/diary attribution and a Source for
    외부 출처 (매체·기관·AI) attribution — claim["speaker_type"] decides.
    Returns (node_ids, edge_ids, statement_node_ids) as string sets. Shared by
    /kg/commit and the
    journal-entry graph builder. NEVER creates Vocab nodes (architecture rule #1).
    Event time is resolved per claim against ``recorded_at``.  Relative language
    such as "yesterday" never inherits the source entry date blindly.
    """
    node_ids: set[str] = set()
    edge_ids: set[str] = set()
    statement_node_ids: set[str] = set()

    recorded_at = recorded_at or datetime.now(timezone.utc)
    for claim_index, claim in enumerate(claims):
        speaker_name = (claim.get("speaker") or "").strip()
        statement_text = (claim.get("statement") or "").strip()
        if not speaker_name or not statement_text:
            continue

        speaker_node = await _resolve_head_node(
            session, user_id, speaker_name, claim.get("speaker_type")
        )
        node_ids.add(str(speaker_node.id))

        title = (claim.get("title") or "").strip() or statement_text[:40]
        stmt_description = _make_stmt_description(context_type, statement_text)
        temporal = _claim_temporal_values(claim, recorded_at)
        stmt_node = await crud._get_or_create_node(
            session, name=title, type_="Statement",
            description=stmt_description, user_id=user_id,
            claim_key=_claim_key(entry_id, claim_index, statement_text),
            **temporal,
        )
        node_ids.add(str(stmt_node.id))
        statement_node_ids.add(str(stmt_node.id))

        edge = await crud.create_edge(
            session, source_id=speaker_node.id, target_id=stmt_node.id,
            relation="SPOKE_OR_PUBLISHED", user_id=user_id,
        )
        if edge:
            edge_ids.add(str(edge.id))

        for raw_concept in (claim.get("concepts") or []):
            c_name, importance, kind, action, c_node_id = _normalize_concept_dict(raw_concept)
            await _persist_concept(
                session, user_id, stmt_node,
                name=c_name, importance=importance, kind=kind,
                action=action, node_id=c_node_id,
                node_ids=node_ids, edge_ids=edge_ids,
            )

    return node_ids, edge_ids, statement_node_ids


# ─── Journal-entry → Statement graph (used by 내 일기 "지식 그래프 생성") ──────────

async def extract_statement_graph_draft(
    session: AsyncSession,
    entry_id: _uuid.UUID,
    user_id: _uuid.UUID,
) -> dict:
    """Produce a STAGING draft of the Statement graph — LLM extraction only, NO commit.

    Returns ``{"claims": [...], "context_type", "speaker_count", "is_diary"}``.
    The diary (1 speaker) / dialogue (N speakers) branching and identity remapping
    are applied here; persistence is deferred to ``persist_entry_claims`` so the user
    can review/edit the draft before it becomes immutable graph nodes.
    """
    from ..precision_text import segments_to_paragraph_text

    entry = await crud.get_journal_entry(session, entry_id, user_id)
    if entry is None:
        raise ValueError("entry not found")

    user = await session.get(User, user_id)
    native_language = getattr(user, "native_language", "korean") or "korean" if user else "korean"

    segments = entry.transcript_segments if isinstance(entry.transcript_segments, list) else []
    speakers: list[str] = []
    for seg in segments:
        if isinstance(seg, dict):
            sp = str(seg.get("speaker", "")).strip()
            if sp and sp not in speakers:
                speakers.append(sp)

    # CLEANED transcript = STT/오타 교정을 마친 문장 — 그래프에 들어가야 하는 본문.
    # 단일 화자(일기)는 이 텍스트를 그대로 쓰고, 다화자는 화자 귀속을 위해 라벨이
    # 붙은 텍스트가 필요하다. 세그먼트는 정제본이 되매핑돼 있으면(정상 경로) 그대로
    # 쓰면 되지만, 되매핑에 실패한 항목·과거 항목은 세그먼트가 원문 그대로다.
    # 그럴 때는 정제본 자체가 이미 "[이름] 발화" 라벨을 유지하므로 그걸 라벨 원본으로
    # 승격한다 — 교정본을 '참고'로만 덧붙이면 모델이 원문 표기를 그대로 베껴
    # ("출근완") 진술 노드가 정제 전 텍스트로 남기 때문. 라벨이 세그먼트 화자 집합을
    # 벗어나면(모델이 이름을 지어낸 경우) 승격하지 않는다.
    clean_text = (entry.transcript_clean_native or "").strip()
    raw_labeled = segments_to_paragraph_text(segments) if segments else ""
    diary_text = clean_text or (entry.transcript_native or "").strip()
    labeled_text = raw_labeled or clean_text or diary_text
    if raw_labeled and clean_text and clean_text != raw_labeled:
        clean_labeled = _clean_text_as_labeled(clean_text, speakers)
        if clean_labeled:
            labeled_text = clean_labeled
            clean_text = ""  # 중복 참고 블록 제거 — 라벨 본문이 이미 정제본이다
    if not labeled_text.strip() and not diary_text:
        raise ValueError("empty transcript for graph build")

    # Existing node names for entity resolution. Identity nodes carry their learned
    # aliases inline — "나 (별칭: 장세영, 세영)" — so the LLM normalizes a variant
    # surface ("세영이가") to the canonical name from the very first extraction (갭 B).
    all_nodes = await crud.get_all_nodes(session, user_id)
    existing_names = _existing_nodes_hint(all_nodes)

    is_diary = len(speakers) <= 1
    settings = get_settings()

    # Content category (대화/일기/회의록/…). Prefer the user-confirmed source_type;
    # fall back to the AI-suggested type, then the legacy trace value.
    trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
    raw_category = (
        (entry.source_type or "").strip()
        or (entry.suggested_source_type or "").strip()
        or str(trace.get("source_type") or "").strip()
    )
    source_category = raw_category or "대화"

    # Entry-level attribution (text paste): the user already told us who asserted
    # this content — no speaker inference. 'source' heads get a Source node (매체·
    # 기관·AI), 'person' an Identity node. 'self' flows through the diary path below.
    attribution_kind = (getattr(entry, "attribution_kind", None) or "").strip().lower()
    attribution_name = (getattr(entry, "attribution_name", None) or "").strip()

    speaker_name: str | None = None
    speaker_type = IDENTITY_ENTITY_TYPE
    if attribution_kind in ("source", "person") and attribution_name:
        speaker_name = attribution_name
        speaker_type = (
            SOURCE_ENTITY_TYPE
            if attribution_kind == "source"
            else IDENTITY_ENTITY_TYPE
        )
        # Attributed paste is never a personal diary. External source (매체·AI) falls
        # back to 자료 (정리된 지식); a named person's authored text to 책 (산문).
        attr_fallback = "자료" if attribution_kind == "source" else "책"
        context_type = (
            raw_category
            if raw_category and raw_category not in ("개인일기", "일기")
            else attr_fallback
        )
        is_diary = False
        system_prompt = _build_extraction_system_prompt(
            content_type=context_type, fixed_speaker=speaker_name, native_language=native_language
        )
        extraction_source = diary_text or labeled_text
        user_prompt = _diary_user_prompt(
            extraction_source,
            speaker_name,
            existing_names,
            header="Source text",
        )
    elif is_diary:
        # Single-speaker entry. Attribute the statement to the lone speaker's
        # CONFIRMED identity rather than blindly assuming the owner — a one-voice
        # clip can be someone else (a lecture, a forwarded memo). Only fall back to
        # the canonical self node (creating it) for legacy auto-'나' entries or
        # genuinely unconfirmed cases — never spuriously for a named speaker.
        from ..languages import spec as _language_spec

        self_label = _language_spec(native_language, default="korean").self_label or "나"
        lone_label = speakers[0] if speakers else None
        resolved = None
        resolved_type = None
        if lone_label and lone_label not in ("나", self_label):
            resolved, resolved_type = await _confirmed_speaker_identity(
                session, user_id, entry_id, lone_label
            )
        if resolved:
            speaker_name = resolved
            # Head-node entity type follows the confirmed node — a lone confirmed
            # Source (e.g. reading aloud "기업은행" material) must not default to
            # Person just because the single-speaker branch usually means a human.
            if resolved_type and is_source_like_type(resolved_type):
                speaker_type = "Source"
        else:
            self_node = await crud.get_or_create_self_node(
                session, user_id, default_name=self_label
            )
            speaker_name = self_node.name
        context_type = "개인일기"
        system_prompt = _build_extraction_system_prompt(
            content_type=context_type, fixed_speaker=speaker_name, native_language=native_language
        )
        extraction_source = diary_text or labeled_text
        user_prompt = _diary_user_prompt(extraction_source, speaker_name, existing_names)
    else:
        context_type = source_category
        system_prompt = _build_extraction_system_prompt(
            content_type=context_type, fixed_speaker=None, native_language=native_language
        )
        # Multi-speaker text is labelled per turn; the coverage guard measures the
        # corrected transcript when there is one, since that is what the prompt
        # tells the model to extract from.
        extraction_source = clean_text or labeled_text
        user_prompt = _external_user_prompt(
            labeled_text, source_category, existing_names, corrected_text=clean_text
        )

    llm_started = time.perf_counter()
    resp = await _llm_client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0.2,
        response_format=_EXTRACTION_RESPONSE_FORMAT,
    )
    extract_ms = _ms_since(llm_started)
    _require_complete_completion(resp.choices[0])
    raw = resp.choices[0].message.content or "{}"
    result = _parse_llm_json(raw)
    # Same guard as the paste path: the entry's later sentences must not vanish
    # between the cleaned transcript and the claims the reviewer is shown.
    coverage_started = time.perf_counter()
    result, coverage = await _ensure_source_coverage(
        source=extraction_source,
        result=result,
        raw=raw,
        system_prompt=system_prompt,
        user_prompt=user_prompt,
        native_language=native_language,
        model=settings.openai_model,
    )
    coverage_ms = _ms_since(coverage_started)
    _drop_referring_concepts(
        [c for c in (result.get("claims") or []) if isinstance(c, dict)]
    )
    verify_started = time.perf_counter()
    await _verify_concept_matches(result, session, user_id)
    verify_ms = _ms_since(verify_started)

    # Build claim dicts — diary and external both emit "claims": [...], and the
    # count is whatever the content naturally splits into (1 or many).
    claims: list[dict] = []
    for c in (result.get("claims") or []):
        if not isinstance(c, dict):
            continue
        statement = (c.get("statement") or "").strip()
        if not statement:
            continue
        claims.append({
            # Fixed-speaker modes (diary / attributed paste): never trust the
            # LLM's speaker field — attribution is decided by the user.
            "speaker": speaker_name if speaker_name else (c.get("speaker") or "").strip(),
            # Head-node entity type: Source for 외부 출처 attribution, else Person.
            "speaker_type": speaker_type,
            "title": (c.get("title") or "").strip(),
            "statement": statement,
            "event_time_text": c.get("event_time_text"),
            "temporal_precision": c.get("temporal_precision") or "unknown",
            "temporal_confidence": c.get("temporal_confidence") or 0.0,
            "event_status": c.get("event_status") or "happened",
            "concepts": c.get("concepts") or [],
        })

    if not claims:
        raise ValueError("LLM produced no statements")

    # Resolve each claim's event time now, with the same function commit uses, so
    # the review UI can show the date it is about to store instead of leaving the
    # user to discover it afterwards. Display-only: commit re-resolves from the
    # same inputs (or from the reviewer's event_date_override, which wins).
    draft_recorded_at = entry.created_at or datetime.now(timezone.utc)
    for c in claims:
        resolved = _claim_temporal_values(c, draft_recorded_at)
        occurred = resolved["occurred_at"]
        c["resolved_event_date"] = occurred.isoformat() if occurred else None
        c["resolved_precision"] = resolved["temporal_precision"]
        c["resolved_confidence"] = resolved["temporal_confidence"]
    recorded_date = draft_recorded_at.astimezone(ZoneInfo(settings.chat_timezone)).date()

    # Remap raw diarization labels (Speaker_1) to confirmed identities (제니 / self /
    # an external Source like 기업은행) so the statement and the voice link
    # converge on one node — never split. The head type follows the confirmed
    # node's actual type instead of defaulting every multi-speaker claim to
    # Person (a diary/attributed-paste claim's speaker never matches a raw label
    # here, so this is a no-op for those branches — see speaker_type above).
    identity_names, identity_types = await _entry_label_identity_map(session, user_id, entry_id)
    if identity_names:
        for c in claims:
            sp = (c.get("speaker") or "").strip()
            if sp not in identity_names:
                continue
            c["speaker"] = identity_names[sp]
            node_type = identity_types.get(sp)
            if node_type and is_source_like_type(node_type):
                c["speaker_type"] = "Source"

    # Pre-resolve person-kind mentions against existing identities so the review
    # UI can pre-select a match; offer the full person roster as picker candidates.
    enrich_started = time.perf_counter()
    await _enrich_person_concepts(session, user_id, claims)
    await _enrich_plain_concepts(session, user_id, claims)
    person_candidates = await _person_candidates_payload(session, user_id)
    enrich_ms = _ms_since(enrich_started)

    # Where the wait actually went. Without this the trace showed one opaque
    # `statement_graph_draft` latency (10–42 s observed) and every explanation was
    # a guess; now extraction / coverage repair / DB resolution are separable.
    timings = {
        "extract_ms": extract_ms,
        "coverage_ms": coverage_ms,
        "verify_ms": verify_ms,
        "enrich_ms": enrich_ms,
    }
    logger.info(
        "graph draft timings entry=%s claims=%d %s",
        entry_id,
        len(claims),
        timings,
    )

    return {
        "timings": timings,
        "claims": claims,
        "context_type": context_type,
        "person_candidates": person_candidates,
        "speaker_count": len(speakers) if speakers else 1,
        "is_diary": is_diary,
        # The entry's own recording day, in the app timezone. The review UI offers
        # "그날/전날" relative to this rather than to the device clock, so a draft
        # reviewed the next morning still counts back from when it was written.
        "recorded_date": recorded_date.isoformat(),
        # Surfaced to the pipeline flow trace (see run_entry_graph_draft) so the
        # "그래프 드래프트" node shows the actual system_prompt/input the LLM used.
        "system_prompt": system_prompt,
        "user_prompt": user_prompt,
        # How much of the source survived into the claims above, and which source
        # sentences did not (see _ensure_source_coverage). None for entries too
        # short to score. Carried into the trace so a silent loss is findable.
        "coverage": coverage,
    }


async def persist_entry_claims(
    session: AsyncSession,
    user_id: _uuid.UUID,
    entry_id: _uuid.UUID,
    claims: list[dict],
    context_type: str,
) -> dict:
    """Persist reviewed/confirmed claims into the graph and link them to the entry.

    This is the commit half of the journal graph build — it runs ``_persist_claims``,
    links confirmed voices, and records provenance. Used by both the one-shot
    ``build_statement_graph_from_entry`` and the HITL apply endpoint.
    """
    claims = [c for c in (claims or []) if isinstance(c, dict) and (c.get("statement") or "").strip()]
    if not claims:
        raise ValueError("no statements to persist")

    # Review clients may round-trip claims without speaker_type — re-derive the
    # head-node type from the entry's attribution so a 출처-attributed entry can
    # never silently commit its source as a Person node.
    entry = await crud.get_journal_entry(session, entry_id, user_id)
    if entry is not None and (entry.attribution_kind or "").strip().lower() == "source":
        for c in claims:
            c.setdefault("speaker_type", "Source")

    entry_recorded_at = entry.created_at if entry is not None and entry.created_at else datetime.now(timezone.utc)
    node_ids, edge_ids, statement_node_ids = await _persist_claims(
        session,
        user_id,
        claims,
        context_type,
        recorded_at=entry_recorded_at,
        entry_id=entry_id,
    )

    await _link_confirmed_voices_to_nodes(session, user_id, entry_id)
    await session.commit()

    # Provenance links so 노드 ↔ 일기 추적이 유지됨
    try:
        node_uuid_list = [_uuid.UUID(nid) for nid in node_ids]
        edge_uuid_list = [_uuid.UUID(eid) for eid in edge_ids]
        await crud.record_journal_graph_links(
            session, entry_id, node_uuid_list, edge_uuid_list
        )
    except Exception as link_exc:
        logger.warning("persist_entry_claims: link recording failed: %s", link_exc)

    # Embed freshly-created Statement/Concept nodes now (not lazily on next chat) so
    # tomorrow's journal draft can fuzzy-link against today's concepts. Best-effort;
    # ensure_statement_embeddings filters name_embedding IS NULL and commits itself.
    try:
        from ..rag import ensure_statement_embeddings

        await ensure_statement_embeddings(session, user_id)
    except Exception:
        logger.warning("persist_entry_claims: embedding backfill failed", exc_info=True)

    statement_count = sum(1 for c in claims if c.get("statement"))
    return {
        "statement_count": statement_count,
        "concept_count": sum(len(c.get("concepts") or []) for c in claims),
        "node_count": len(node_ids),
        "edge_count": len(edge_ids),
        "context_type": context_type,
        "statement_node_ids": sorted(statement_node_ids),
    }


@router.post("/temporal-backfill")
async def temporal_backfill(
    body: TemporalBackfillRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Preview or apply deterministic event-time repairs for the caller's graph."""
    from ..temporal_backfill import backfill_statement_event_times

    return await backfill_statement_event_times(
        session,
        user.id,
        timezone_name=get_settings().chat_timezone,
        dry_run=body.dry_run,
    )


async def build_statement_graph_from_entry(
    session: AsyncSession,
    entry_id: _uuid.UUID,
    user_id: _uuid.UUID,
) -> dict:
    """One-shot draft + persist (no HITL review). Kept for the worker / auto paths.

    The journal UI uses the two-phase draft→review→apply flow instead; this wrapper
    preserves the legacy single-call behavior for callers that don't review.
    """
    draft = await extract_statement_graph_draft(session, entry_id, user_id)
    summary = await persist_entry_claims(
        session, user_id, entry_id, draft["claims"], draft["context_type"]
    )
    summary["speaker_count"] = draft.get("speaker_count", 1)
    return summary


# ─── Transcribe endpoint ──────────────────────────────────────────────────────

@router.post("/transcribe")
async def kg_transcribe(
    file: UploadFile = File(...),
    user: User = Depends(request_user_dep),
    _quota: None = Depends(daily_quota(KIND_STT)),
) -> dict:
    """STT + speaker diarization for audio uploaded to the KG build flow.

    Returns transcript text, unique speaker count, and per-segment details so
    the frontend can decide:
    - diary mode  → 1 speaker expected; warn user if speaker_count > 1
    - external mode → show speaker segments for labeling before KG extraction
    """
    file_bytes = await file.read()
    filename = file.filename or "audio.wav"

    # Scratch copy alongside the durable one — diarize_audio/transcribe_audio
    # both take a Path, which S3-backed storage cannot provide on its own.
    audio_key, audio_path = await save_audio_workfile(file_bytes, filename, user.id)

    native_language = getattr(user, "native_language", None) or "korean"

    # Run diarization first (non-blocking if disabled)
    segments: list[SpeakerSegment]
    segments, _, _ = await diarize_audio(audio_path, native_language)

    # STT transcription
    transcript = await transcribe_audio(audio_path, native_language)

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
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Returns aggregated stats for the Insight dashboard.

    Deliberately avoids ``crud.get_all_nodes``: the dashboard needs three counts
    plus (date, description) for Statements, and hydrating every ORM node — with
    aliases, temporal columns and provenance — to throw all of it away was the
    single slowest thing behind this screen.
    """
    # Node counts straight from Postgres — one grouped scan, no rows hydrated.
    type_rows = await session.execute(
        select(Node.type, func.count())
        .where(Node.user_id == user.id, Node.deleted_at.is_(None))
        .group_by(Node.type)
    )
    type_counts = {str(t): int(c) for t, c in type_rows.all()}

    # Speaker count from the SPOKE_OR_PUBLISHED heads rather than from type
    # strings — a graph that still has legacy 'Person'/'Speaker' rows would
    # otherwise report zero speakers after the Person type was retired.
    speaker_rows = await session.execute(
        select(func.count(func.distinct(Edge.source_id))).where(
            Edge.user_id == user.id,
            Edge.relation == REL_SPOKE_OR_PUBLISHED,
        )
    )
    total_speakers = int(speaker_rows.scalar() or 0)

    today = datetime.now(timezone.utc).date()
    cutoff = today - timedelta(days=364)

    # context_type lives inside the description blob (JSON or legacy two-line),
    # so the distribution still needs the text — but only for Statements, and
    # only those two columns.
    stmt_rows = await session.execute(
        select(Node.created_at, Node.description).where(
            Node.user_id == user.id,
            Node.deleted_at.is_(None),
            Node.type == "Statement",
        )
    )

    day_counts: dict[str, int] = {}
    src_counts: dict[str, int] = {}
    for created_at, description in stmt_rows.all():
        d = (
            created_at.astimezone(timezone.utc).date()
            if created_at.tzinfo
            else created_at.date()
        )
        if d >= cutoff:
            key = d.isoformat()
            day_counts[key] = day_counts.get(key, 0) + 1
        src, _ = _parse_stmt_description(description)
        src_counts[src] = src_counts.get(src, 0) + 1

    daily_activity = [{"date": k, "count": v} for k, v in sorted(day_counts.items())]

    # streak: consecutive days with at least 1 statement up to today
    streak = 0
    check = today
    while day_counts.get(check.isoformat(), 0) > 0:
        streak += 1
        check -= timedelta(days=1)

    source_distribution = [
        {"source": k, "count": v}
        for k, v in sorted(src_counts.items(), key=lambda x: -x[1])
    ]

    return {
        "total_statements": type_counts.get("Statement", 0),
        "total_concepts": type_counts.get("Concept", 0),
        # Statement heads, counted from the edges rather than from type strings:
        # type-independent, so it survives un-migrated 'Person'/'Speaker' rows.
        "total_speakers": total_speakers,
        "streak_days": streak,
        "daily_activity": daily_activity,
        "source_distribution": source_distribution,
    }


@router.get("/statements/by-date")
async def kg_statements_by_date(
    date: str,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    limit: int = 100,
) -> dict:
    """Statements recorded on one UTC day, for the insight heat-map day feed.

    The feed used to be served by fetching the *entire* graph client-side and
    filtering it in Dart — every tap on a heat-map cell paid for the whole node
    and edge set. This returns just the handful of rows that day actually has.
    """
    try:
        day = _date.fromisoformat(date)
    except ValueError:
        raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD")

    start = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc)
    rows = await session.execute(
        select(Node.id, Node.name, Node.description, Node.created_at)
        .where(
            Node.user_id == user.id,
            Node.deleted_at.is_(None),
            Node.type == "Statement",
            Node.created_at >= start,
            Node.created_at < start + timedelta(days=1),
        )
        .order_by(Node.created_at)
        .limit(max(1, min(limit, 500)))
    )
    statements = []
    for node_id, name, description, created_at in rows.all():
        context_type, _ = _parse_stmt_description(description)
        statements.append(
            {
                "id": str(node_id),
                "name": name,
                "context_type": context_type,
                "created_at": created_at.isoformat(),
            }
        )
    return {"date": date, "statements": statements}


# ─── Debug runs endpoint ───────────────────────────────────────────────────────

@router.get("/debug/runs")
async def kg_debug_runs(
    _user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_debug_enabled),
) -> list[dict]:
    """Return recent persisted journal/KG pipeline traces plus legacy extracts.

    The old debug screen only read ``_run_log``, which is populated by the
    legacy ``POST /kg/extract`` endpoint and is wiped on restart.  The active
    journal flow persists its trace on ``JournalEntry``, so surface that first.
    """
    entries = (
        await session.scalars(
            select(JournalEntry)
            .where(
                JournalEntry.user_id == _user.id,
                JournalEntry.pipeline_trace.is_not(None),
            )
            .order_by(JournalEntry.created_at.desc())
            .limit(50)
        )
    ).all()
    persisted: list[dict] = []
    for entry in entries:
        trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
        if not trace.get("steps"):
            continue
        timing = trace.get("timing") if isinstance(trace.get("timing"), dict) else {}
        persisted.append({
            "kind": "journal_pipeline",
            "run_id": trace.get("run_id") or str(entry.id),
            "entry_id": str(entry.id),
            "mode": "journal",
            "timestamp": trace.get("completed_at") or trace.get("started_at") or entry.created_at.isoformat(),
            "status": trace.get("status") or entry.status,
            "latency_ms": sum(value for value in timing.values() if isinstance(value, int)),
            "trace": trace,
        })
    legacy = [{**run, "kind": "legacy_extract"} for run in _run_log]
    return sorted(
        [*persisted, *legacy],
        key=lambda run: run.get("timestamp") or "",
        reverse=True,
    )[:50]


# ─── Calendar data endpoint ────────────────────────────────────────────────────

@router.get("/calendar-data")
async def kg_calendar_data(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Per-day breakdown with context_types for calendar + heatmap sync.

    Returns last 365 days. Each day includes list of context_types present
    so the calendar can render colored indicator dots per source type.
    """
    today = datetime.now(timezone.utc).date()
    cutoff = today - timedelta(days=364)

    # Only the four Statement columns this projection reads — see kg_stats for
    # why the full ORM load was worth removing.
    rows = await session.execute(
        select(Node.id, Node.description, Node.created_at).where(
            Node.user_id == user.id,
            Node.deleted_at.is_(None),
            Node.type == "Statement",
            Node.created_at
            >= datetime.combine(cutoff, datetime.min.time(), tzinfo=timezone.utc),
        )
    )

    # Build per-day map: date → {types: set, ids: list}
    day_map: dict[str, dict] = {}
    for node_id, description, created_at in rows.all():
        d = (
            created_at.astimezone(timezone.utc).date()
            if created_at.tzinfo
            else created_at.date()
        )
        key = d.isoformat()
        if key not in day_map:
            day_map[key] = {"context_types": [], "statement_ids": []}
        ctx, _ = _parse_stmt_description(description)
        if ctx not in day_map[key]["context_types"]:
            day_map[key]["context_types"].append(ctx)
        day_map[key]["statement_ids"].append(str(node_id))

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


@router.get("/timeline")
async def kg_timeline(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Entry-centric timeline: ONE card per uploaded file (journal entry).

    A single audio/text upload may yield several Statement nodes; the timeline
    groups them under their source entry so the user sees one card, not many.
    Includes entries with no graph yet (has_graph=false) so every upload appears.
    """
    # Cards read only id/created_at/status/source_type/transcript/pipeline_trace —
    # never the staged graph, segments, or translations.
    entries = await crud.list_journal_entries(
        session, user.id, limit=500, with_blobs=False
    )
    nodes = await crud.get_all_nodes(session, user.id)
    node_by_id = {n.id: n for n in nodes}
    edges = await crud.get_all_edges(session, user.id)

    # Provenance: entry_id → [node_id]
    # Scoped to this user's entries. Without the IN filter this scanned every
    # link row in the table — other users' provenance included — and threw the
    # rest away after the node_by_id lookup missed.
    link_rows = await session.execute(
        select(JournalGraphLink.journal_entry_id, JournalGraphLink.node_id).where(
            JournalGraphLink.node_id.is_not(None),
            JournalGraphLink.journal_entry_id.in_([e.id for e in entries]),
        )
    )
    # Dedupe (entry_id, node_id): a re-run of the graph build can leave duplicate
    # link rows, which would otherwise render the same Statement twice ("진술 4").
    entry_nodes: dict = {}
    seen_links: set = set()
    for eid, nid in link_rows.all():
        if (eid, nid) in seen_links:
            continue
        seen_links.add((eid, nid))
        entry_nodes.setdefault(eid, []).append(nid)

    # Statement → concepts (CONTEXT) and speaker (SPOKE_OR_PUBLISHED).
    stmt_concepts: dict = {}
    stmt_speaker: dict = {}
    for e in edges:
        if e.relation == "CONTEXT":
            stmt_concepts.setdefault(e.source_id, []).append(e.target_id)
        elif e.relation == "SPOKE_OR_PUBLISHED":
            stmt_speaker.setdefault(e.target_id, []).append(e.source_id)

    cards: list[dict] = []
    for entry in entries:
        statements_out: list[dict] = []
        concept_names: list[str] = []
        speaker_names: list[str] = []
        ctx_types: list[str] = []
        for nid in entry_nodes.get(entry.id, []):
            s = node_by_id.get(nid)
            if s is None or s.type != "Statement" or s.deleted_at is not None:
                continue
            ctx, content = _parse_stmt_description(s.description)
            if ctx and ctx not in ctx_types:
                ctx_types.append(ctx)
            sp = next(
                (node_by_id[i].name for i in stmt_speaker.get(s.id, []) if i in node_by_id),
                None,
            )
            if sp and sp not in speaker_names:
                speaker_names.append(sp)
            for cid in stmt_concepts.get(s.id, []):
                c = node_by_id.get(cid)
                if c is not None and c.type == "Concept" and c.name not in concept_names:
                    concept_names.append(c.name)
            statements_out.append(
                {"id": str(s.id), "title": s.name, "content": content, "speaker": sp}
            )

        trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
        # Fall back to the Statement nodes' own context_type when the entry has no
        # stored source_type. Dialogue/diary graphs persist the category ('대화',
        # '개인일기' …) only on the statements, not the entry column, so without
        # this fallback the card would show '미분류' even though the statements
        # carry a real category.
        source_type = (
            (entry.source_type or "").strip()
            or (entry.suggested_source_type or "").strip()
            or str(trace.get("source_type") or "").strip()
            or next((c for c in ctx_types if c and c != "미분류"), None)
        )
        if statements_out:
            preview = " · ".join(st["title"] for st in statements_out[:2])
        else:
            preview = (entry.transcript_clean_native or entry.transcript_native or "").strip()[:60]

        cards.append({
            "entry_id": str(entry.id),
            "created_at": entry.created_at.isoformat() if entry.created_at else None,
            "source_type": source_type,
            "status": entry.status,
            "has_graph": bool(statements_out),
            "preview": preview,
            "statements": statements_out,
            "concepts": concept_names,
            "speakers": speaker_names,
            "counts": {"statements": len(statements_out), "concepts": len(concept_names)},
        })

    return {"cards": cards}
