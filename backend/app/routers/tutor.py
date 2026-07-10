"""Composition tutor API."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from ..deps import request_user_dep
from ..models import User
from ..schemas import (
    TutorChatRequest,
    TutorVocabBatchRequest,
    TutorVocabSaveRequest,
)
from ..tutor import tutor_chat
from ..user_vocab_store import (
    delete_tutor_expression,
    list_tutor_expressions,
    list_tutor_history,
    save_tutor_expression,
)

router = APIRouter(prefix="/tutor", tags=["tutor"])


@router.get("/history")
async def get_history(
    limit: int = 20,
    user: User = Depends(request_user_dep),
) -> dict:
    items = await list_tutor_history(user.id, limit=limit)
    return {"items": items, "total": len(items)}


@router.post("/chat")
async def chat(
    payload: TutorChatRequest,
    user: User = Depends(request_user_dep),
) -> dict:
    answer = await tutor_chat(
        user,
        messages=[m.model_dump() for m in payload.messages],
        language=payload.language,
        drill_prompt=payload.drill_prompt,
    )
    return {"answer": answer}


@router.get("/vocab")
async def get_vocab(
    language: str | None = None,
    user: User = Depends(request_user_dep),
) -> dict:
    items = await list_tutor_expressions(user.id, language=language)
    return {"items": items, "total": len(items)}


@router.post("/vocab")
async def save_vocab(
    payload: TutorVocabSaveRequest,
    user: User = Depends(request_user_dep),
) -> dict:
    entry = await save_tutor_expression(
        user.id,
        expression=payload.expression,
        meaning=payload.meaning,
        example=payload.example,
        language=payload.language,
        note=payload.note,
        prompt_ko=payload.prompt_ko,
        user_attempt=payload.user_attempt,
    )
    return {"ok": True, "entry": entry}


@router.post("/vocab/batch")
async def save_vocab_batch(
    payload: TutorVocabBatchRequest,
    user: User = Depends(request_user_dep),
) -> dict:
    saved = 0
    for item in payload.items:
        if not item.expression.strip():
            continue
        await save_tutor_expression(
            user.id,
            expression=item.expression,
            meaning=item.meaning,
            example=item.example,
            language=item.language,
            note=item.note,
            prompt_ko=item.prompt_ko,
            user_attempt=item.user_attempt,
        )
        saved += 1
    return {"ok": True, "saved": saved}


@router.delete("/vocab")
async def delete_vocab(
    expression: str,
    language: str = "english",
    user: User = Depends(request_user_dep),
) -> dict:
    removed = await delete_tutor_expression(user.id, expression, language)
    return {"ok": removed}
