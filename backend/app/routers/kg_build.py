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

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, UploadFile
from openai import AsyncOpenAI
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..config import get_settings
from ..db import get_session
from ..deps import request_user_dep
from ..entity_types import (
    is_identity_type,
    is_person_like_type,
    is_source_like_type,
    normalize_entity_type,
)
from ..journal_pipeline import transcribe_audio
from ..models import JournalGraphLink, Node, SpeakerProfile, User
from ..speaker_diarization import SpeakerSegment, diarize_audio
from ..storage import save_audio, local_path

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/kg", tags=["kg-build"])

# ─── In-memory run log (last 50 extract calls) ───────────────────────────────

_run_log: deque[dict] = deque(maxlen=50)


# ─── OpenAI client (shared, cached) ──────────────────────────────────────────

@lru_cache
def _llm_client() -> AsyncOpenAI:
    settings = get_settings()
    # Bound the request so a hung OpenAI call fails fast (→ graph_failed) rather
    # than buffering for the SDK default (600s × retries).
    return AsyncOpenAI(
        api_key=settings.openai_api_key,
        timeout=settings.openai_timeout_sec,
        max_retries=1,
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
      - "new_person" → create a fresh Person node for this name.
      - "concept"    → keep it an ordinary Concept node (downgrade / not a person after all).
    """
    action: Literal["link", "new_person", "concept"] = "new_person"
    node_id: _uuid.UUID | None = None


class ConceptIn(BaseModel):
    name: str
    # 1-5: how central this concept is to the statement (LLM-assigned, clamped).
    importance: int = Field(default=3, ge=1, le=5)
    # "person" → a specific human (resolves to a Person/self node, MENTIONS edge);
    # "concept" → an ordinary idea/thing (Concept node, CONTEXT edge).
    kind: Literal["person", "concept"] = "concept"
    # Only meaningful for kind="person"; carries the reviewer's resolution decision.
    resolution: ConceptResolutionIn | None = None


class KgClaimIn(BaseModel):
    speaker: str
    # Head-node entity type: "Person" (화자) or "Source" (매체·기관·AI 출처).
    speaker_type: str = "Person"
    title: str = ""          # short node label (5-7 words); falls back to truncated statement
    statement: str           # full 1-2 sentence content; stored in node description
    concepts: list[ConceptIn] = Field(default_factory=list)


class KgCommitRequest(BaseModel):
    claims: list[KgClaimIn] = Field(min_length=1)
    context_type: str  # e.g. 'diary', 'meeting', 'book'
    original_text: str = ""
    journal_entry_id: _uuid.UUID | None = None  # optional link for transcript provenance


# Allowed statement head-node types. Source (외부 출처) is deliberately not
# person-like — it never enters voice/speaker pickers (see entity_types).
_HEAD_NODE_TYPES = frozenset({"Person", "Source"})


def _claim_head_type(raw: str | None) -> str:
    """Sanitize a claim's speaker_type to a valid head-node entity type."""
    t = normalize_entity_type(raw or "Person")
    return t if t in _HEAD_NODE_TYPES else "Person"


async def _resolve_head_node(
    session: AsyncSession,
    user_id: _uuid.UUID,
    name: str,
    head_type: str,
) -> Node:
    """Resolve a statement head (화자/출처) to an existing identity, never forking.

    A head is created by name+type, but a mentioned identity may already exist under
    the same name (e.g. '엄마' first appeared as a MENTIONS target → Identity node).
    Blindly creating a Person/Source head would fork it. So resolve across the whole
    정체성 category first and reuse:
      - Person head ↔ person-like or generic Identity (a speaker is human → the
        generic Identity is promoted to Person).
      - Source head ↔ source-like only.
    A person↔source name clash (incompatible role) falls through to a fresh node.
    """
    name = (name or "").strip()
    head_type = _claim_head_type(head_type)
    want_source = is_source_like_type(head_type)

    existing = await crud.find_identity_node_by_name_or_alias(session, user_id, name)
    if existing is not None:
        existing_is_source = is_source_like_type(existing.type)
        if want_source and existing_is_source:
            crud.add_node_alias(existing, name)
            await session.flush()
            await crud.index_identity_alias(session, user_id, existing, name)
            return existing
        if not want_source and not existing_is_source:
            if not is_person_like_type(existing.type):
                # generic Identity now speaks → it's human.
                existing.type = normalize_entity_type("Person")
            crud.add_node_alias(existing, name)
            await session.flush()
            await crud.index_identity_alias(session, user_id, existing, name)
            return existing
        # incompatible role (person↔source name clash) → create a fresh head node.

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
    focus_line = (
        f'\nThis text\'s content_type is "{content_type}" — prioritize extracting the '
        f"items listed for it above all else."
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
      "title": "핵심 내용을 담은 5-7단어 한국어 제목",
      "statement": "정제된 핵심 한국어 진술 (1-2문장 전체 내용)",
      "concepts": [{{"name": "개념1", "importance": 4, "kind": "concept"}}, {{"name": "제니", "importance": 3, "kind": "person"}}],
      "speaker_matched": false,
      "concepts_matched": [false, false]
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

{_content_type_guidance_block(content_type)}

[FIELDS]
{speaker_rule}
- title: 5–7 Korean words capturing the essence of this claim. Used as the graph node label.
- statement: 1–2 clean Korean sentences (remove filler, preserve full meaning).
- concepts: 1–5 concrete nouns per claim — NEVER an empty array. Every claim has
  at least one concept: for emotional/reflective claims, extract the TARGET or
  CAUSE of the feeling (e.g. "면접이 생각나 기분이 안 좋았다" → concepts: 면접;
  "사업이 잘 안 된다" → concepts: 사업), not just the emotion word. Each concept
  is an object:
  - name: the concept/entity name.
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
- speaker_matched: true only when speaker name was reused from existing_nodes.
- concepts_matched: per-concept boolean (same order as concepts), true if reused
  from existing_nodes.
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
                            "speaker_matched": {"type": "boolean"},
                            "concepts_matched": {
                                "type": "array",
                                "items": {"type": "boolean"},
                            },
                        },
                        "required": [
                            "speaker",
                            "title",
                            "statement",
                            "concepts",
                            "speaker_matched",
                            "concepts_matched",
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
    for c in _iter_concepts(claims):
        if isinstance(c.get("resolution"), dict):
            continue  # reviewer/prior pass already decided
        name = str(c.get("name") or "").strip()
        if not name:
            continue
        match = await crud.find_identity_node_by_name_or_alias(session, user_id, name)
        if match is not None:
            c["kind"] = "person"  # a known identity is always identity-kind
            c["resolution"] = {
                "action": "link",
                "node_id": str(match.id),
                "matched_name": match.name,
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

    try:
        vectors = await embed_texts([name for _, name in pairs])
    except Exception:
        return

    for (c, _name), vec in zip(pairs, vectors):
        hit = await crud.find_identity_by_alias_embedding(session, user_id, vec)
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
    for claim in claims:
        if not isinstance(claim, dict):
            continue
        concepts = [c for c in (claim.get("concepts") or []) if isinstance(c, dict)]
        matched_flags: list[bool] = []
        for c in concepts:
            name = (c.get("name") or "").strip()
            hits = await crud.find_nodes_by_name(session, user_id, name) if name else []
            matched_flags.append(len(hits) > 0)
        claim["concepts_matched"] = matched_flags

        speaker_name: str = (claim.get("speaker") or "").strip()
        if speaker_name:
            hits = await crud.find_nodes_by_name(session, user_id, speaker_name)
            claim["speaker_matched"] = len(hits) > 0


# ─── Endpoints ────────────────────────────────────────────────────────────────

@router.post("/extract")
async def kg_extract(
    body: KgExtractRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
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
        raw = resp.choices[0].message.content or "{}"
        result = _parse_llm_json(raw)

        # Diary mode: never trust the LLM's speaker field — it's fixed.
        # speaker_matched is recomputed against the DB just below anyway.
        if body.mode == "diary":
            for claim in result.get("claims") or []:
                if isinstance(claim, dict):
                    claim["speaker"] = speaker

        # ── Re-verify matched flags against actual DB (LLMs hallucinate) ────────
        await _verify_concept_matches(result, session, user.id)

        # ── Pre-resolve person mentions + attach picker candidates ──────────────
        claims_list = [c for c in (result.get("claims") or []) if isinstance(c, dict)]
        await _enrich_person_concepts(session, user.id, claims_list)
        result["person_candidates"] = await _person_candidates_payload(session, user.id)

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
    background_tasks: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> KgCommitOut:
    """Stage 2 — persist human-verified claims into the graph (PostgreSQL).

    Graph structure per claim:
        (Person/Speaker) --SPOKE_OR_PUBLISHED--> (Statement) --CONTEXT--> (Concept...)
    """
    node_ids: set[str] = set()
    edge_ids: set[str] = set()

    occurred_at = _date.today()
    if body.journal_entry_id is not None:
        source_entry = await crud.get_journal_entry(session, body.journal_entry_id, user.id)
        if source_entry is not None and source_entry.created_at:
            occurred_at = source_entry.created_at.date()

    for claim in body.claims:
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
        stmt_node = await crud._get_or_create_node(
            session,
            name=title,
            type_="Statement",
            description=stmt_description,
            user_id=user.id,
            occurred_at=occurred_at,
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

    # ── Enqueue expression extraction for newly committed Statement nodes ──────
    try:
        from ..extraction_queue import enqueue_bulk
        from ..crud import get_effective_target_languages, get_all_statement_nodes

        langs = get_effective_target_languages(user)
        all_stmts = await get_all_statement_nodes(session, user.id)
        await enqueue_bulk(user.id, all_stmts, langs)
    except Exception as _eq_exc:
        logger.warning("kg_commit: failed to enqueue expression extraction: %s", _eq_exc)

    from ..workers.quiz_refill import refill_user_quizzes

    background_tasks.add_task(refill_user_quizzes, user.id)

    return KgCommitOut(
        ok=True,
        claims_saved=len(body.claims),
        nodes_upserted=len(node_ids),
        edges_created=len(edge_ids),
    )


# ─── Concept → Person migration ───────────────────────────────────────────────
# For nodes created before person-mention resolution existed: a name like '할머니'
# that was stored as a Concept can be promoted to a Person node, or merged into an
# already-existing Person identity (reassigning its edges). See [[project_immutable_graph_model]]
# — this is an explicit user-driven correction, the one place edge surgery is allowed.

class ReclassifyNodeRequest(BaseModel):
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
    - otherwise → change the node's type in place (e.g. Concept → Person).
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

    node.type = normalize_entity_type(body.to_type)
    node.updated_at = datetime.now(timezone.utc)
    await session.flush()
    # Now that it's an identity, index its name so it participates in fuzzy resolution.
    await crud.index_identity_alias(session, user.id, node, node.name)
    await session.commit()
    return {"ok": True, "merged": False, "node_id": str(node.id), "type": node.type}


# ─── Shared claim persistence ─────────────────────────────────────────────────

async def _confirmed_speaker_name(
    session: AsyncSession,
    user_id: _uuid.UUID,
    entry_id: _uuid.UUID,
    session_label: str,
) -> str | None:
    """Confirmed graph identity for a diarization label on this entry, if any.

    Prefers the linked node's name (the canonical identity, e.g. the self node),
    then a confirmed new-person display name. None when still unconfirmed.
    """
    appearance = await crud.get_speaker_appearance_for_label(
        session, entry_id, session_label
    )
    if appearance is None:
        return None
    profile = await session.get(SpeakerProfile, appearance.speaker_profile_id)
    if profile is None or profile.user_id != user_id:
        return None
    if profile.node_id is not None:
        node = await session.get(Node, profile.node_id)
        if node is not None and node.user_id == user_id:
            return (node.name or "").strip() or None
    return (profile.display_name or "").strip() or None


async def _entry_label_identity_map(
    session: AsyncSession,
    user_id: _uuid.UUID,
    entry_id: _uuid.UUID,
) -> dict[str, str]:
    """diarization label → confirmed identity name, for claim attribution.

    Lets statements attach to the CONFIRMED speaker (제니 / the self node) instead
    of the raw 'Speaker_1' label the LLM sees in the transcript — so the statement
    edge and the voice link land on the SAME node, not two split ones.
    """
    appearances = await crud.list_speaker_appearances_for_entry(session, entry_id)
    mapping: dict[str, str] = {}
    for app in appearances:
        label = (app.session_label or "").strip()
        if not label:
            continue
        name = await _confirmed_speaker_name(session, user_id, entry_id, label)
        if name:
            mapping[label] = name
    return mapping


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

    A confirmed voice means the identity is human: if the name already exists as a
    mentioned ``Identity`` node it is promoted to ``Person`` (and reused) rather than
    forking a second node — the mention and the voice converge. External ``Source``
    nodes never receive a voice.
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
                session, name=name, type_="Person", user_id=user_id
            )
        elif not is_person_like_type(node.type):
            # Mentioned Identity now has a confirmed voice → it's a human.
            node.type = normalize_entity_type("Person")
            await session.flush()
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
    category — NOT ``Person``. We can't tell a human (할머니) from a pet (마야) or a
    group at this point, and "Person" would mislabel the non-humans; the graph's
    top tier is 정체성–진술–개념. Person is reserved for identities confirmed human
    (the self node, voice-linked speakers); Source for 외부 출처. Registers the
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

    # Genuinely new mention → an Identity node (NEVER a Concept, NEVER assumed Person).
    node = await crud._get_or_create_node(
        session, name=name, type_="Identity", user_id=user_id
    )
    await crud.index_identity_alias(session, user_id, node, name)
    return node


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
    Importance accumulates on BOTH: recurring identities matter like recurring themes.

    Stickiness: a kind=concept name that already resolved to an identity keeps
    converging there — LLM tagging is inconsistent across entries, so one
    promotion (review sheet / reclassify) must hold permanently. The single
    opt-out is an EXPLICIT reviewer decision (action="concept"), which always
    yields a plain Concept node.
    """
    name = (name or "").strip()
    if not name:
        return
    explicit_concept = action == "concept"

    target: Node | None = None
    if kind == "person" and not explicit_concept:
        target = await _resolve_person_concept(session, user_id, name, action, node_id)
    elif not explicit_concept:
        # kind=concept without a reviewer decision: sticky identity check.
        target = await crud.find_identity_node_by_name_or_alias(session, user_id, name)

    if target is not None:
        target.importance_score = (target.importance_score or 0) + importance
        node_ids.add(str(target.id))
        m_edge = await crud.create_edge(
            session, source_id=stmt_node.id, target_id=target.id,
            relation="MENTIONS", user_id=user_id,
        )
        if m_edge:
            edge_ids.add(str(m_edge.id))
        return

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
    occurred_at: _date | None = None,
) -> tuple[set[str], set[str]]:
    """Persist claims as (Person|Source)-SPOKE_OR_PUBLISHED->(Statement)-CONTEXT->(Concept).

    The head node is a Person for spoken/diary attribution and a Source for
    외부 출처 (매체·기관·AI) attribution — claim["speaker_type"] decides.
    Returns (node_ids, edge_ids) as string sets. Shared by /kg/commit and the
    journal-entry graph builder. NEVER creates Vocab nodes (architecture rule #1).
    ``occurred_at`` stamps new Statement nodes with the source entry's date so
    the graph can answer "언제…?" queries (see [[temporal.py]]).
    """
    node_ids: set[str] = set()
    edge_ids: set[str] = set()

    for claim in claims:
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
        stmt_node = await crud._get_or_create_node(
            session, name=title, type_="Statement",
            description=stmt_description, user_id=user_id,
            occurred_at=occurred_at,
        )
        node_ids.add(str(stmt_node.id))

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

    return node_ids, edge_ids


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

    # CLEANED transcript = STT-corrected wording (e.g. 마차→말차) the graph must use.
    # Raw labeled segments keep [Speaker_N] labels needed for attribution but the
    # original mishearing. So: diary (single speaker) uses cleaned text directly;
    # the external (multi-speaker) branch keeps the labeled raw for attribution and
    # passes the cleaned text as a corrected-wording reference for the LLM.
    clean_text = (entry.transcript_clean_ko or "").strip()
    raw_labeled = segments_to_paragraph_text(segments) if segments else ""
    diary_text = clean_text or (entry.transcript_ko or "").strip()
    labeled_text = raw_labeled or clean_text or diary_text
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
    # 기관·AI), 'person' a Person node. 'self' flows through the diary path below.
    attribution_kind = (getattr(entry, "attribution_kind", None) or "").strip().lower()
    attribution_name = (getattr(entry, "attribution_name", None) or "").strip()

    speaker_name: str | None = None
    speaker_type = "Person"
    if attribution_kind in ("source", "person") and attribution_name:
        speaker_name = attribution_name
        speaker_type = "Source" if attribution_kind == "source" else "Person"
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
        user_prompt = _diary_user_prompt(
            diary_text or labeled_text,
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
        lone_label = speakers[0] if speakers else None
        resolved = None
        if lone_label and lone_label != "나":
            resolved = await _confirmed_speaker_name(session, user_id, entry_id, lone_label)
        if resolved:
            speaker_name = resolved
        else:
            self_node = await crud.get_or_create_self_node(session, user_id)
            speaker_name = self_node.name
        context_type = "개인일기"
        system_prompt = _build_extraction_system_prompt(
            content_type=context_type, fixed_speaker=speaker_name, native_language=native_language
        )
        user_prompt = _diary_user_prompt(diary_text or labeled_text, speaker_name, existing_names)
    else:
        context_type = source_category
        system_prompt = _build_extraction_system_prompt(
            content_type=context_type, fixed_speaker=None, native_language=native_language
        )
        user_prompt = _external_user_prompt(
            labeled_text, source_category, existing_names, corrected_text=clean_text
        )

    resp = await _llm_client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=0.2,
        response_format=_EXTRACTION_RESPONSE_FORMAT,
    )
    raw = resp.choices[0].message.content or "{}"
    result = _parse_llm_json(raw)
    await _verify_concept_matches(result, session, user_id)

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
            "concepts": c.get("concepts") or [],
        })

    if not claims:
        raise ValueError("LLM produced no statements")

    # Remap raw diarization labels (Speaker_1) to confirmed identities (제니 / self)
    # so the statement and the voice link converge on one node — never split.
    identity_map = await _entry_label_identity_map(session, user_id, entry_id)
    if identity_map:
        for c in claims:
            sp = (c.get("speaker") or "").strip()
            c["speaker"] = identity_map.get(sp, sp)

    # Pre-resolve person-kind mentions against existing identities so the review
    # UI can pre-select a match; offer the full person roster as picker candidates.
    await _enrich_person_concepts(session, user_id, claims)
    person_candidates = await _person_candidates_payload(session, user_id)

    return {
        "claims": claims,
        "context_type": context_type,
        "person_candidates": person_candidates,
        "speaker_count": len(speakers) if speakers else 1,
        "is_diary": is_diary,
        # Surfaced to the pipeline flow trace (see run_entry_graph_draft) so the
        # "그래프 드래프트" node shows the actual system_prompt/input the LLM used.
        "system_prompt": system_prompt,
        "user_prompt": user_prompt,
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

    entry_date = entry.created_at.date() if entry is not None and entry.created_at else None
    node_ids, edge_ids = await _persist_claims(
        session, user_id, claims, context_type, occurred_at=entry_date
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

    statement_count = sum(1 for c in claims if c.get("statement"))
    return {
        "statement_count": statement_count,
        "concept_count": sum(len(c.get("concepts") or []) for c in claims),
        "node_count": len(node_ids),
        "edge_count": len(edge_ids),
        "context_type": context_type,
    }


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
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Returns aggregated stats for the Insight dashboard."""
    nodes = await crud.get_all_nodes(session, user.id)

    statements = [n for n in nodes if n.type == "Statement"]
    concepts   = [n for n in nodes if n.type == "Concept"]
    # Statement heads: people AND 출처(Source) nodes both anchor statements.
    speakers   = [n for n in nodes if n.type in ("Person", "Source")]

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
    _user: User = Depends(request_user_dep),
) -> list[dict]:
    """Returns recent KG extract pipeline runs (in-memory, last 50)."""
    return list(_run_log)


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
    entries = await crud.list_journal_entries(session, user.id, limit=500)
    nodes = await crud.get_all_nodes(session, user.id)
    node_by_id = {n.id: n for n in nodes}
    edges = await crud.get_all_edges(session, user.id)

    # Provenance: entry_id → [node_id]
    link_rows = await session.execute(
        select(JournalGraphLink.journal_entry_id, JournalGraphLink.node_id).where(
            JournalGraphLink.node_id.is_not(None)
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
            preview = (entry.transcript_clean_ko or entry.transcript_ko or "").strip()[:60]

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
