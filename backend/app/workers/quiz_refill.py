"""Batch quiz refill — frozen in MVP v2."""

from __future__ import annotations

import uuid

from ..config import get_settings


async def refill_user_quizzes(user_id: uuid.UUID) -> dict:
    """Auto-refill from knowledge graph — disabled when quiz_auto_enabled is False."""
    if not get_settings().quiz_auto_enabled:
        return {"status": "skipped", "reason": "quiz_auto_enabled=False"}
    return {"status": "skipped", "reason": "not implemented"}
