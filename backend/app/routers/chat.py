from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..db import get_session
from ..graph_extractor import extract_triples
from ..rag import answer_with_graph
from ..schemas import ChatRequest, ChatResponse, GraphOut

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("", response_model=ChatResponse)
async def chat(
    payload: ChatRequest, session: AsyncSession = Depends(get_session)
) -> ChatResponse:
    triples = await extract_triples(payload.message)
    await crud.persist_triples(session, triples)

    answer = await answer_with_graph(session, payload.message)

    nodes = await crud.get_all_nodes(session)
    edges = await crud.get_all_edges(session)

    return ChatResponse(
        answer=answer,
        extracted_triples=[(t.source, t.relation, t.target) for t in triples],
        graph=GraphOut(nodes=nodes, edges=edges),
    )
