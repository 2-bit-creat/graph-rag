"""Shared GraphRAG retrieval core: seeds -> Context Packages -> RRF rerank -> prompt text.

Consumed by both :mod:`graph_chat` (chat) and :mod:`rag` (quiz). Replaces two
independent, drifting seed-expansion implementations — the drift had already
produced a real bug: a Concept seed's connected Statement only got its full
sentence pulled in graph_chat's identity-only expansion branch, not here.

Seed-type expansion (1-hop, Case A/B/C) — every case ends up as one or more
:class:`ContextPackage`, one per Statement, deduplicated by statement id:

  A. Concept seed   -> its CONTEXT-linked Statements, most recent first, capped.
  B. Identity seed  -> that speaker's Statements. Signals COMPOSE: an explicit
                        time window is a hard pre-filter; within it, statements
                        linked to sibling Concept seeds come first, then the
                        nearest by query embedding, then plain recency fills any
                        remaining slots (see crud.find_statements_by_speaker).
  C. Statement seed -> itself, with its speaker + CONTEXT concepts + MENTIONS
                        identities attached directly (no query needed).

A final Reciprocal Rank Fusion (RRF) pass combines vector similarity, connected-
concept importance, and recency into one ranking, with a soft (never hard)
penalty for packages outside an explicit query time window — a vaguely-timed
question shouldn't lose a genuinely relevant memory outright.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from datetime import UTC, date, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .entity_types import is_identity_type
from .models import Node

# Worst possible cosine distance (unit vectors) — used to rank a package with no
# embedding-comparable statement last rather than crashing the sort.
_WORST_DISTANCE = 2.0


@dataclass
class ContextPackage:
    """One Statement plus everything needed to render it for an LLM prompt."""

    statement: Node
    speaker: Node | None = None
    concepts: list[Node] = field(default_factory=list)
    mentions: list[Node] = field(default_factory=list)
    seed_reason: str = ""  # which case (A/B/C) produced this package — debug only

    @property
    def id(self) -> uuid.UUID:
        return self.statement.id

    @property
    def occurred_at(self) -> date:
        return self.statement.occurred_at or self.statement.created_at.date()


@dataclass
class RankedContext:
    text: str
    packages: list[ContextPackage] = field(default_factory=list)
    node_ids: list[uuid.UUID] = field(default_factory=list)


def statement_content(node: Node) -> str:
    """The diary sentence a Statement node actually holds. ``description`` is
    JSON with the real text under ``content``; ``name`` is a short title, not
    the sentence — callers that render node.name for a Statement show the
    wrong thing."""
    desc = (node.description or "").strip()
    if not desc:
        return node.name
    try:
        content = (json.loads(desc).get("content") or "").strip()
        if content:
            return content
    except (ValueError, AttributeError):
        pass
    parts = desc.split("\n", 1)
    return (parts[1] if len(parts) > 1 else parts[0]).strip() or node.name


async def _hydrate_packages(
    session: AsyncSession,
    user_id: uuid.UUID,
    statement_by_id: dict[uuid.UUID, Node],
    reason_by_id: dict[uuid.UUID, str],
) -> list[ContextPackage]:
    """Batch-attach speaker/concepts/mentions to a set of Statement nodes —
    one query per relation type regardless of how many statements/packages."""
    settings = get_settings()
    stmt_ids = set(statement_by_id)
    if not stmt_ids:
        return []
    speakers = await crud.get_speakers_for_statements(session, user_id, stmt_ids)
    concepts = await crud.get_concepts_for_statements(
        session, user_id, stmt_ids, limit_per_statement=settings.graph_case_c_concept_limit
    )
    mentions = await crud.get_mentions_for_statements(
        session, user_id, stmt_ids, limit_per_statement=settings.graph_case_c_mention_limit
    )
    return [
        ContextPackage(
            statement=node,
            speaker=speakers.get(sid),
            concepts=concepts.get(sid, []),
            mentions=mentions.get(sid, []),
            seed_reason=reason_by_id.get(sid, ""),
        )
        for sid, node in statement_by_id.items()
    ]


async def build_context_packages(
    session: AsyncSession,
    user_id: uuid.UUID,
    seeds: list[Node],
    *,
    query_vec: list[float] | None = None,
    time_window: tuple[date, date] | None = None,
) -> list[ContextPackage]:
    """Expand seed nodes (any mix of Concept/Identity/Statement) into Context
    Packages, branching by seed type. See module docstring for Case A/B/C."""
    settings = get_settings()
    start, end = time_window if time_window is not None else (None, None)

    statement_seeds = [n for n in seeds if n.type == "Statement"]
    concept_seeds = [n for n in seeds if n.type == "Concept"]
    identity_seeds = [n for n in seeds if is_identity_type(n.type)]
    concept_seed_ids = {n.id for n in concept_seeds}

    statement_by_id: dict[uuid.UUID, Node] = {}
    reason_by_id: dict[uuid.UUID, str] = {}

    def _add(node: Node, reason: str) -> None:
        if node.id not in statement_by_id:
            statement_by_id[node.id] = node
            reason_by_id[node.id] = reason

    # Case C: a Statement seed carries itself directly.
    for node in statement_seeds:
        _add(node, "case_c_statement_seed")

    # Case A: Concept seeds -> their linked Statements.
    for concept in concept_seeds:
        linked = await crud.find_statements_by_concept(
            session, user_id, concept.id, limit=settings.graph_case_a_statement_limit
        )
        for node in linked:
            _add(node, "case_a_concept_seed")

    # Case B: Identity seeds -> that speaker's Statements, composed filters.
    # Falls back to statements that merely MENTION the identity when it has no
    # SPOKE_OR_PUBLISHED statements at all — an Identity like a pet is never a
    # speaker, so "마야가 누구야?" must still surface what's said ABOUT her.
    for identity in identity_seeds:
        linked = await crud.find_statements_by_speaker(
            session,
            user_id,
            identity.id,
            limit=settings.graph_case_b_statement_limit,
            query_embedding=query_vec,
            start=start,
            end=end,
            concept_ids=concept_seed_ids or None,
        )
        for node in linked:
            _add(node, "case_b_identity_seed")
        if not linked:
            mentioned_in = await crud.find_statements_mentioning(
                session, user_id, identity.id, limit=settings.graph_case_b_statement_limit
            )
            for node in mentioned_in:
                _add(node, "case_b_identity_mentioned")

    return await _hydrate_packages(session, user_id, statement_by_id, reason_by_id)


async def _distance_by_statement(
    session: AsyncSession, statement_ids: set[uuid.UUID], query_vec: list[float]
) -> dict[uuid.UUID, float]:
    if not statement_ids or not query_vec:
        return {}
    dist = Node.name_embedding.cosine_distance(query_vec)
    rows = await session.execute(
        select(Node.id, dist).where(
            Node.id.in_(statement_ids), Node.name_embedding.isnot(None)
        )
    )
    return {row[0]: float(row[1]) for row in rows.all()}


def _package_importance(pkg: ContextPackage) -> int:
    """Max importance_score among a package's connected concepts — max rather
    than sum, so a package doesn't rank higher just for mentioning more
    concepts than another equally-important one."""
    if not pkg.concepts:
        return 0
    return max((c.importance_score or 0) for c in pkg.concepts)


def _package_recency_key(pkg: ContextPackage) -> datetime:
    occurred = pkg.occurred_at
    return datetime(occurred.year, occurred.month, occurred.day, tzinfo=UTC)


def _competition_ranks(
    packages: list[ContextPackage], sort_key
) -> dict[uuid.UUID, float]:
    """0-based ranks, ascending by ``sort_key`` (best/lowest first), with ties
    resolved by AVERAGING the tied positions rather than by list order.

    Without this, two packages a signal genuinely can't distinguish (e.g. both
    have 0 connected-concept importance) would still get different sequential
    ranks purely from whichever happened to come first in ``packages`` —
    letting an uninformative signal silently outvote a real one like recency.
    """
    ordered = sorted(packages, key=sort_key)
    ranks: dict[uuid.UUID, float] = {}
    i = 0
    n = len(ordered)
    while i < n:
        j = i
        while j + 1 < n and sort_key(ordered[j + 1]) == sort_key(ordered[i]):
            j += 1
        avg_rank = (i + j) / 2.0
        for x in range(i, j + 1):
            ranks[ordered[x].id] = avg_rank
        i = j + 1
    return ranks


async def rank_packages(
    session: AsyncSession,
    packages: list[ContextPackage],
    *,
    query_vec: list[float] | None = None,
    time_window: tuple[date, date] | None = None,
) -> list[ContextPackage]:
    """Reciprocal Rank Fusion over 3 signals — vector similarity, connected-
    concept importance, recency — plus a soft penalty (never a hard cutoff)
    for packages outside an explicit query time window.

    ``Score = sum(1 / (k + rank_i))`` for each signal's 0-based rank; higher is
    better. ``k`` (``settings.graph_rrf_k``) is the standard RRF smoothing
    constant — larger values flatten the influence of rank differences.
    """
    if not packages:
        return []
    settings = get_settings()
    k = settings.graph_rrf_k

    distances: dict[uuid.UUID, float] = {}
    if query_vec is not None:
        distances = await _distance_by_statement(
            session, {p.id for p in packages}, query_vec
        )

    rank_similarity = _competition_ranks(
        packages, lambda p: distances.get(p.id, _WORST_DISTANCE)
    )
    rank_importance = _competition_ranks(packages, lambda p: -_package_importance(p))
    rank_recency = _competition_ranks(
        packages, lambda p: -_package_recency_key(p).timestamp()
    )

    start, end = time_window if time_window is not None else (None, None)

    def _score(pkg: ContextPackage) -> float:
        score = (
            1.0 / (k + rank_similarity[pkg.id])
            + 1.0 / (k + rank_importance[pkg.id])
            + 1.0 / (k + rank_recency[pkg.id])
        )
        if start is not None and end is not None and not (start <= pkg.occurred_at <= end):
            score *= settings.graph_time_penalty_factor
        return score

    return sorted(packages, key=_score, reverse=True)


def _identity_label(node: Node) -> str:
    return "나" if node.is_self else node.name


def _format_package(index: int, pkg: ContextPackage) -> str:
    lines = [f"기록 {index}:"]
    if pkg.speaker is not None:
        suffix = "" if pkg.speaker.is_self else f" ({pkg.speaker.type})"
        lines.append(f"- 화자: {_identity_label(pkg.speaker)}{suffix}")
    lines.append(f"- 일시: {pkg.occurred_at.isoformat()}")
    lines.append(f'- 진술: "{statement_content(pkg.statement)}"')
    if pkg.concepts:
        lines.append(f"- 연관 개념: {', '.join(c.name for c in pkg.concepts)}")
    if pkg.mentions:
        # Kept separate from 연관 개념 on purpose: these are people the statement
        # talks ABOUT, not who said it — conflating the two is a bug we've hit
        # before (see graph_chat._build_system_prompt's explicit warning).
        lines.append(f"- 언급된 인물: {', '.join(m.name for m in pkg.mentions)}")
    return "\n".join(lines)


def _seed_description_lines(seeds: list[Node]) -> list[str]:
    """A seeded Identity/Concept's own ``description`` (who/what it is) — e.g.
    마야's "내 고양이". Context Packages are Statement-centric, so without this
    a seed with no Statement of its own (or one that only gets pulled in via a
    MENTIONS fallback) would never have its own description surface at all."""
    lines: list[str] = []
    seen: set[uuid.UUID] = set()
    for node in seeds:
        if node.type == "Statement" or node.id in seen:
            continue
        desc = (node.description or "").strip()
        if not desc:
            continue
        seen.add(node.id)
        lines.append(f"- {_identity_label(node)}: {desc}")
    return lines


def build_final_prompt_context(
    packages: list[ContextPackage], *, top_k: int | None = None, seeds: list[Node] | None = None
) -> str:
    """Render the (already RRF-ranked) top packages into LLM-ready text, with
    any seeded identity/concept's own description surfaced first."""
    settings = get_settings()
    k = top_k if top_k is not None else settings.graph_context_top_k
    top = packages[:k]

    parts: list[str] = []
    desc_lines = _seed_description_lines(seeds or [])
    if desc_lines:
        parts.append("알고 있는 대상:\n" + "\n".join(desc_lines))
    if top:
        parts.append(
            "\n\n".join(_format_package(i, pkg) for i, pkg in enumerate(top, start=1))
        )
    return "\n\n".join(parts)


