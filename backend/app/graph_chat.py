"""Free-form chat over the user's knowledge graph.

Retrieval is deterministic (embedding similarity → 1-hop expansion) so the
returned ``referenced_node_ids`` honestly reflect which memories grounded the
answer — the mobile app uses them to spark the matching nodes on the mini map.
Cost per turn: one embedding call + one chat call.
"""

from __future__ import annotations

import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .crud import (
    backfill_alias_embeddings,
    find_identities_by_alias_embedding,
    find_similar_nodes_with_distance,
    find_statements_by_time_window,
    get_neighborhood,
    user_has_alias_embeddings,
)
from .entity_types import is_identity_type
from .llm_usage import log_usage
from .models import Edge, Node, User
from .rag import _get_client, embed_text, ensure_statement_embeddings
from .temporal import format_time_window_label, parse_time_window

logger = logging.getLogger(__name__)

_backfill_checked: set[uuid.UUID] = set()


@dataclass
class GraphChatResult:
    answer: str
    referenced_node_ids: list[str] = field(default_factory=list)


def _statement_content(node: Node) -> str:
    desc = (node.description or "").strip()
    if not desc:
        return node.name
    if node.type == "Statement":
        try:
            content = (json.loads(desc).get("content") or "").strip()
            if content:
                return content
        except (ValueError, AttributeError):
            pass
        parts = desc.split("\n", 1)
        return (parts[1] if len(parts) > 1 else parts[0]).strip() or node.name
    return node.name


def _node_date_prefix(node: Node) -> str:
    if getattr(node, "occurred_at", None):
        return node.occurred_at.isoformat()
    if node.created_at:
        return node.created_at.date().isoformat()
    return ""


def _node_memory_text(node: Node) -> str:
    """One readable memory line for a seed node. A Statement contributes its
    sentence; an identity/concept contributes ``name — description`` (who/what it
    is) so an identity seed like 마야 isn't reduced to a bare label."""
    if node.type == "Statement":
        return _statement_content(node)
    desc = (node.description or "").strip()
    return f"{node.name} — {desc}" if desc else node.name


async def _retrieve_seeds(
    session: AsyncSession, user_id: uuid.UUID, message: str
) -> list[Node]:
    """Seed nodes for the answer, from two text-embedding indexes:

    - Statement/Concept via ``Node.name_embedding`` (sentence-level similarity), and
    - identity heads (사람·기업/출처·반려동물) via ``node_alias_embeddings`` — these
      carry no ``name_embedding``, so without this "마야가 누구야?" could never seed
      the 마야 node, only statements that happen to be semantically near it.

    One embedding call feeds both searches. Results are merged by node id keeping
    the best (lowest) cosine distance, then sorted nearest-first.
    """
    settings = get_settings()
    try:
        query_vec = await embed_text(message)
    except Exception as exc:  # noqa: BLE001 — chat should still answer without memories
        logger.warning("graph_chat: embedding failed for user %s: %s", user_id, exc)
        return []

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

    return [node for node, _dist in sorted(best.values(), key=lambda x: x[1])][:10]


async def _build_context(
    session: AsyncSession,
    user_id: uuid.UUID,
    seeds: list[Node],
    *,
    time_window: tuple[date, date] | None = None,
    time_window_label: str | None = None,
) -> str:
    if not seeds:
        return ""
    settings = get_settings()
    seed_limit = (
        settings.graph_chat_temporal_seed_limit
        if time_window is not None
        else 10
    )
    seed_ids = {n.id for n in seeds}
    node_ids = await get_neighborhood(session, user_id, seed_ids, depth=1)

    nodes = (
        (await session.execute(select(Node).where(Node.id.in_(node_ids)))).scalars().all()
    )
    active = [n for n in nodes if n.deleted_at is None]
    name_by_id = {n.id: n.name for n in active}
    node_by_id = {n.id: n for n in active}

    edges = (
        (
            await session.execute(
                select(Edge)
                .where(
                    Edge.user_id == user_id,
                    or_(Edge.source_id.in_(node_ids), Edge.target_id.in_(node_ids)),
                )
                .order_by(Edge.weight.desc())
                .limit(settings.graph_chat_max_triples)
            )
        )
        .scalars()
        .all()
    )

    # Statements adjacent to an identity seed carry the "who they are / what
    # happened" detail that answers "마야가 누구야?"; the triples below only expose
    # node NAMES (short labels), so pull those statements' full content in too.
    identity_seed_ids = {n.id for n in seeds if is_identity_type(n.type)}
    related_stmt_ids: list[uuid.UUID] = []
    if identity_seed_ids:
        seen_stmt: set[uuid.UUID] = set()
        for e in edges:
            for anchor, other in ((e.source_id, e.target_id), (e.target_id, e.source_id)):
                if anchor not in identity_seed_ids or other in seen_stmt:
                    continue
                nb = node_by_id.get(other)
                if nb is not None and nb.type == "Statement":
                    seen_stmt.add(other)
                    related_stmt_ids.append(other)

    memory_lines: list[str] = []
    seen_lines: set[str] = set()

    def _add(text: str, when: str = "") -> None:
        text = text.strip()
        if not text or text in seen_lines:
            return
        seen_lines.add(text)
        prefix = f"[{when}] " if when else ""
        memory_lines.append(f"- {prefix}{text}")

    for node in seeds[:seed_limit]:
        _add(_node_memory_text(node), _node_date_prefix(node))

    for sid in related_stmt_ids[:12]:
        node = node_by_id[sid]
        _add(_statement_content(node), _node_date_prefix(node))

    seen_triples: set[str] = set()
    triple_lines: list[str] = []
    for e in edges:
        if e.source_id not in name_by_id or e.target_id not in name_by_id:
            continue
        line = (
            f"({name_by_id[e.source_id]}) -[{e.relation}]-> ({name_by_id[e.target_id]})"
        )
        if line in seen_triples:
            continue
        seen_triples.add(line)
        triple_lines.append(line)

    parts = []
    if time_window_label:
        parts.append(time_window_label)
    if memory_lines:
        parts.append("사용자의 일기 기억:\n" + "\n".join(memory_lines))
    if triple_lines:
        parts.append("지식그래프 사실:\n" + "\n".join(triple_lines))
    return "\n\n".join(parts)


