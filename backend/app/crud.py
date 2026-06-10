import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .graph_extractor import Triple
from .models import Edge, Node


async def _get_or_create_node(session: AsyncSession, name: str, type_: str) -> Node:
    name = name.strip()
    type_ = (type_ or "entity").strip().lower()

    result = await session.execute(
        select(Node).where(Node.name == name, Node.type == type_)
    )
    node = result.scalar_one_or_none()
    if node is None:
        node = Node(name=name, type=type_)
        session.add(node)
        await session.flush()
    return node


async def persist_triples(session: AsyncSession, triples: list[Triple]) -> None:
    """Upsert nodes/edges from extracted triples (deduped)."""
    for t in triples:
        if not t.source or not t.target:
            continue
        source = await _get_or_create_node(session, t.source, t.source_type)
        target = await _get_or_create_node(session, t.target, t.target_type)

        exists = await session.execute(
            select(Edge).where(
                Edge.source_id == source.id,
                Edge.target_id == target.id,
                Edge.relation == t.relation,
            )
        )
        if exists.scalar_one_or_none() is None:
            session.add(
                Edge(
                    source_id=source.id,
                    target_id=target.id,
                    relation=t.relation,
                )
            )
    await session.commit()


async def get_all_nodes(session: AsyncSession) -> list[Node]:
    result = await session.execute(select(Node).order_by(Node.created_at))
    return list(result.scalars().all())


async def get_all_edges(session: AsyncSession) -> list[Edge]:
    result = await session.execute(select(Edge).order_by(Edge.created_at))
    return list(result.scalars().all())


async def delete_node(session: AsyncSession, node_id: uuid.UUID) -> bool:
    node = await session.get(Node, node_id)
    if node is None:
        return False
    await session.delete(node)
    await session.commit()
    return True


async def create_edge(
    session: AsyncSession,
    source_id: uuid.UUID,
    target_id: uuid.UUID,
    relation: str,
) -> Edge | None:
    source = await session.get(Node, source_id)
    target = await session.get(Node, target_id)
    if source is None or target is None:
        return None

    existing = await session.execute(
        select(Edge).where(
            Edge.source_id == source_id,
            Edge.target_id == target_id,
            Edge.relation == relation,
        )
    )
    edge = existing.scalar_one_or_none()
    if edge is not None:
        return edge

    edge = Edge(source_id=source_id, target_id=target_id, relation=relation)
    session.add(edge)
    await session.commit()
    await session.refresh(edge)
    return edge
