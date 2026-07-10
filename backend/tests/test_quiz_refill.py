"""Tests for quiz refill worker (LLM mocked)."""

from __future__ import annotations

import uuid
from unittest.mock import AsyncMock, patch

import pytest

from app.workers.quiz_refill import refill_user_quizzes


@pytest.mark.asyncio
async def test_refill_skips_when_auto_disabled(db_session, iso_user, monkeypatch):
    from app.config import get_settings

    settings = get_settings()
    monkeypatch.setattr(settings, "quiz_auto_enabled", False)

    result = await refill_user_quizzes(iso_user.id)
    assert result["status"] == "skipped"


@pytest.mark.asyncio
async def test_refill_generates_up_to_cap(db_session, iso_user, monkeypatch):
    from app.config import get_settings

    settings = get_settings()
    monkeypatch.setattr(settings, "quiz_auto_enabled", True)
    monkeypatch.setattr(settings, "quiz_queue_target_per_type", 3)
    monkeypatch.setattr(settings, "quiz_refill_max_per_run", 2)

    fake_quiz = type(
        "Q",
        (),
        {"source_nodes": [uuid.uuid4()]},
    )()

    with (
        patch(
            "app.workers.quiz_refill.generate_composition_quiz",
            new_callable=AsyncMock,
            return_value=(fake_quiz, None),
        ),
        patch(
            "app.workers.quiz_refill.run_quiz_generate_pipeline",
            new_callable=AsyncMock,
        ),
    ):
        result = await refill_user_quizzes(iso_user.id)

    assert result["status"] == "ok"
    assert result["generated"] <= 2
    assert result["generated"] >= 1
