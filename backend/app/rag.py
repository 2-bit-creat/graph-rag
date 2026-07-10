"""Graph RAG: graph retrieval for journal and quiz context."""

import uuid
from dataclasses import dataclass, field
from functools import lru_cache

from openai import AsyncOpenAI
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .crud import (
    find_identities_by_alias_embedding,
    find_similar_nodes_with_distance,
    get_neighborhood,
)
from .models import Edge, Node


@lru_cache
def _get_client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


@dataclass
class RetrievedContext:
    context: str
    seed_node_ids: list[uuid.UUID] = field(default_factory=list)
    node_ids: list[uuid.UUID] = field(default_factory=list)
    # Best seed similarity (1 - min cosine distance), 0.0 when nothing matched.
    graph_score: float = 0.0


async def embed_text(text: str) -> list[float]:
    results = await embed_texts([text])
    return results[0]


async def embed_texts(texts: list[str]) -> list[list[float]]:
    if not texts:
        return []
    client = _get_client()
    resp = await client.embeddings.create(
        model="text-embedding-3-small",
        input=texts,
    )
    by_index = {item.index: item.embedding for item in resp.data}
    return [by_index[i] for i in range(len(texts))]


def _node_embed_text(node: Node) -> str:
    """Text used to embed a node. Statement descriptions are JSON with the
    actual diary sentence under 'content' — embed that, not the raw JSON."""
    import json as _json

    desc = (node.description or "").strip()
    if desc and node.type == "Statement":
        try:
            desc = (_json.loads(desc).get("content") or "").strip()
        except (ValueError, AttributeError):
            parts = desc.split("\n", 1)
            desc = parts[1].strip() if len(parts) > 1 else parts[0].strip()
    return f"{node.name}\n{desc}".strip() if desc else node.name


def _node_fact_line(node: Node) -> str:
    """Human-readable fact for the graph context: a Statement's actual sentence,
    or an identity/concept's ``name — description``. The triple view only carries
    node NAMES (short labels), so this is what lets the model answer 'who/what'."""
    import json as _json

    desc = (node.description or "").strip()
    if node.type == "Statement":
        if desc:
            try:
                content = (_json.loads(desc).get("content") or "").strip()
                if content:
                    return content
            except (ValueError, AttributeError):
                parts = desc.split("\n", 1)
                return (parts[1] if len(parts) > 1 else parts[0]).strip() or node.name
        return node.name
    return f"{node.name} — {desc}" if desc else node.name


async def ensure_statement_embeddings(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    batch_size: int = 100,
) -> int:
    """Backfill Node.name_embedding for Statement/Concept nodes missing one.

    Cheap no-op once everything is embedded; called lazily before graph-chat
    retrieval and best-effort after kg_commit. Returns number embedded.
    """
    result = await session.execute(
        select(Node).where(
            Node.user_id == user_id,
            Node.deleted_at.is_(None),
            Node.type.in_(("Statement", "Concept")),
            Node.name_embedding.is_(None),
        )
    )
    nodes = list(result.scalars().all())
    if not nodes:
        return 0

    done = 0
    for i in range(0, len(nodes), batch_size):
        batch = nodes[i : i + batch_size]
        vectors = await embed_texts([_node_embed_text(n) for n in batch])
        for node, vec in zip(batch, vectors):
            node.name_embedding = vec
        await session.flush()
        done += len(batch)
    await session.commit()
    return done


