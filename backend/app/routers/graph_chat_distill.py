"""Chat ? journal distillation endpoints (mounted under /graph/chat).

  POST  /graph/chat/sessions/{id}/distill/draft   ? extract a diary draft
  POST  /graph/chat/sessions/{id}/distill/refine  ? rewrite it conversationally
  PATCH /graph/chat/sessions/{id}/distill         ? persist include-toggles only

The final hand-off (committing the draft) reuses the existing journal pipeline:
the client posts the included sentences to POST /journal/entries. No new commit
path here.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..chat_distill import build_distill_draft, refine_distill_draft
from ..db import get_session
from ..deps import request_user_dep
from ..models import ChatSession, User
from ..schemas import (
    DistillDraftOut,
    DistillRefineRequest,
    DistillSentenceOut,
    DistillStateUpdateRequest,
)

router = APIRouter(prefix="/graph/chat", tags=["graph-chat"])


async def _require_session(
    session: AsyncSession, user: User, session_id: uuid.UUID
) -> ChatSession:
    row = await crud.get_chat_session(session, user.id, session_id)
    if row is None:
        raise HTTPException(status_code=404, detail="???? ?? ? ???.")
    return row


def _draft_out(draft: dict, message_id: str | None = None) -> DistillDraftOut:
    return DistillDraftOut(
        draft_id=draft.get("draft_id", ""),
        sentences=[DistillSentenceOut(**s) for s in draft.get("sentences", [])],
        message_id=message_id,
    )


def _summary(draft: dict) -> str:
    total = len(draft.get("sentences", []))
    dups = sum(1 for s in draft["sentences"] if s.get("duplicate"))
    if total == 0:
        return "???? ?? ??? ??? ?? ????."
    base = f"???? {total}?? ?? ??? ?????."
    return base + (f" ?? {dups}?? ?? ???? ?? ?? ?????." if dups else "")


async def _append_draft_message(
    session: AsyncSession, row: ChatSession, draft: dict
) -> str:
    appended = await crud.append_chat_messages(
        session,
        row,
        [
            {
                "role": "assistant",
                "kind": "distill_draft",
                "content": _summary(draft),
                "meta": draft,
            }
        ],
    )
    return str(appended[0].id)


@router.post("/sessions/{session_id}/distill/draft", response_model=DistillDraftOut)
async def distill_draft(
    session_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> DistillDraftOut:
    row = await _require_session(session, user, session_id)
    try:
        draft = await build_distill_draft(session, user, row)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail="?? ??? ?????. ?? ? ?? ??? ???."
        ) from exc
    message_id = await _append_draft_message(session, row, draft)
    await session.commit()
    return _draft_out(draft, message_id)


@router.post("/sessions/{session_id}/distill/refine", response_model=DistillDraftOut)
async def distill_refine(
    session_id: uuid.UUID,
    payload: DistillRefineRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> DistillDraftOut:
    row = await _require_session(session, user, session_id)
    if not row.distill_state:
        raise HTTPException(status_code=409, detail="?? ??? ??? ???.")
    await crud.append_chat_messages(
        session, row, [{"role": "user", "content": payload.instruction.strip()}]
    )
    try:
        draft = await refine_distill_draft(session, user, row, payload.instruction.strip())
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail="?? ??? ?????. ?? ? ?? ??? ???."
        ) from exc
    message_id = await _append_draft_message(session, row, draft)
    await session.commit()
    return _draft_out(draft, message_id)


@router.patch("/sessions/{session_id}/distill", response_model=DistillDraftOut)
async def update_distill_state(
    session_id: uuid.UUID,
    payload: DistillStateUpdateRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> DistillDraftOut:
    """Persist the user's per-sentence include toggles without re-running the LLM."""
    row = await _require_session(session, user, session_id)
    state = row.distill_state
    if not state:
        raise HTTPException(status_code=409, detail="??? ???.")
    sentences = state.get("sentences", [])
    for i, included in enumerate(payload.included):
        if i < len(sentences):
            sentences[i]["included"] = bool(included)
    await crud.set_chat_session_distill_state(
        session, row, {**state, "sentences": sentences}
    )
    await session.commit()
    return _draft_out(row.distill_state)
