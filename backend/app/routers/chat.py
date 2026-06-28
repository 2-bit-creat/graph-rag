from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..rag import answer_with_graph
from ..schemas import ChatRequest, ChatResponse

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("", response_model=ChatResponse)
async def chat(
    payload: ChatRequest, session: AsyncSession = Depends(get_session)
) -> ChatResponse:
    """Pure conversation. Does NOT modify the graph; it can reference it for context."""
    if not payload.messages:
        raise HTTPException(status_code=400, detail="messages must not be empty")

    last_user = next(
        (m for m in reversed(payload.messages) if m.role == "user"), None
    )
    if last_user is None:
        raise HTTPException(status_code=400, detail="no user message found")

    history = [m.model_dump() for m in payload.messages[:-1]]
    answer = await answer_with_graph(session, last_user.content, history=history)
    return ChatResponse(answer=answer)
