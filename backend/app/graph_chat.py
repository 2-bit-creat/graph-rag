"""Free-form chat over the user's knowledge graph.

Retrieval is deterministic (embedding similarity → 1-hop expansion) so the
returned ``referenced_node_ids`` honestly reflect which memories grounded the
answer — the mobile app uses them to spark the matching nodes on the mini map.
Cost per turn: one embedding call + one chat call.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any
from zoneinfo import ZoneInfo

from openai import APIConnectionError, APIStatusError, APITimeoutError, RateLimitError
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .crud import (
    _identity_nodes_self_first,
    backfill_alias_embeddings,
    find_identities_by_alias_embedding,
    find_statements_lexical,
    find_similar_nodes_with_distance,
    find_statements_by_speaker,
    find_statements_by_time_window,
    user_has_alias_embeddings,
)
from .graph_retrieval import RankedContext, build_ranked_context
from .query_planner import PlannedQuery, create_search_plan
from .models import Node, User
from .name_match import scan_identity_mentions
from .rag import _get_client, embed_text, ensure_statement_embeddings
from .temporal import format_time_window_label, parse_time_window

logger = logging.getLogger(__name__)

_backfill_checked: set[uuid.UUID] = set()


@dataclass
class GraphChatResult:
    answer: str
    referenced_node_ids: list[str] = field(default_factory=list)
    retrieval_status: str = "ok"
    retrieval_meta: dict[str, Any] = field(default_factory=dict)
    learning_card: dict[str, Any] | None = None


async def _create_chat_completion(*, messages: list[dict[str, str]], settings: Any):
    """Create a chat completion with bounded retries for transient provider faults."""
    attempts = 3
    for attempt in range(attempts):
        try:
            return await _get_client().chat.completions.create(
                model=settings.openai_model,
                messages=messages,
                temperature=0.5,
                max_tokens=settings.graph_chat_max_completion_tokens,
                timeout=settings.openai_timeout_sec,
            )
        except (APIConnectionError, APITimeoutError, RateLimitError, APIStatusError) as exc:
            status_code = getattr(exc, "status_code", None)
            retryable = isinstance(exc, (APIConnectionError, APITimeoutError, RateLimitError)) or (
                isinstance(status_code, int) and status_code >= 500
            )
            logger.warning(
                "graph_chat: completion failed (attempt %s/%s, type=%s, status=%s, retryable=%s)",
                attempt + 1,
                attempts,
                type(exc).__name__,
                status_code,
                retryable,
            )
            if not retryable or attempt == attempts - 1:
                raise
            await asyncio.sleep(0.5 * (2**attempt))


async def _retrieve_seeds(
    session: AsyncSession,
    user_id: uuid.UUID,
    message: str,
    *,
    query_vec: list[float] | None = None,
) -> tuple[list[Node], list[float] | None]:
    """Seed nodes for the answer, from two text-embedding indexes:

    - Statement/Concept via ``Node.name_embedding`` (sentence-level similarity), and
    - identity heads (사람·기업/출처·반려동물) via ``node_alias_embeddings`` — these
      carry no ``name_embedding``, so without this "마야가 누구야?" could never seed
      the 마야 node, only statements that happen to be semantically near it.

    One embedding call feeds both searches. Results are merged by node id keeping
    the best (lowest) cosine distance, then sorted nearest-first.

    ``query_vec`` lets a caller that already embedded the (possibly residual,
    speaker-stripped) message reuse that vector instead of paying for a second
    embedding call. Returns ``(seeds, query_vec)`` — the caller needs the actual
    vector used (even when it computed it locally here) to feed the shared
    Context Package builder's similarity ranking downstream."""
    settings = get_settings()
    if query_vec is None:
        try:
            query_vec = await embed_text(message)
        except Exception as exc:  # noqa: BLE001 — chat should still answer without memories
            logger.warning("graph_chat: embedding failed for user %s: %s", user_id, exc)
            return [], None

    scored: list[tuple[Node, float]] = []

    try:
        scored.extend(
            await find_similar_nodes_with_distance(
                session,
                user_id,
                query_vec,
                limit=settings.graph_chat_seed_limit,
                max_distance=settings.graph_chat_max_distance,
            )
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("graph_chat: node retrieval failed for user %s: %s", user_id, exc)

    try:
        scored.extend(
            (node, dist)
            for node, _text, dist in await find_identities_by_alias_embedding(
                session,
                user_id,
                query_vec,
                limit=settings.graph_chat_identity_seed_limit,
                max_distance=settings.graph_chat_identity_max_distance,
            )
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("graph_chat: identity retrieval failed for user %s: %s", user_id, exc)

    best: dict[uuid.UUID, tuple[Node, float]] = {}
    for node, dist in scored:
        prev = best.get(node.id)
        if prev is None or dist < prev[1]:
            best[node.id] = (node, dist)

    seeds = [node for node, _dist in sorted(best.values(), key=lambda x: x[1])][:10]
    return seeds, query_vec


def _split_speaker_residual(message: str, matches: list) -> str:
    """Message text with each matched speaker span removed — the topic-only
    remainder, so a compound query like "하승목 연구원이 성장성 모형 관련해서
    뭘 물었지?" embeds as "성장성 모형 관련해서 뭘 물었지?" instead of diluting
    the vector with a name the embedding search would fail on anyway."""
    residual = message
    for m in sorted(matches, key=lambda m: m.start, reverse=True):
        residual = residual[: m.start] + residual[m.end :]
    residual = " ".join(residual.split())
    return residual if len(residual) >= 4 else message


async def _scan_speaker_matches(
    session: AsyncSession, user_id: uuid.UUID, message: str, *, native_language: str = "korean"
) -> tuple[list, str]:
    """Deterministic (zero LLM/embedding cost) speaker detection: scan the raw
    message text for identity names/aliases the user already has in their
    graph, tolerating whitespace and honorific-suffix variants ("하승목 연구원"
    == "하승목연구원"). Returns ``(matches, residual_message)`` — ``matches`` is
    ``[]`` and residual is the original message when nothing is detected or the
    feature is disabled (``graph_chat_speaker_seed_limit <= 0``)."""
    settings = get_settings()
    if settings.graph_chat_speaker_seed_limit <= 0:
        return [], message
    try:
        identities = await _identity_nodes_self_first(session, user_id)
        matches = scan_identity_mentions(message, identities, native_language)
    except Exception as exc:  # noqa: BLE001 — never block the embedding-only path
        logger.warning("graph_chat: speaker scan failed for user %s: %s", user_id, exc)
        return [], message
    if not matches:
        return [], message
    return matches, _split_speaker_residual(message, matches)


async def _retrieve_speaker_seeds(
    session: AsyncSession,
    user_id: uuid.UUID,
    matches: list,
    *,
    query_vec: list[float] | None,
) -> list[Node]:
    """For each detected speaker, the identity node itself plus every Statement
    it actually SPOKE_OR_PUBLISHED — independent of embedding distance, so a
    compound query no longer silently drops the exact-named speaker's
    statements when the sentence embedding is diluted below the similarity
    cutoff. Statements are ranked by topical relevance to ``query_vec`` (the
    same vector already computed for the residual/topic embedding search) when
    given, else by recency."""
    settings = get_settings()
    seeds: list[Node] = []
    seen_ids: set[uuid.UUID] = set()
    for match in matches[:2]:  # a chat turn realistically names at most 1-2 people
        if match.node.id not in seen_ids:
            seen_ids.add(match.node.id)
            seeds.append(match.node)
        try:
            stmts = await find_statements_by_speaker(
                session,
                user_id,
                match.node.id,
                limit=settings.graph_chat_speaker_seed_limit,
                query_embedding=query_vec,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "graph_chat: speaker statement lookup failed for user %s: %s", user_id, exc
            )
            continue
        for s in stmts:
            if s.id not in seen_ids:
                seen_ids.add(s.id)
                seeds.append(s)
    return seeds


async def _build_context(
    session: AsyncSession,
    user_id: uuid.UUID,
    seeds: list[Node],
    *,
    query_vec: list[float] | None = None,
    time_window: tuple[date, date] | None = None,
    time_window_label: str | None = None,
    native_language: str = "korean",
) -> RankedContext:
    """Delegate 1-hop expansion + RRF rerank + prompt rendering to the shared
    :mod:`graph_retrieval` core (Context Packages, Case A/B/C seed handling)."""
    if not seeds:
        return RankedContext(text=time_window_label or "")
    ranked = await build_ranked_context(
        session,
        user_id,
        seeds,
        query_vec=query_vec,
        time_window=time_window,
        native_language=native_language,
    )
    if time_window_label:
        ranked.text = (
            f"{time_window_label}\n\n{ranked.text}" if ranked.text else time_window_label
        )
    return ranked


def build_graph_chat_messages(
    *,
    message: str,
    history: list[dict[str, Any]],
    context: str,
    summary: str | None = None,
    native_label: str = "Korean (한국어)",
    native_language: str = "korean",
) -> list[dict[str, str]]:
    """Assemble the LLM message list (persona → summary → history → RAG → user)."""
    from .prompts import native_pack

    settings = get_settings()
    pack = native_pack(native_language)
    messages: list[dict[str, str]] = [
        {"role": "system", "content": pack.chat_system_prompt},
    ]
    if summary:
        messages.append(
            {"role": "system", "content": f"{pack.summary_prefix}{summary}"}
        )
    max_history = settings.graph_chat_history_turns + settings.graph_chat_summary_batch
    for m in history[-max_history:]:
        role = m.get("role")
        content = (m.get("content") or "").strip()
        if role in ("user", "assistant") and content:
            messages.append({"role": role, "content": content})
    messages.append(
        {
            "role": "system",
            "content": context or pack.no_context_placeholder,
        }
    )
    messages.append({"role": "user", "content": message})
    return messages


async def graph_chat_answer(
    session: AsyncSession,
    user: User,
    message: str,
    history: list[dict[str, Any]],
    summary: str | None = None,
) -> GraphChatResult:
    settings = get_settings()
    tz = ZoneInfo(settings.chat_timezone)
    now = datetime.now(tz)
    native_language = getattr(user, "native_language", None) or "korean"

    planned: PlannedQuery = await create_search_plan(message, now=now, tz=tz, client=_get_client())
    plan = planned.plan
    # Empty means "any status" — the planner only fills this when the question is
    # about a status. Statements are included on their event date and their
    # status is described in the context, not used to hide them
    # (see SearchPlan._keep_empty_event_status).
    allowed_event_statuses = list(plan.event_status)
    time_window = None
    if plan.time is not None and plan.time.start is not None and plan.time.end is not None:
        time_window = (plan.time.start, plan.time.end)
    time_window_label: str | None = None
    temporal_seeds: list[Node] = []
    if time_window is not None and "temporal_sql" in plan.retrievers:
        start, end = time_window
        temporal_seeds = await find_statements_by_time_window(
            session,
            user.id,
            start,
            end,
            limit=settings.graph_chat_temporal_seed_limit,
            tz_name=settings.chat_timezone,
            event_statuses=allowed_event_statuses,
        )
        time_window_label = format_time_window_label(
            start, end, message, tz, now
        )

    needs_dense = "dense" in plan.retrievers
    if needs_dense and user.id not in _backfill_checked:
        try:
            await ensure_statement_embeddings(session, user.id)
            if not await user_has_alias_embeddings(session, user.id):
                await backfill_alias_embeddings(session, user.id)
            # Only mark as done on success — a transient embedding failure must be
            # retried on the next message, or a new user's journals stay
            # unsearchable for the whole server lifetime.
            _backfill_checked.add(user.id)
        except Exception as exc:  # noqa: BLE001 — backfill failure must not kill chat
            logger.warning("graph_chat: embedding backfill failed: %s", exc)
            await session.rollback()

    # Deterministic, zero-cost scan for an identity name/alias literally present
    # in the message ("하승목 연구원이 ...") — a compound query dilutes the
    # sentence embedding below the similarity cutoff even when the speaker is
    # unambiguous from the text itself. When found, the speaker's name is
    # stripped from the text that gets embedded so the remaining vector is a
    # sharper topic-only query (질의 분해), and both searches share that one
    # embedding call.
    if "entity_exact" in plan.retrievers:
        speaker_matches, residual_message = await _scan_speaker_matches(
            session, user.id, message, native_language=native_language
        )
    else:
        speaker_matches, residual_message = [], message

    query_vec: list[float] | None = None
    speaker_seeds: list[Node] = []
    topic_query = " ".join(plan.topics).strip() or residual_message
    if speaker_matches and needs_dense:
        try:
            query_vec = await embed_text(residual_message)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "graph_chat: residual embedding failed for user %s: %s", user.id, exc
            )
            query_vec = None
    if speaker_matches:
        speaker_seeds = await _retrieve_speaker_seeds(
            session, user.id, speaker_matches, query_vec=query_vec
        )

    embedding_seeds: list[Node] = []
    if needs_dense:
        embedding_seeds, query_vec = await _retrieve_seeds(
            session, user.id, topic_query, query_vec=query_vec
        )

    lexical_seeds: list[Node] = []
    if "lexical" in plan.retrievers and plan.topics:
        lexical_seeds = await find_statements_lexical(
            session,
            user.id,
            plan.topics,
            limit=plan.result_limit,
            start=time_window[0] if time_window and plan.time and plan.time.constraint == "hard" else None,
            end=time_window[1] if time_window and plan.time and plan.time.constraint == "hard" else None,
            event_statuses=allowed_event_statuses,
        )

    seen: set[uuid.UUID] = set()
    seeds: list[Node] = []
    seed_candidates = temporal_seeds + lexical_seeds + speaker_seeds + embedding_seeds
    # A user-specified hard period is a candidate-generation constraint, not
    # merely an RRF penalty. Keep only matching Statement seeds; graph expansion
    # receives the same window for identity paths.
    if time_window is not None and plan.time and plan.time.constraint == "hard":
        start, end = time_window
        seed_candidates = [
            node for node in seed_candidates
            if node.type != "Statement"
            or (
                (
                    not allowed_event_statuses
                    or (node.event_status or "happened") in allowed_event_statuses
                )
                and start <= (node.occurred_at or (node.event_start_at.date() if node.event_start_at else node.created_at.date())) <= end
            )
        ]
    for node in seed_candidates:
        if node.id in seen:
            continue
        seen.add(node.id)
        seeds.append(node)

    referenced_node_ids = [str(n.id) for n in seeds]
    ranked = RankedContext(text="")
    try:
        ranked = await _build_context(
            session,
            user.id,
            seeds,
            query_vec=query_vec,
            time_window=time_window,
            time_window_label=time_window_label,
            native_language=native_language,
        )
        context = ranked.text
        if ranked.node_ids:
            referenced_node_ids = [str(nid) for nid in ranked.node_ids]
    except Exception as exc:  # noqa: BLE001 — degrade to a memory-less answer, never 500
        logger.warning("graph_chat: context build failed for user %s: %s", user.id, exc)
        await session.rollback()
        context = time_window_label or ""
        referenced_node_ids = [str(n.id) for n in temporal_seeds]

    from .languages import label as _language_label

    native_label = _language_label(native_language, default="korean")
    messages = build_graph_chat_messages(
        message=message,
        history=history,
        context=context,
        summary=summary,
        native_label=native_label,
        native_language=native_language,
    )

    resp = await _create_chat_completion(messages=messages, settings=settings)
    answer = (resp.choices[0].message.content or "").strip()

    learning_card = None
    if plan.learning.enabled and plan.learning.mode == "optional_followup" and ranked.packages:
        target = getattr(user, "target_language", "english") or "english"
        learning_card = {
            "type": "memory_recall",
            "target_language": target,
            "source_node_id": str(ranked.packages[0].statement.id),
            "prompt": f"이 기억을 {target}로 한 문장으로 말해볼래?",
        }
    retrieval_meta = {
        "answer_intent": plan.answer_intent,
        "retrievers": plan.retrievers,
        "time": (
            {"start": time_window[0].isoformat(), "end": time_window[1].isoformat(), "constraint": plan.time.constraint}
            if time_window and plan.time else None
        ),
        "planner_status": planned.status,
        "event_status": allowed_event_statuses,
        "candidate_counts": {
            "temporal_sql": len(temporal_seeds),
            "lexical": len(lexical_seeds),
            "entity": len(speaker_seeds),
            "dense": len(embedding_seeds),
            "after_hard_filters": len(seeds),
            "context_packages": len(ranked.packages),
        },
        "referenced_count": len(referenced_node_ids),
    }
    if settings.debug_enabled:
        retrieval_meta["planner_raw"] = planned.raw_plan
        retrieval_meta["planner_error"] = planned.error
    return GraphChatResult(
        answer=answer,
        referenced_node_ids=referenced_node_ids,
        retrieval_status=planned.status,
        retrieval_meta=retrieval_meta,
        learning_card=learning_card,
    )
