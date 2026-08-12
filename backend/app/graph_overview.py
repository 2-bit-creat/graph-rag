"""Aggregate answers for questions ABOUT the graph, not about a memory in it.

"내 그래프에 뭐가 있어?" and "요즘 내가 자주 말한 주제는?" have no single
Statement to be similar to, so every similarity retriever returns nothing for
them and graph chat fell back to "관련된 일기 기억이 없습니다" — the app looked
like it had forgotten everything the user had ever written. The answer to those
questions is a handful of SQL aggregates, which is what this builds.

Everything here counts in Postgres. Not one ORM row is hydrated: a Node carries
a 1536-dim name embedding, and pulling those back just to call ``len()`` is the
single slowest mistake available in this codebase.
"""

from __future__ import annotations

import logging
import uuid

from sqlalchemy import Date, cast, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .graph_schema import REL_CONTEXT, REL_SPOKE_OR_PUBLISHED
from .models import Edge, Node

logger = logging.getLogger(__name__)

# Type labels are user-extensible (ontology presets), so the summary line names
# the ones that carry meaning for a learner and lumps the rest under 기타 rather
# than inventing a translation for a type it has never seen.
_TYPE_LABELS = {
    "Statement": "진술",
    "Concept": "개념",
    "Source": "출처",
    "Identity": "정체성",
    # Legacy rows on graphs that predate the Person→Identity collapse.
    "Person": "정체성",
}


async def _counts_by_type(session: AsyncSession, user_id: uuid.UUID) -> dict[str, int]:
    """One grouped scan. Mirrors the query behind /kg/stats, soft-delete included."""
    rows = await session.execute(
        select(Node.type, func.count())
        .where(Node.user_id == user_id, Node.deleted_at.is_(None))
        .group_by(Node.type)
    )
    return {str(node_type): int(count) for node_type, count in rows.all()}


async def _top_concepts(
    session: AsyncSession, user_id: uuid.UUID, limit: int
) -> list[tuple[str, int]]:
    """Concepts by how many Statements point at them.

    Rides idx_edges_target_relation. Soft-deleting a Statement hard-deletes its
    edges, so counting edges cannot resurrect a trashed memory's topics and the
    source side needs no second check.
    """
    rows = await session.execute(
        select(Node.name, func.count(Edge.id).label("uses"))
        .join(Edge, Edge.target_id == Node.id)
        .where(
            Node.user_id == user_id,
            Node.deleted_at.is_(None),
            Node.type == "Concept",
            Edge.user_id == user_id,
            Edge.relation == REL_CONTEXT,
        )
        .group_by(Node.id, Node.name)
        .order_by(func.count(Edge.id).desc(), Node.name)
        .limit(limit)
    )
    return [(str(name), int(uses)) for name, uses in rows.all()]


async def _top_speakers(
    session: AsyncSession, user_id: uuid.UUID, limit: int
) -> list[tuple[str, int]]:
    """Who the statements are attributed to, by volume.

    No entity-type filter is needed or wanted: being the source of a
    SPOKE_OR_PUBLISHED edge is what makes a node a speaker, whatever subtype it
    was stored as (Person / Source / Identity).
    """
    rows = await session.execute(
        select(Node.name, func.count(Edge.id).label("said"))
        .join(Edge, Edge.source_id == Node.id)
        .where(
            Node.user_id == user_id,
            Node.deleted_at.is_(None),
            Edge.user_id == user_id,
            Edge.relation == REL_SPOKE_OR_PUBLISHED,
        )
        .group_by(Node.id, Node.name)
        .order_by(func.count(Edge.id).desc(), Node.name)
        .limit(limit)
    )
    return [(str(name), int(said)) for name, said in rows.all()]


async def _span(session: AsyncSession, user_id: uuid.UUID) -> tuple[str | None, str | None]:
    """First and last day the graph has a Statement for. One row.

    occurred_at is the resolved event day when the extractor found one; the rows
    without it fall back to when the entry was written, matching how the rest of
    the app orders a timeline.
    """
    day = func.coalesce(Node.occurred_at, cast(Node.created_at, Date))
    row = (
        await session.execute(
            select(func.min(day), func.max(day)).where(
                Node.user_id == user_id,
                Node.deleted_at.is_(None),
                Node.type == "Statement",
            )
        )
    ).one_or_none()
    if not row or row[0] is None:
        return None, None
    return row[0].isoformat(), row[1].isoformat()


def _type_breakdown(counts: dict[str, int]) -> str:
    named = [
        f"{label} {counts[node_type]}개"
        for node_type, label in _TYPE_LABELS.items()
        if counts.get(node_type)
    ]
    other = sum(count for t, count in counts.items() if t not in _TYPE_LABELS)
    if other:
        named.append(f"기타 {other}개")
    return " · ".join(named)


async def build_graph_overview(
    session: AsyncSession, user_id: uuid.UUID
) -> str:
    """A plain-text summary of the whole graph, or "" when it is empty."""
    settings = get_settings()
    counts = await _counts_by_type(session, user_id)
    total = sum(counts.values())
    if not total:
        return ""

    concepts = await _top_concepts(session, user_id, settings.graph_chat_overview_top_concepts)
    speakers = await _top_speakers(session, user_id, settings.graph_chat_overview_top_speakers)
    first_day, last_day = await _span(session, user_id)

    lines = [
        "[내 그래프 전체 요약]",
        f"- 전체 노드 {total}개 ({_type_breakdown(counts)})",
    ]
    if first_day and last_day:
        lines.append(
            f"- 기록 기간: {first_day} ~ {last_day}"
            if first_day != last_day
            else f"- 기록 날짜: {first_day}"
        )
    if concepts:
        lines.append(
            "- 자주 등장한 개념: "
            + ", ".join(f"{name}({uses})" for name, uses in concepts)
        )
    if speakers:
        lines.append(
            "- 화자별 진술 수: "
            + ", ".join(f"{name}({said})" for name, said in speakers)
        )
    return "\n".join(lines)


async def safe_graph_overview(session: AsyncSession, user_id: uuid.UUID) -> str:
    """build_graph_overview, but a failure here never costs the user their answer."""
    try:
        return await build_graph_overview(session, user_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("graph overview failed for user %s: %s", user_id, exc)
        return ""
