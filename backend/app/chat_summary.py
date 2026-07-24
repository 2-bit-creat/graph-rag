"""Rolling chat-session summary (short-term memory) — server-internal only."""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .crud import get_chat_session, set_chat_session_summary_state
from .db import async_session_factory
from .models import ChatMessage, ChatSession, User
from .prompts import native_pack
from .rag import _get_client

logger = logging.getLogger(__name__)


def needs_summary_update(
    post_watermark_message_count: int,
    *,
    history_turns: int | None = None,
    batch: int | None = None,
    enabled: bool | None = None,
) -> bool:
    """True when verbatim backlog after the watermark exceeds history_turns + batch."""
    settings = get_settings()
    if enabled is None:
        enabled = settings.graph_chat_summary_enabled
    if not enabled:
        return False
    if history_turns is None:
        history_turns = settings.graph_chat_history_turns
    if batch is None:
        batch = settings.graph_chat_summary_batch
    return post_watermark_message_count > history_turns + batch


def watermark_from_state(state: dict | None) -> datetime | None:
    if not state:
        return None
    raw = state.get("upto_created_at")
    if not raw:
        return None
    return datetime.fromisoformat(raw)


async def _load_text_messages_after(
    session: AsyncSession,
    session_id: uuid.UUID,
    after: datetime | None,
) -> list[ChatMessage]:
    stmt = select(ChatMessage).where(
        ChatMessage.session_id == session_id,
        ChatMessage.kind == "text",
    )
    if after is not None:
        stmt = stmt.where(ChatMessage.created_at > after)
    stmt = stmt.order_by(ChatMessage.created_at.asc())
    return list((await session.execute(stmt)).scalars().all())


def _format_dialogue(messages: list[ChatMessage]) -> str:
    return "\n".join(f"{m.role}: {m.content}" for m in messages)


async def apply_summary_update(
    session: AsyncSession,
    row: ChatSession,
) -> bool:
    """Absorb one summary batch when needed. Returns True if summary_state changed."""
    settings = get_settings()
    state = row.summary_state or {}
    expected_watermark_id = state.get("upto_message_id")
    watermark = watermark_from_state(state)

    messages = await _load_text_messages_after(session, row.id, watermark)
    if not needs_summary_update(len(messages)):
        return False

    history_turns = settings.graph_chat_history_turns
    batch = settings.graph_chat_summary_batch
    older = messages[:-history_turns]
    to_summarize = older[:batch]
    if not to_summarize:
        return False

    await session.refresh(row)
    current_state = row.summary_state or {}
    if current_state.get("upto_message_id") != expected_watermark_id:
        return False

    owner = await session.get(User, row.user_id)
    pack = native_pack(getattr(owner, "native_language", None))

    old_summary = (state.get("text") or "").strip()
    user_prompt = pack.summary_user_template.format(
        prior=old_summary or pack.summary_no_prior,
        dialogue=_format_dialogue(to_summarize),
    )

    try:
        resp = await _get_client().chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": pack.summary_system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.2,
            max_tokens=settings.graph_chat_summary_max_tokens,
            timeout=settings.openai_timeout_sec,
        )
    except Exception as exc:  # noqa: BLE001 — keep prior summary on LLM failure
        logger.warning("chat_summary: LLM failed for session %s: %s", row.id, exc)
        return False
    new_summary = (resp.choices[0].message.content or "").strip()
    if not new_summary:
        logger.warning(
            "chat_summary: empty summary for session %s — keeping prior state",
            row.id,
        )
        return False

    last_msg = to_summarize[-1]
    new_state = {
        "text": new_summary,
        "upto_message_id": str(last_msg.id),
        "upto_created_at": last_msg.created_at.isoformat(),
        "covered_count": (state.get("covered_count") or 0) + len(to_summarize),
        "updated_at": datetime.now(UTC).isoformat(),
        "model": settings.openai_model,
    }
    await session.refresh(row)
    if (row.summary_state or {}).get("upto_message_id") != expected_watermark_id:
        return False
    await set_chat_session_summary_state(session, row, new_state)
    return True


async def update_session_summary(session_id: uuid.UUID, user_id: uuid.UUID) -> None:
    """Background entry point: absorb the oldest summary batch into summary_state."""
    async with async_session_factory() as session:
        try:
            row = await get_chat_session(session, user_id, session_id)
            if row is None:
                return
            if await apply_summary_update(session, row):
                await session.commit()
        except Exception as exc:  # noqa: BLE001 — background task must not escape
            logger.warning(
                "chat_summary: update failed for session %s: %s", session_id, exc
            )
            await session.rollback()