_SYSTEM_PROMPT = (
    "당신은 사용자의 일기를 기억하는 친근한 대화 상대입니다. 사용자가 심심할 때 "
    "편하게 수다를 떨러 오는 공간이에요. 따뜻하고 자연스러운 한국어로 대화하세요 "
    "(사용자가 다른 언어를 쓰면 맞춰주세요). "
    "아래에 제공되는 '일기 기억'과 '지식그래프 사실'은 사용자가 실제로 쓴 일기에서 "
    "나온 것입니다. 관련이 있을 때 자연스럽게 언급하며 대화하되, 기억에 없는 내용을 "
    "지어내지 마세요. 관련 기억이 없으면 솔직하게 모른다고 하고 가볍게 되물어보세요. "
    "'지금까지의 대화 요약'은 이 채팅방의 이전 대화를 압축한 것이지 일기 기억이 "
    "아닙니다 — 요약을 일기 기억처럼 인용하지 마세요. "
    "일기 기억 각 줄 앞의 [날짜]는 사건이 일어난 날(있으면) 또는 일기에 기록된 "
    "날입니다 — '언제 …했지?' 같은 질문에는 이 날짜로 답하세요. "
    "요청 기간이 명시되어 있고 그 기간의 기록이 없으면 지어내지 말고 "
    "그 기간의 기록이 없다고 말하세요. "
    "답변은 수다 톤으로 짧고 편하게 — 강의하지 마세요."
)


def build_graph_chat_messages(
    *,
    message: str,
    history: list[dict[str, Any]],
    context: str,
    summary: str | None = None,
) -> list[dict[str, str]]:
    """Assemble the LLM message list (persona → summary → history → RAG → user)."""
    settings = get_settings()
    messages: list[dict[str, str]] = [
        {"role": "system", "content": _SYSTEM_PROMPT},
    ]
    if summary:
        messages.append(
            {"role": "system", "content": f"지금까지의 대화 요약:\n{summary}"}
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
            "content": context or "(이번 메시지와 관련된 일기 기억이 없습니다.)",
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

    time_window = parse_time_window(message, tz, now)
    time_window_label: str | None = None
    temporal_seeds: list[Node] = []
    if time_window is not None:
        start, end = time_window
        temporal_seeds = await find_statements_by_time_window(
            session,
            user.id,
            start,
            end,
            limit=settings.graph_chat_temporal_seed_limit,
            tz_name=settings.chat_timezone,
        )
        time_window_label = format_time_window_label(
            start, end, message, tz, now
        )

    if user.id not in _backfill_checked:
        _backfill_checked.add(user.id)
        try:
            await ensure_statement_embeddings(session, user.id)
            if not await user_has_alias_embeddings(session, user.id):
                await backfill_alias_embeddings(session, user.id)
        except Exception as exc:  # noqa: BLE001 — backfill failure must not kill chat
            logger.warning("graph_chat: embedding backfill failed: %s", exc)
            await session.rollback()

    embedding_seeds = await _retrieve_seeds(session, user.id, message)

    seen: set[uuid.UUID] = set()
    seeds: list[Node] = []
    for node in temporal_seeds + embedding_seeds:
        if node.id in seen:
            continue
        seen.add(node.id)
        seeds.append(node)

    try:
        context = await _build_context(
            session,
            user.id,
            seeds,
            time_window=time_window,
            time_window_label=time_window_label,
        )
    except Exception as exc:  # noqa: BLE001 — degrade to a memory-less answer, never 500
        logger.warning("graph_chat: context build failed for user %s: %s", user.id, exc)
        await session.rollback()
        context = time_window_label or ""
        seeds = temporal_seeds

    messages = build_graph_chat_messages(
        message=message,
        history=history,
        context=context,
        summary=summary,
    )

    resp = await _get_client().chat.completions.create(
        model=settings.openai_model,
        messages=messages,
        temperature=0.5,
        max_tokens=settings.graph_chat_max_completion_tokens,
        timeout=settings.openai_timeout_sec,
    )
    log_usage("graph_chat", resp)
    answer = (resp.choices[0].message.content or "").strip()

    return GraphChatResult(
        answer=answer,
        referenced_node_ids=[str(n.id) for n in seeds],
    )
