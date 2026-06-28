from __future__ import annotations

import random
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .models import Edge, JournalGraphLink, Node
from .quiz_settings import quiz_selection_settings
from .rag import hybrid_retrieve


@dataclass
class QuizGraphSelection:
    settings: dict
    seed_nodes: list[dict] = field(default_factory=list)
    candidate_count: int = 0
    selected_nodes: list[dict] = field(default_factory=list)
    selected_edges: list[dict] = field(default_factory=list)
    pick_breakdown: dict[str, int] = field(default_factory=dict)
    context_text: str = ""
    source_node_ids: list[uuid.UUID] = field(default_factory=list)


def _node_dict(
    node: Node,
    *,
    link_created_at: datetime | None = None,
    pick_reason: str = "",
) -> dict:
    ts = link_created_at or node.created_at
    return {
        "id": str(node.id),
        "name": node.name,
        "type": node.type,
        "created_at": node.created_at.isoformat() if node.created_at else None,
        "link_created_at": link_created_at.isoformat() if link_created_at else None,
        "recency_at": ts.isoformat() if ts else None,
        "pick_reason": pick_reason,
    }


def _edge_dict(edge: Edge, source_name: str, target_name: str) -> dict:
    return {
        "id": str(edge.id),
        "source": source_name,
        "relation": edge.relation,
        "target": target_name,
        "created_at": edge.created_at.isoformat() if edge.created_at else None,
    }


def _recency_score(ts: datetime | None) -> float:
    if ts is None:
        return 0.0
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=UTC)
    age_days = max(0.0, (datetime.now(UTC) - ts).total_seconds() / 86400.0)
    return 1.0 / (1.0 + age_days)


def _weighted_sample_without_replacement(
    items: list[tuple[uuid.UUID, float]],
    k: int,
    rng: random.Random | None = None,
) -> list[uuid.UUID]:
    """Pure-Python weighted sampling without replacement (no NumPy)."""
    if k <= 0 or not items:
        return []
    rng = rng or random.Random()
    pool = list(items)
    picked: list[uuid.UUID] = []
    for _ in range(min(k, len(pool))):
        weights = [max(w, 0.0) for _, w in pool]
        total = sum(weights)
        if total <= 0:
            idx = rng.randrange(len(pool))
        else:
            r = rng.random() * total
            acc = 0.0
            idx = 0
            for i, w in enumerate(weights):
                acc += w
                if r <= acc:
                    idx = i
                    break
        nid, _ = pool.pop(idx)
        picked.append(nid)
    return picked


def _pick_non_seed_nodes(
    *,
    candidates: dict[uuid.UUID, Node],
    seed_ids: set[uuid.UUID],
    link_ts: dict[uuid.UUID, datetime | None],
    max_nodes: int,
    recency_w: float,
    selected_ids: list[uuid.UUID],
    id_reason: dict[uuid.UUID, str],
    pick_breakdown: dict[str, int],
) -> None:
    """70/30 weighted recency + uniform random picks among non-seed candidates."""
    n_recent = max(0, min(max_nodes, round(max_nodes * recency_w)))
    n_random = max(0, max_nodes - n_recent)

    non_seed = [
        nid
        for nid in candidates
        if nid not in seed_ids and nid not in selected_ids
    ]
    scored = [
        (nid, _recency_score(link_ts.get(nid) or candidates[nid].created_at))
        for nid in non_seed
    ]

    for nid in _weighted_sample_without_replacement(scored, n_recent):
        if len(selected_ids) >= max_nodes:
            break
        selected_ids.append(nid)
        id_reason[nid] = "recency"
        pick_breakdown["recency"] += 1

    pool = [nid for nid in non_seed if nid not in selected_ids]
    if pool and n_random > 0 and len(selected_ids) < max_nodes:
        picks = random.sample(pool, min(n_random, len(pool), max_nodes - len(selected_ids)))
        for nid in picks:
            selected_ids.append(nid)
            id_reason[nid] = "random"
            pick_breakdown["random"] += 1


def _format_context(nodes: list[dict], edges: list[dict]) -> str:
    lines: list[str] = []
    for n in nodes:
        lines.append(f"Node: {n['name']} ({n['type']})")
    for e in edges:
        lines.append(f"Edge: {e['source']} --{e['relation']}--> {e['target']}")
    return "\n".join(lines) if lines else "(no graph context — journal text only)"


