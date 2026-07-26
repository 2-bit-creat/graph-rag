from datetime import date

import pytest

from app import crud
from app.quiz_progress import _level_for_xp, _streaks, add_attempt, dashboard, raw_xp


def test_xp_policy_applies_type_bonus_and_hint_penalties():
    assert raw_xp(
        quiz_type="cloze",
        correct=True,
        quality=4,
        queue_kind="new",
        hint_level=0,
        answer_revealed=False,
    ) == 10
    assert raw_xp(
        quiz_type="cloze",
        correct=True,
        quality=4,
        queue_kind="review",
        hint_level=1,
        answer_revealed=False,
    ) == 10
    assert raw_xp(
        quiz_type="composition",
        correct=True,
        quality=5,
        queue_kind="new",
        hint_level=0,
        answer_revealed=False,
    ) == 14
    assert raw_xp(
        quiz_type="cloze",
        correct=True,
        quality=4,
        queue_kind="review",
        hint_level=2,
        answer_revealed=True,
    ) == 1


def test_streak_keeps_yesterday_at_risk_until_today_ends():
    today = date(2026, 7, 26)
    active = {date(2026, 7, 23), date(2026, 7, 24), date(2026, 7, 25)}
    assert _streaks(active, today) == (3, 3, True)
    active.add(today)
    assert _streaks(active, today) == (4, 4, False)


def test_growth_level_thresholds_are_triangular():
    assert _level_for_xp(0) == (1, 0, 100)
    assert _level_for_xp(99) == (1, 0, 100)
    assert _level_for_xp(100) == (2, 100, 300)
    assert _level_for_xp(300) == (3, 300, 600)


@pytest.mark.asyncio
async def test_same_quiz_same_day_only_awards_best_score_delta(db_session, iso_user):
    quiz = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="cloze",
        language="english",
        quiz_data={"accepted_answers": ["hello"]},
    )
    first = await add_attempt(
        db_session,
        user_id=iso_user.id,
        quiz=quiz,
        idempotency_key="attempt-low-score",
        answer_payload={"answer": "wrong"},
        correct=False,
        quality=1,
        tutor_feedback=None,
        hint_level=0,
        revealed_tokens=[],
        answer_revealed=False,
    )
    await db_session.commit()
    second = await add_attempt(
        db_session,
        user_id=iso_user.id,
        quiz=quiz,
        idempotency_key="attempt-high-score",
        answer_payload={"answer": "hello"},
        correct=True,
        quality=4,
        tutor_feedback=None,
        hint_level=0,
        revealed_tokens=[],
        answer_revealed=False,
    )
    await db_session.commit()
    assert first.xp_awarded == 2
    assert second.xp_awarded == 8


@pytest.mark.asyncio
async def test_dashboard_uses_attempts_for_today_and_xp(db_session, iso_user):
    quiz = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="composition",
        language="english",
        quiz_data={},
    )
    await add_attempt(
        db_session,
        user_id=iso_user.id,
        quiz=quiz,
        idempotency_key="dashboard-attempt",
        answer_payload={"answer": "I learned today."},
        correct=True,
        quality=5,
        tutor_feedback={"verdict": "natural"},
        hint_level=0,
        revealed_tokens=[],
        answer_revealed=False,
    )
    await db_session.commit()
    result = await dashboard(db_session, iso_user, timezone_name="Asia/Seoul")
    assert result["today"]["composition"] == 1
    assert result["today_xp"] == 14
    assert result["current_streak"] == 1