async def build_ranked_context(
    session: AsyncSession,
    user_id: uuid.UUID,
    seeds: list[Node],
    *,
    query_vec: list[float] | None = None,
    time_window: tuple[date, date] | None = None,
    top_k: int | None = None,
) -> RankedContext:
    """End-to-end: seeds -> Context Packages -> RRF rerank -> prompt text.

    The one function graph_chat.py and rag.py both call so their retrieval
    behavior can no longer drift apart the way it did before this module.
    """
    settings = get_settings()
    packages = await build_context_packages(
        session, user_id, seeds, query_vec=query_vec, time_window=time_window
    )
    ranked = await rank_packages(
        session, packages, query_vec=query_vec, time_window=time_window
    )
    text = build_final_prompt_context(ranked, top_k=top_k, seeds=seeds)

    cutoff = top_k if top_k is not None else settings.graph_context_top_k
    node_ids: list[uuid.UUID] = []
    seen_ids: set[uuid.UUID] = set()

    def _collect(node: Node | None) -> None:
        if node is not None and node.id not in seen_ids:
            seen_ids.add(node.id)
            node_ids.append(node.id)

    for node in seeds:
        if (node.description or "").strip():
            _collect(node)

    for pkg in ranked[:cutoff]:
        _collect(pkg.statement)
        _collect(pkg.speaker)
        for c in pkg.concepts:
            _collect(c)
        for m in pkg.mentions:
            _collect(m)

    return RankedContext(text=text, packages=ranked, node_ids=node_ids)
