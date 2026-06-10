"""Graph RAG: retrieve a relevant subgraph and answer with gpt-4o-mini."""

from functools import lru_cache

from openai import AsyncOpenAI
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import Edge, Node


@lru_cache
def _get_client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


async def _retrieve_context(session: AsyncSession, query: str) -> str:
    """Find nodes mentioned in the query and serialize their neighborhood."""
    tokens = [t for t in query.replace("?", " ").split() if len(t) > 2]

    seed_ids: set = set()
    if tokens:
        filters = [Node.name.ilike(f"%{tok}%") for tok in tokens]
        seeds = await session.execute(select(Node).where(or_(*filters)))
        seed_ids = {n.id for n in seeds.scalars().all()}

    edge_query = select(Edge)
    if seed_ids:
        edge_query = edge_query.where(
            or_(Edge.source_id.in_(seed_ids), Edge.target_id.in_(seed_ids))
        )
    edges = list((await session.execute(edge_query.limit(50))).scalars().all())

    if not edges:
        return ""

    node_ids = {e.source_id for e in edges} | {e.target_id for e in edges}
    nodes = (
        await session.execute(select(Node).where(Node.id.in_(node_ids)))
    ).scalars().all()
    name_by_id = {n.id: n.name for n in nodes}

    lines = [
        f"({name_by_id.get(e.source_id, '?')}) -[{e.relation}]-> ({name_by_id.get(e.target_id, '?')})"
        for e in edges
    ]
    return "\n".join(lines)


async def answer_with_graph(session: AsyncSession, query: str) -> str:
    context = await _retrieve_context(session, query)
    settings = get_settings()

    system = (
        "You are a personal knowledge assistant. Answer the user's question using "
        "the knowledge graph facts provided. If the facts are insufficient, say so "
        "briefly and answer from general knowledge. Be concise."
    )
    user = (
        f"Knowledge graph facts:\n{context or '(no relevant facts yet)'}\n\n"
        f"Question: {query}"
    )

    resp = await _get_client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        temperature=0.2,
    )
    return resp.choices[0].message.content or ""
