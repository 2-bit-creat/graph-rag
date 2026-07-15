"""Background refill entry-point tests for the current daily-batch pipeline."""

from __future__ import annotations

import pytest

from app import quiz_batch
from app.workers import quiz_refill


@pytest.mark.asyncio
async def test_refill_delegates_once_to_daily_batches(iso_user, monkeypatch) -> None:
    calls: list[str] = []

    async def fake_fill(session, user):
        calls.append(str(user.id))
        return {
            "english": {"status": "generated", "cloze": 2, "composition": 1},
            "german": {"status": "source_exhausted", "cloze": 1, "composition": 1},
        }

    monkeypatch.setattr(quiz_batch, "fill_user_daily_batches", fake_fill)

    result = await quiz_refill.refill_user_quizzes(iso_user.id)

    assert calls == [str(iso_user.id)]
    assert result["status"] == "ok"
    assert result["batches"]["english"]["cloze"] == 2


@pytest.mark.asyncio
async def test_refill_skips_when_same_user_is_already_running(iso_user) -> None:
    quiz_refill._IN_FLIGHT.add(iso_user.id)
    try:
        result = await quiz_refill.refill_user_quizzes(iso_user.id)
    finally:
        quiz_refill._IN_FLIGHT.discard(iso_user.id)

    assert result == {"status": "skipped", "reason": "already running"}


@pytest.mark.asyncio
async def test_refill_releases_guard_after_failure(iso_user, monkeypatch) -> None:
    async def fail_fill(session, user):
        raise RuntimeError("boom")

    monkeypatch.setattr(quiz_batch, "fill_user_daily_batches", fail_fill)

    with pytest.raises(RuntimeError, match="boom"):
        await quiz_refill.refill_user_quizzes(iso_user.id)

    assert iso_user.id not in quiz_refill._IN_FLIGHT
