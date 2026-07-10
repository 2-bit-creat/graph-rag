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
from .language_config import normalize_native
from .llm_usage import log_usage
from .models import ChatMessage, ChatSession, User
from .rag import _get_client

logger = logging.getLogger(__name__)


def _summary_system_prompt(*, native_language: str = "korean") -> str:
    native = normalize_native(native_language)
    if native == "english":
        return (
            "You are a conversation summarizer. Merge [Existing summary] and [New dialogue] "
            "into one updated summary. Preserve: new facts about the user, emotional state "
            "and reasons, ongoing topics, plans or commitments they mentioned. Skip greetings "
            "and small talk. Write in English bullet points ('-'), max 800 characters total."
        )
    return (
        "당신은 대화 요약 도우미입니다. [기존 요약]과 [새 대화]를 합쳐 하나의 최신 요약으로 "
        "갱신하세요. 다음을 우선 보존하세요: 사용자에 대해 새로 드러난 사실, 감정 상태와 그 "
        "이유, 진행 중인 대화 주제, 사용자가 언급한 계획·약속. 인사말과 단순 잡담은 "
        "생략하세요. 한국어 개조식(불릿 '-')으로, 전체 800자 이내로 쓰세요."
    )


_SUMMARY_SYSTEM = _summary_system_prompt(native_language="korean")


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
    *,
    native_language: str = "korean",
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

    native = normalize_native(native_language)
    old_label = "(none)" if native == "english" else "(없음)"
    new_label = "[New dialogue]" if native == "english" else "[새 대화]"
    existing_label = "[Existing summary]" if native == "english" else "[기존 요약]"
    updated_label = "Updated summary:" if native == "english" else "갱신된 요약:"

    old_summary = (state.get("text") or "").strip()
    user_prompt = (
        f"{existing_label}\n{old_summary or old_label}\n\n"
        f"{new_label}\n{_format_dialogue(to_summarize)}\n\n"
        f"{updated_label}"
    )

    try:
        resp = await _get_client().chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": _summary_system_prompt(native_language=native)},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.2,
            max_tokens=settings.graph_chat_summary_max_tokens,
            timeout=settings.openai_timeout_sec,
        )
    except Exception as exc:  # noqa: BLE001 — keep prior summary on LLM failure
        logger.warning("chat_summary: LLM failed for session %s: %s", row.id, exc)
        return False
    log_usage("chat_summary", resp)
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
            user = await session.get(User, user_id)
            native_language = normalize_native(
                getattr(user, "native_language", None) if user else None
            )
            if await apply_summary_update(session, row, native_language=native_language):
                await session.commit()
        except Exception as exc:  # noqa: BLE001 — background task must not escape
            logger.warning(
                "chat_summary: update failed for session %s: %s", session_id, exc
            )
            await session.rollback()