async def list_entry_graph_seed_nodes(
    session: AsyncSession, entry_id: uuid.UUID
) -> list[tuple[Node, datetime | None]]:
    result = await session.execute(
        select(Node, JournalGraphLink.created_at)
        .join(JournalGraphLink, JournalGraphLink.node_id == Node.id)
        .where(
            JournalGraphLink.journal_entry_id == entry_id,
            JournalGraphLink.node_id.isnot(None),
        )
        .order_by(JournalGraphLink.created_at.desc())
    )
    return [(row[0], row[1]) for row in result.all()]


async def get_edges_for_nodes(
    session: AsyncSession,
    user_id: uuid.UUID,
    node_ids: set[uuid.UUID],
) -> list[Edge]:
    if not node_ids:
        return []
    result = await session.execute(
        select(Edge).where(
            Edge.user_id == user_id,
            or_(Edge.source_id.in_(node_ids), Edge.target_id.in_(node_ids)),
        )
    )
    return list(result.scalars().all())


async def _fallback_seed_nodes(
    session: AsyncSession,
    user_id: uuid.UUID,
    translation_en: str,
) -> list[tuple[Node, datetime | None]]:
    query = translation_en[:200]
    rc = await hybrid_retrieve(session, query, user_id)
    names: list[str] = []
    for line in (rc.context or "").splitlines():
        line = line.strip()
        if line and line not in names:
            names.append(line[:80])
    seeds: list[tuple[Node, datetime | None]] = []
    for name in names[:5]:
        result = await session.execute(
            select(Node)
            .where(Node.user_id == user_id, Node.name.ilike(name[:50]))
            .limit(1)
        )
        node = result.scalar_one_or_none()
        if node is not None:
            seeds.append((node, node.created_at))
    if seeds:
        return seeds
    result = await session.execute(
        select(Node)
        .where(Node.user_id == user_id)
        .order_by(Node.created_at.desc())
        .limit(5)
    )
    return [(n, n.created_at) for n in result.scalars().all()]


async def select_quiz_subgraph(
    session: AsyncSession,
    user_id: uuid.UUID,
    entry_id: uuid.UUID,
    translation_en: str,
) -> QuizGraphSelection:
    settings = get_settings()
    cfg = quiz_selection_settings()
    max_nodes = settings.quiz_max_nodes
    max_edges = settings.quiz_max_edges
    max_hops = settings.quiz_max_hops
    recency_w = settings.quiz_recency_weight

    seed_pairs = await list_entry_graph_seed_nodes(session, entry_id)
    if not seed_pairs:
        seed_pairs = await _fallback_seed_nodes(session, user_id, translation_en)

    seed_ids = {n.id for n, _ in seed_pairs}
    link_ts = {n.id: ts for n, ts in seed_pairs}

    seed_node_dicts = [
        _node_dict(n, link_created_at=link_ts.get(n.id), pick_reason="seed")
        for n, _ in seed_pairs
    ]

    if not seed_ids:
        return QuizGraphSelection(
            settings=cfg,
            seed_nodes=[],
            candidate_count=0,
            selected_nodes=[],
            selected_edges=[],
            pick_breakdown={"recency": 0, "random": 0, "seed": 0},
            context_text="(no graph nodes — journal text only)",
            source_node_ids=[],
        )

    candidate_ids = await crud.get_neighborhood(
        session, user_id, seed_ids, depth=max_hops
    )
    result = await session.execute(select(Node).where(Node.id.in_(candidate_ids)))
    candidates = {n.id: n for n in result.scalars().all()}

    selected_ids: list[uuid.UUID] = []
    id_reason: dict[uuid.UUID, str] = {}
    pick_breakdown = {"recency": 0, "random": 0, "seed": 0}

    for nid in seed_ids:
        if len(selected_ids) >= max_nodes:
            break
        if nid in candidates:
            selected_ids.append(nid)
            id_reason[nid] = "seed"
            pick_breakdown["seed"] += 1

    _pick_non_seed_nodes(
        candidates=candidates,
        seed_ids=seed_ids,
        link_ts=link_ts,
        max_nodes=max_nodes,
        recency_w=recency_w,
        selected_ids=selected_ids,
        id_reason=id_reason,
        pick_breakdown=pick_breakdown,
    )

    selected_set = set(selected_ids)
    selected_node_dicts: list[dict] = []
    for nid in selected_ids:
        node = candidates.get(nid)
        if node is None:
            continue
        selected_node_dicts.append(
            _node_dict(
                node,
                link_created_at=link_ts.get(nid),
                pick_reason=id_reason.get(nid, "random"),
            )
        )

    edges = await get_edges_for_nodes(session, user_id, selected_set)
    name_by_id = {n.id: n.name for n in candidates.values()}
    edge_dicts: list[dict] = []
    for edge in sorted(
        edges,
        key=lambda e: e.created_at or datetime.min.replace(tzinfo=UTC),
        reverse=True,
    )[:max_edges]:
        src = name_by_id.get(edge.source_id, "?")
        tgt = name_by_id.get(edge.target_id, "?")
        edge_dicts.append(_edge_dict(edge, src, tgt))

    context = _format_context(selected_node_dicts, edge_dicts)

    return QuizGraphSelection(
        settings=cfg,
        seed_nodes=seed_node_dicts,
        candidate_count=len(candidates),
        selected_nodes=selected_node_dicts,
        selected_edges=edge_dicts,
        pick_breakdown=pick_breakdown,
        context_text=context,
        source_node_ids=selected_ids,
    )