async def retrieve_graph_context(
    session: AsyncSession,
    query: str,
    user_id: uuid.UUID | None = None,
    query_vec: list[float] | None = None,
) -> RetrievedContext:
    """Seed from two text-embedding indexes (Statement/Concept name_embedding +
    identity alias embeddings), expand, and render both the actual sentences and
    the relationship triples. ``query_vec`` may be passed in to avoid re-embedding
    the same query."""
    settings = get_settings()
    tokens = [t for t in query.replace("?", " ").split() if len(t) > 2]

    seed_ids: set[uuid.UUID] = set()
    best_dist = 1.0  # min cosine distance across seeds → graph relevance score
    if user_id is not None and query.strip():
        try:
            if query_vec is None:
                query_vec = await embed_text(query)
            scored = await find_similar_nodes_with_distance(
                session,
                user_id,
                query_vec,
                limit=settings.graph_retrieve_seed_limit,
                max_distance=settings.graph_retrieve_max_distance,
            )
            # Identities (사람·기업/출처·반려동물) carry no name_embedding — seed them
            # from the alias index so "마야가 누구야?" finds the 마야 node itself.
            scored += [
                (node, dist)
                for node, _text, dist in await find_identities_by_alias_embedding(
                    session,
                    user_id,
                    query_vec,
                    limit=settings.graph_retrieve_identity_seed_limit,
                    max_distance=settings.graph_retrieve_identity_max_distance,
                )
            ]
            for node, dist in scored:
                seed_ids.add(node.id)
                best_dist = min(best_dist, dist)
        except Exception:
            await session.rollback()

    if not seed_ids and tokens:
        filters = [Node.name.ilike(f"%{tok}%") for tok in tokens]
        q = select(Node).where(or_(*filters))
        if user_id is not None:
            q = q.where(Node.user_id == user_id)
        seeds = await session.execute(q.limit(10))
        seed_ids = {n.id for n in seeds.scalars().all()}

    graph_score = max(0.0, 1.0 - best_dist) if seed_ids else 0.0

    edge_query = select(Edge)
    if user_id is not None:
        edge_query = edge_query.where(Edge.user_id == user_id)
    if seed_ids:
        edge_query = edge_query.where(
            or_(Edge.source_id.in_(seed_ids), Edge.target_id.in_(seed_ids))
        )
    # Strongest (most-reinforced) relations first, so the cap keeps signal not noise.
    edges = list(
        (
            await session.execute(edge_query.order_by(Edge.weight.desc()).limit(50))
        ).scalars().all()
    )

    node_ids = {e.source_id for e in edges} | {e.target_id for e in edges} | seed_ids

    if user_id and seed_ids:
        node_ids |= await get_neighborhood(session, user_id, seed_ids, depth=2)

    if not node_ids:
        return RetrievedContext(context="", seed_node_ids=list(seed_ids), graph_score=graph_score)

    nodes = (
        await session.execute(select(Node).where(Node.id.in_(node_ids)))
    ).scalars().all()
    name_by_id = {n.id: n.name for n in nodes}
    node_by_id = {n.id: n for n in nodes}

    if user_id and seed_ids:
        all_edges = await session.execute(
            select(Edge).where(
                Edge.user_id == user_id,
                or_(Edge.source_id.in_(node_ids), Edge.target_id.in_(node_ids)),
            ).order_by(Edge.weight.desc()).limit(80)
        )
        edges = list(all_edges.scalars().all())

    # Sentences that answer 'who/what/what happened': seed nodes plus the Statement
    # nodes reachable from them — the triple view alone only exposes short labels.
    fact_ids: list[uuid.UUID] = [sid for sid in seed_ids if sid in node_by_id]
    for e in edges:
        for anchor, other in ((e.source_id, e.target_id), (e.target_id, e.source_id)):
            if anchor in seed_ids and other in node_by_id:
                nb = node_by_id[other]
                if nb.type == "Statement" and other not in fact_ids:
                    fact_ids.append(other)
    fact_lines: list[str] = []
    seen_facts: set[str] = set()
    for nid in fact_ids[:15]:
        line = _node_fact_line(node_by_id[nid]).strip()
        if line and line not in seen_facts:
            seen_facts.add(line)
            fact_lines.append(f"- {line}")

    triple_lines = [
        f"({name_by_id.get(e.source_id, '?')}) -[{e.relation}]-> ({name_by_id.get(e.target_id, '?')})"
        for e in edges
        if e.source_id in name_by_id and e.target_id in name_by_id
    ]

    parts: list[str] = []
    if fact_lines:
        parts.append("Relevant statements:\n" + "\n".join(fact_lines))
    if triple_lines:
        parts.append("Relationships:\n" + "\n".join(triple_lines))
    return RetrievedContext(
        context="\n\n".join(parts),
        seed_node_ids=list(seed_ids),
        node_ids=list(node_ids),
        graph_score=graph_score,
    )


async def hybrid_retrieve(
    session: AsyncSession,
    query: str,
    user_id: uuid.UUID,
) -> RetrievedContext:
    """Thin wrapper kept for journal/quiz callers — graph context only."""
    query_vec: list[float] | None = None
    if query.strip():
        try:
            query_vec = await embed_text(query)
        except Exception:
            await session.rollback()

    return await retrieve_graph_context(
        session, query, user_id=user_id, query_vec=query_vec
    )
