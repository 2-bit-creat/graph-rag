import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..db import get_session
from ..schemas import EdgeCreate, EdgeOut, GraphOut

router = APIRouter(prefix="/graph", tags=["graph"])


@router.get("", response_model=GraphOut)
async def read_graph(session: AsyncSession = Depends(get_session)) -> GraphOut:
    nodes = await crud.get_all_nodes(session)
    edges = await crud.get_all_edges(session)
    return GraphOut(nodes=nodes, edges=edges)


@router.post("/edges", response_model=EdgeOut, status_code=status.HTTP_201_CREATED)
async def add_edge(
    payload: EdgeCreate, session: AsyncSession = Depends(get_session)
) -> EdgeOut:
    edge = await crud.create_edge(
        session, payload.source_id, payload.target_id, payload.relation
    )
    if edge is None:
        raise HTTPException(status_code=404, detail="source or target node not found")
    return edge


@router.delete("/nodes/{node_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_node(
    node_id: uuid.UUID, session: AsyncSession = Depends(get_session)
) -> None:
    deleted = await crud.delete_node(session, node_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="node not found")