async def select_quiz_subgraph_from_graph(
    session: AsyncSession,
    user_id: uuid.UUID,
) -> QuizGraphSelection:
    """Graph-only subgraph selection (no journal entry)."""
    cfg = quiz_selection_settings()
    seed_pairs = await _fallback_seed_nodes(session, user_id, "")
    settings = get_settings()
    max_nodes = settings.quiz_max_nodes
    max_edges = settings.quiz_max_edges
    max_hops = settings.quiz_max_hops
    recency_w = settings.quiz_recency_weight

    seed_ids = {n.id for n, _ in seed_pairs}
    link_ts = {n.id: ts for n, ts in seed_pairs}
    seed_node_dicts = [
        _node_dict(n, link_created_at=link_ts.get(n.id), pick_reason="seed")
        for n, _ in seed_pairs
    ]

    if not seed_ids:
        return QuizGraphSelection(
            settings=cfg,
            seed_nodes=[],
            candidate_count=0,
            selected_nodes=[],
            selected_edges=[],
            pick_breakdown={"recency": 0, "random": 0, "seed": 0},
            context_text="(no graph nodes — add content via GraphRAG first)",
            source_node_ids=[],
        )

    candidate_ids = await crud.get_neighborhood(session, user_id, seed_ids, depth=max_hops)
    result = await session.execute(select(Node).where(Node.id.in_(candidate_ids)))
    candidates = {n.id: n for n in result.scalars().all()}

    selected_ids: list[uuid.UUID] = []
    id_reason: dict[uuid.UUID, str] = {}
    pick_breakdown = {"recency": 0, "random": 0, "seed": 0}

    for nid in seed_ids:
        if len(selected_ids) >= max_nodes:
            break
        if nid in candidates:
            selected_ids.append(nid)
            id_reason[nid] = "seed"
            pick_breakdown["seed"] += 1

    _pick_non_seed_nodes(
        candidates=candidates,
        seed_ids=seed_ids,
        link_ts=link_ts,
        max_nodes=max_nodes,
        recency_w=recency_w,
        selected_ids=selected_ids,
        id_reason=id_reason,
        pick_breakdown=pick_breakdown,
    )

    selected_set = set(selected_ids)
    selected_node_dicts = [
        _node_dict(
            candidates[nid],
            link_created_at=link_ts.get(nid),
            pick_reason=id_reason.get(nid, "random"),
        )
        for nid in selected_ids
        if nid in candidates
    ]

    edges = await get_edges_for_nodes(session, user_id, selected_set)
    name_by_id = {n.id: n.name for n in candidates.values()}
    edge_dicts = [
        _edge_dict(
            edge,
            name_by_id.get(edge.source_id, "?"),
            name_by_id.get(edge.target_id, "?"),
        )
        for edge in sorted(
            edges,
            key=lambda e: e.created_at or datetime.min.replace(tzinfo=UTC),
            reverse=True,
        )[:max_edges]
    ]
    context = _format_context(selected_node_dicts, edge_dicts)
    return QuizGraphSelection(
        settings=cfg,
        seed_nodes=seed_node_dicts,
        candidate_count=len(candidates),
        selected_nodes=selected_node_dicts,
        selected_edges=edge_dicts,
        pick_breakdown=pick_breakdown,
        context_text=context,
        source_node_ids=selected_ids,
    )
