"""Data-subject access export (PIPA 제35조 열람권).

Assembles a complete, human-readable JSON bundle of everything stored for a
user. Vector/embedding columns and the password hash are excluded — they are
internal machinery, not the user's own data — and audio is referenced by key
(the bytes are downloadable via the journal endpoints)."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime
from typing import Any

from pgvector.sqlalchemy import Vector
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .json_util import json_safe
from .models import (
    ChatMessage,
    ChatSession,
    Edge,
    JournalEntry,
    Node,
    Quiz,
    User,
)

_USER_SECRET_FIELDS = {"password_hash"}


def _row_to_dict(row: Any) -> dict:
    """Serialize an ORM row, skipping vector columns (huge, non-user-facing)."""
    out: dict[str, Any] = {}
    for col in row.__table__.columns:
        if isinstance(col.type, Vector):
            continue
        if col.name in _USER_SECRET_FIELDS:
            continue
        out[col.name] = getattr(row, col.name)
    return out


async def _rows(session: AsyncSession, model: Any, user_id: uuid.UUID) -> list[dict]:
    result = await session.execute(select(model).where(model.user_id == user_id))
    return [_row_to_dict(r) for r in result.scalars().all()]


async def export_user_data(session: AsyncSession, user: User) -> dict:
    """Return a JSON-safe dict of all data held for `user`."""
    from . import node_expression_store, user_vocab_store

    account = _row_to_dict(user)

    chat_sessions = await _rows(session, ChatSession, user.id)
    session_ids = [s["id"] for s in chat_sessions]
    chat_messages: list[dict] = []
    if session_ids:
        msg_result = await session.execute(
            select(ChatMessage)
            .where(ChatMessage.session_id.in_(session_ids))
            .order_by(ChatMessage.created_at)
        )
        chat_messages = [_row_to_dict(m) for m in msg_result.scalars().all()]

    try:
        vocabularies = await user_vocab_store.list_vocabularies(user.id)
    except Exception:
        vocabularies = []
    try:
        expressions = await asyncio.to_thread(
            node_expression_store._read_store_sync, user.id
        )
    except Exception:
        expressions = {}

    bundle = {
        "export_meta": {
            "generated_at": datetime.now(UTC).isoformat(),
            "format_version": 1,
            "note": "Personal data export for the account below (PIPA access right).",
        },
        "account": account,
        "journal_entries": await _rows(session, JournalEntry, user.id),
        "graph_nodes": await _rows(session, Node, user.id),
        "graph_edges": await _rows(session, Edge, user.id),
        "quizzes": await _rows(session, Quiz, user.id),
        "chat_sessions": chat_sessions,
        "chat_messages": chat_messages,
        "vocabularies": vocabularies,
        "node_expressions": expressions,
    }
    return json_safe(bundle)
