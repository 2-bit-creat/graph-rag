"""Chat → journal distillation endpoints (mounted under /graph/chat).

  POST  /graph/chat/sessions/{id}/distill/draft   → extract a diary draft
  POST  /graph/chat/sessions/{id}/distill/refine  → rewrite it conversationally
  PATCH /graph/chat/sessions/{id}/distill         → persist include-toggles only

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
        raise HTTPException(status_code=404, detail="대화방을 찾을 수 없어요.")
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
        return "대화에서 새로 정리할 내용을 찾지 못했어요."
    base = f"대화에서 {total}개의 일기 문장을 정리했어요."
    return base + (
        f" 그중 {dups}개는 이미 기록한 내용과 겹쳐 보여 표시해 뒀어요." if dups else ""
    )


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
            status_code=502, detail="초안 생성에 실패했어요. 잠시 후 다시 시도해 주세요."
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
        raise HTTPException(status_code=409, detail="수정할 초안이 아직 없어요.")
    await crud.append_chat_messages(
        session, row, [{"role": "user", "content": payload.instruction.strip()}]
    )
    try:
        draft = await refine_distill_draft(session, user, row, payload.instruction.strip())
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail="초안 수정에 실패했어요. 잠시 후 다시 시도해 주세요."
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
        raise HTTPException(status_code=409, detail="저장할 초안이 없어요.")
    sentences = state.get("sentences", [])
    for i, included in enumerate(payload.included):
        if i < len(sentences):
            sentences[i]["included"] = bool(included)
    await crud.set_chat_session_distill_state(
        session, row, {**state, "sentences": sentences}
    )
    await session.commit()
    return _draft_out(row.distill_state)
