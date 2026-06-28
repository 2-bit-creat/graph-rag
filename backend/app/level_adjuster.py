"""Level adjustment — frozen in MVP v2 (manual level only)."""

from __future__ import annotations

import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings


async def maybe_adjust_level(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    recent_accuracy: float | None = None,
) -> int | None:
    """Auto level adjustment — disabled when quiz_auto_enabled is False."""
    if not get_settings().quiz_auto_enabled:
        return None
    return None


async def reclassify_queue_by_level(
    session: AsyncSession,
    user_id: uuid.UUID,
    new_level: int,
) -> int:
    """Re-tag archived quizzes when user manually changes level."""
    from . import crud

    return await crud.reclassify_quiz_queues(session, user_id, new_level)
