"""Graph RAG: hybrid vector + graph retrieval."""

import uuid
from dataclasses import dataclass, field
from functools import lru_cache

from openai import AsyncOpenAI
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .crud import find_similar_nodes_by_embedding, get_neighborhood
from .models import Chunk, Edge, Node


@lru_cache
def _get_client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


@dataclass
class RetrievedContext:
    context: str
    seed_node_ids: list[uuid.UUID] = field(default_factory=list)
    node_ids: list[uuid.UUID] = field(default_factory=list)
    chunk_texts: list[str] = field(default_factory=list)


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


async def _vector_search(
    session: AsyncSession,
    user_id: uuid.UUID,
    query: str,
    limit: int = 10,
) -> list[tuple[str, float]]:
    count = await session.scalar(
        select(func.count()).select_from(Chunk).where(Chunk.user_id == user_id)
    )
    if not count:
        return []

    try:
        embedding = await embed_text(query)
        result = await session.execute(
            select(
                Chunk.text,
                Chunk.embedding.cosine_distance(embedding).label("dist"),
            )
            .where(Chunk.user_id == user_id, Chunk.embedding.isnot(None))
            .order_by("dist")
            .limit(limit)
        )
        hits: list[tuple[str, float]] = []
        for row in result.all():
            dist = float(row.dist) if row.dist is not None else 1.0
            hits.append((row.text, max(0.0, 1.0 - dist)))
        return hits
    except Exception:
        await session.rollback()
        result = await session.execute(
            select(Chunk.text)
            .where(Chunk.user_id == user_id)
            .order_by(Chunk.created_at.desc())
            .limit(limit)
        )
        return [(t, 0.5) for t in result.scalars().all()]


async def retrieve_graph_context(
    session: AsyncSession,
    query: str,
    user_id: uuid.UUID | None = None,
) -> RetrievedContext:
    tokens = [t for t in query.replace("?", " ").split() if len(t) > 2]

    seed_ids: set[uuid.UUID] = set()
    if user_id is not None and query.strip():
        try:
            query_vec = await embed_text(query)
            similar = await find_similar_nodes_by_embedding(
                session, user_id, query_vec, limit=5, max_distance=0.35
            )
            seed_ids = {n.id for n in similar}
        except Exception:
            await session.rollback()

    if not seed_ids and tokens:
        filters = [Node.name.ilike(f"%{tok}%") for tok in tokens]
        q = select(Node).where(or_(*filters))
        if user_id is not None:
            q = q.where(Node.user_id == user_id)
        seeds = await session.execute(q.limit(10))
        seed_ids = {n.id for n in seeds.scalars().all()}

    edge_query = select(Edge)
    if user_id is not None:
        edge_query = edge_query.where(Edge.user_id == user_id)
    if seed_ids:
        edge_query = edge_query.where(
            or_(Edge.source_id.in_(seed_ids), Edge.target_id.in_(seed_ids))
        )
    edges = list((await session.execute(edge_query.limit(50))).scalars().all())

    node_ids = {e.source_id for e in edges} | {e.target_id for e in edges} | seed_ids

    if user_id and seed_ids:
        node_ids |= await get_neighborhood(session, user_id, seed_ids, depth=2)

    if not node_ids:
        return RetrievedContext(context="", seed_node_ids=list(seed_ids))

    nodes = (
        await session.execute(select(Node).where(Node.id.in_(node_ids)))
    ).scalars().all()
    name_by_id = {n.id: n.name for n in nodes}

    edge_ids = {e.source_id for e in edges} | {e.target_id for e in edges}
    if user_id and seed_ids:
        all_edges = await session.execute(
            select(Edge).where(
                Edge.user_id == user_id,
                or_(Edge.source_id.in_(node_ids), Edge.target_id.in_(node_ids)),
            ).limit(80)
        )
        edges = list(all_edges.scalars().all())

    lines = [
        f"({name_by_id.get(e.source_id, '?')}) -[{e.relation}]-> ({name_by_id.get(e.target_id, '?')})"
        for e in edges
        if e.source_id in name_by_id and e.target_id in name_by_id
    ]
    return RetrievedContext(
        context="\n".join(lines),
        seed_node_ids=list(seed_ids),
        node_ids=list(node_ids),
    )


async def hybrid_retrieve(
    session: AsyncSession,
    query: str,
    user_id: uuid.UUID,
) -> RetrievedContext:
    settings = get_settings()
    w = settings.hybrid_weight

    graph_rc = await retrieve_graph_context(session, query, user_id=user_id)
    vector_hits = await _vector_search(session, user_id, query, limit=8)

    graph_score = 1.0 if graph_rc.context else 0.0
    combined_chunks: list[str] = []
    for chunk_text, vec_score in vector_hits:
        combined_score = w * vec_score + (1 - w) * graph_score
        if combined_score > 0.1:
            combined_chunks.append(chunk_text)

    context_parts = []
    if combined_chunks:
        context_parts.append("Recent journal excerpts:\n" + "\n---\n".join(combined_chunks))
    if graph_rc.context:
        context_parts.append("Knowledge graph facts:\n" + graph_rc.context)

    return RetrievedContext(
        context="\n\n".join(context_parts),
        seed_node_ids=graph_rc.seed_node_ids,
        node_ids=graph_rc.node_ids,
        chunk_texts=combined_chunks,
    )


async def answer_with_graph(
    session: AsyncSession,
    query: str,
    history: list[dict] | None = None,
    user_id: uuid.UUID | None = None,
) -> str:
    if user_id:
        rc = await hybrid_retrieve(session, query, user_id)
        context = rc.context
    else:
        context = (await retrieve_graph_context(session, query)).context

    settings = get_settings()
    system = (
        "You are a friendly tutor helping the user learn English from their daily life. "
        "Answer conversationally. Use personal graph facts and journal context when relevant."
    )
    facts = f"Personal context:\n{context or '(none yet)'}"

    messages: list[dict] = [{"role": "system", "content": system}, {"role": "system", "content": facts}]
    for m in history or []:
        role = m.get("role")
        content = m.get("content", "")
        if role in ("user", "assistant") and content:
            messages.append({"role": role, "content": content})
    messages.append({"role": "user", "content": query})

    resp = await _get_client().chat.completions.create(
        model=settings.openai_model,
        messages=messages,
        temperature=0.3,
    )
    return resp.choices[0].message.content or ""
