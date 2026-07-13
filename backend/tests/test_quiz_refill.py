"""Quiz auto-refill worker — bundle count, per-run cap, target stop, seed rotation.

The LLM bundle call is mocked; we only exercise the worker's counting/capping.
"""

from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app import crud
from app.config import get_settings
from app.db import async_session_factory
from app.models import Quiz
from app.workers import quiz_refill

_TYPES = ("cloze", "composition")


def _make_fake_bundle(counter: list[int]):
    """A stand-in for generate_quiz_bundle that inserts one row per type."""

    async def fake_bundle(session, user, *, language, exclude_node_ids=None):
        counter[0] += 1
        created = []
        for t in _TYPES:
            quiz = await crud.create_quiz(
                session,
                user_id=user.id,
                quiz_type=t,
                question_ko=f"{language}-{t}-{counter[0]}",
                quiz_data={"language": language},
                difficulty_level=user.current_level,
                queue_kind="new",
                language=language,
            )
            created.append(quiz)
        return created, {}

    return fake_bundle


async def _new_count(user_id) -> int:
    async with async_session_factory() as s:
        return int(
            (
                await s.execute(
                    select(func.count()).select_from(Quiz).where(
                        Quiz.user_id == user_id, Quiz.queue_kind == "new"
                    )
                )
            ).scalar_one()
        )


@pytest.mark.asyncio
async def test_refill_stops_at_target(db_session, iso_user, monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "quiz_auto_enabled", True)
    monkeypatch.setattr(settings, "quiz_queue_target_per_type", 2)
    monkeypatch.setattr(settings, "quiz_refill_max_bundles_per_run", 10)

    counter = [0]
    monkeypatch.setattr(quiz_refill, "generate_quiz_bundle", _make_fake_bundle(counter))

    result = await quiz_refill.refill_user_quizzes(iso_user.id)

    assert result["status"] == "ok"
    # Each bundle adds 1 per type; target per type is 2 → exactly 2 bundles.
    assert counter[0] == 2
    assert await _new_count(iso_user.id) == 2 * len(_TYPES)


@pytest.mark.asyncio
async def test_refill_respects_per_run_cap(db_session, iso_user, monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "quiz_auto_enabled", True)
    monkeypatch.setattr(settings, "quiz_queue_target_per_type", 100)
    monkeypatch.setattr(settings, "quiz_refill_max_bundles_per_run", 3)

    counter = [0]
    monkeypatch.setattr(quiz_refill, "generate_quiz_bundle", _make_fake_bundle(counter))

    await quiz_refill.refill_user_quizzes(iso_user.id)

    # Target is unreachable in one run → capped at the per-run bundle budget.
    assert counter[0] == 3


@pytest.mark.asyncio
async def test_refill_skipped_when_disabled(db_session, iso_user, monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "quiz_auto_enabled", False)
    result = await quiz_refill.refill_user_quizzes(iso_user.id)
    assert result["status"] == "skipped"
