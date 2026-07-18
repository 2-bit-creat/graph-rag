"""Graph RAG: graph retrieval for journal and quiz context.

Seed discovery (embedding + identity-alias search) lives here; the shared
:mod:`graph_retrieval` module owns everything downstream of a seed list — 1-hop
type-aware expansion into Context Packages, RRF rerank, and prompt rendering.
"""

import uuid
from dataclasses import dataclass, field
from functools import lru_cache

from openai import AsyncOpenAI
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .crud import find_identities_by_alias_embedding, find_similar_nodes_with_distance
from .graph_retrieval import build_ranked_context
from .models import Node


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
    identity alias embeddings), falling back to a plain name search when neither
    hits, then hand off to :mod:`graph_retrieval`'s shared Context Package
    builder + RRF rerank for the 1-hop expansion and final prompt text.
    ``query_vec`` may be passed in to avoid re-embedding the same query."""
    settings = get_settings()
    tokens = [t for t in query.replace("?", " ").split() if len(t) > 2]

    seeds_by_id: dict[uuid.UUID, Node] = {}
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
                seeds_by_id[node.id] = node
                best_dist = min(best_dist, dist)
        except Exception:
            await session.rollback()

    if not seeds_by_id and tokens and user_id is not None:
        filters = [Node.name.ilike(f"%{tok}%") for tok in tokens]
        q = select(Node).where(Node.user_id == user_id, or_(*filters)).limit(10)
        found = await session.execute(q)
        for node in found.scalars().all():
            seeds_by_id[node.id] = node

    graph_score = max(0.0, 1.0 - best_dist) if seeds_by_id else 0.0

    if not seeds_by_id or user_id is None:
        return RetrievedContext(
            context="", seed_node_ids=list(seeds_by_id), graph_score=graph_score
        )

    ranked = await build_ranked_context(
        session, user_id, list(seeds_by_id.values()), query_vec=query_vec
    )
    return RetrievedContext(
        context=ranked.text,
        seed_node_ids=list(seeds_by_id),
        node_ids=ranked.node_ids,
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
