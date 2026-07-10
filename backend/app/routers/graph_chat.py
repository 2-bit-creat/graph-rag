"""Graph-chat API — Claude-style multi-room conversation grounded in the KG.

Sessions (chat rooms):
  GET    /graph/chat/sessions                      → list rooms (sidebar)
  POST   /graph/chat/sessions                      → new room
  PATCH  /graph/chat/sessions/{id}                 → rename
  DELETE /graph/chat/sessions/{id}                 → delete room + messages
  GET    /graph/chat/sessions/{id}/messages        → history, oldest-first
  POST   /graph/chat/sessions/{id}/messages        → send (RAG answer)
  POST   /graph/chat/sessions/{id}/events          → append a non-LLM record
                                                     (inline quiz cards, etc.)

Distillation (chat → journal) lives in graph_chat_distill.py, mounted below.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..chat_summary import needs_summary_update, update_session_summary, watermark_from_state
from ..db import get_session
from ..dev_user import dev_user_dep
from ..graph_chat import graph_chat_answer
from ..models import ChatMessage, ChatSession, User
from ..schemas import (
    ChatEventRequest,
    ChatSessionCreateRequest,
    ChatSessionListOut,
    ChatSessionOut,
    ChatSessionRenameRequest,
    GraphChatHistoryOut,
    GraphChatMessageOut,
    GraphChatRequest,
    GraphChatResponse,
)

router = APIRouter(prefix="/graph/chat", tags=["graph-chat"])


def _iso(dt) -> str | None:
    return dt.isoformat() if dt else None


def _message_out(m: ChatMessage) -> GraphChatMessageOut:
    return GraphChatMessageOut(
        id=str(m.id),
        role=m.role,
        kind=m.kind,
        content=m.content,
        referenced_node_ids=list(m.referenced_node_ids or []),
        meta=m.meta,
        created_at=_iso(m.created_at),
    )


async def _session_out(session: AsyncSession, row: ChatSession) -> ChatSessionOut:
    preview = await crud.last_message_preview(session, row.id, user_id=row.user_id)
    return ChatSessionOut(
        id=str(row.id),
        title=row.title,
        preview=(preview or "").strip()[:80] or None,
        created_at=_iso(row.created_at),
        updated_at=_iso(row.updated_at),
    )


async def _require_session(
    session: AsyncSession, user: User, session_id: uuid.UUID
) -> ChatSession:
    row = await crud.get_chat_session(session, user.id, session_id)
    if row is None:
        raise HTTPException(status_code=404, detail="채팅방을 찾을 수 없어요.")
    return row


async def _migrate_legacy_json(session: AsyncSession, user: User) -> None:
    """One-time import of the pre-sessions JSON chat log into a single room.

    Runs only when the user has zero sessions, then renames the file so it never
    re-imports. Best-effort — a failure here must not block the sidebar.
    """
    import json
    from pathlib import Path

    from ..config import get_settings

    path = Path(get_settings().upload_dir) / str(user.id) / "graph_chat_history.json"
    if not path.is_file():
        return
    try:
        items = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        items = []
    if isinstance(items, list) and items:
        row = await crud.create_chat_session(session, user.id, title="이전 대화")
        await crud.append_chat_messages(
            session,
            row,
            [
                {
                    "role": m.get("role", "assistant"),
                    "content": m.get("content", ""),
                    "referenced_node_ids": m.get("referenced_node_ids") or [],
                }
                for m in items
                if m.get("role") in ("user", "assistant")
            ],
        )
    try:
        path.rename(path.with_suffix(path.suffix + ".migrated"))
    except OSError:
        pass


# --- Sessions ----------------------------------------------------------------


@router.get("/sessions", response_model=ChatSessionListOut)
async def list_sessions(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> ChatSessionListOut:
    rows = await crud.list_chat_sessions(session, user.id)
    if not rows:
        await _migrate_legacy_json(session, user)
        await session.commit()
        rows = await crud.list_chat_sessions(session, user.id)
    return ChatSessionListOut(
        items=[await _session_out(session, r) for r in rows]
    )


@router.post("/sessions", response_model=ChatSessionOut)
async def create_session(
    payload: ChatSessionCreateRequest,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> ChatSessionOut:
    row = await crud.create_chat_session(session, user.id, title=payload.title)
    await session.commit()
    return await _session_out(session, row)


@router.patch("/sessions/{session_id}", response_model=ChatSessionOut)
async def rename_session(
    session_id: uuid.UUID,
    payload: ChatSessionRenameRequest,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> ChatSessionOut:
    row = await _require_session(session, user, session_id)
    await crud.rename_chat_session(session, row, payload.title)
    await session.commit()
    return await _session_out(session, row)


@router.delete("/sessions/{session_id}")
async def delete_session(
    session_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    row = await _require_session(session, user, session_id)
    await crud.delete_chat_session(session, row)
    await session.commit()
    return {"ok": True}


# --- Messages ----------------------------------------------------------------


@router.get("/sessions/{session_id}/messages", response_model=GraphChatHistoryOut)
async def list_messages(
    session_id: uuid.UUID,
    limit: int = Query(200, ge=1, le=500),
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphChatHistoryOut:
    await _require_session(session, user, session_id)
    rows = await crud.list_chat_messages(session, session_id, limit=limit)
    return GraphChatHistoryOut(
        items=[_message_out(m) for m in rows], total=len(rows)
    )


@router.post("/sessions/{session_id}/messages", response_model=GraphChatResponse)
async def send_message(
    session_id: uuid.UUID,
    payload: GraphChatRequest,
    background_tasks: BackgroundTasks,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphChatResponse:
    row = await _require_session(session, user, session_id)
    message = payload.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="message is required")

    summary_state = row.summary_state or {}
    summary_text = (summary_state.get("text") or "").strip() or None
    watermark = watermark_from_state(summary_state)

    # RAG history = text turns after the summary watermark (quiz/draft cards excluded).
    prior = await crud.list_chat_messages(
        session,
        session_id,
        limit=50,
        kinds=["text"],
        after=watermark,
    )
    history = [{"role": m.role, "content": m.content} for m in prior]

    try:
        result = await graph_chat_answer(
            session, user, message, history, summary=summary_text
        )
    except Exception as exc:  # noqa: BLE001 — surface LLM failures as a clean 502
        raise HTTPException(
            status_code=502, detail="답변 생성에 실패했어요. 잠시 후 다시 시도해 주세요."
        ) from exc

    appended = await crud.append_chat_messages(
        session,
        row,
        [
            {"role": "user", "content": message},
            {
                "role": "assistant",
                "content": result.answer,
                "referenced_node_ids": result.referenced_node_ids,
            },
        ],
    )
    # Auto-title an untitled room from its first user message.
    if not row.title:
        await crud.rename_chat_session(session, row, message[:40])
    await session.commit()

    post_watermark_count = len(prior) + 2
    if needs_summary_update(post_watermark_count):
        background_tasks.add_task(update_session_summary, session_id, user.id)

    user_msg, assistant_msg = appended
    return GraphChatResponse(
        answer=result.answer,
        referenced_node_ids=result.referenced_node_ids,
        user_message_id=str(user_msg.id),
        assistant_message_id=str(assistant_msg.id),
        created_at=_iso(assistant_msg.created_at),
    )


@router.post("/sessions/{session_id}/events", response_model=GraphChatMessageOut)
async def append_event(
    session_id: uuid.UUID,
    payload: ChatEventRequest,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphChatMessageOut:
    row = await _require_session(session, user, session_id)
    appended = await crud.append_chat_messages(
        session,
        row,
        [
            {
                "role": payload.role,
                "kind": payload.kind,
                "content": payload.content,
                "referenced_node_ids": payload.referenced_node_ids,
                "meta": payload.meta,
            }
        ],
    )
    await session.commit()
    return _message_out(appended[0])
