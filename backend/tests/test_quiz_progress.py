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


@pytest.mark.asyncio
async def test_dashboard_buckets_days_in_the_learners_timezone(db_session, iso_user):
    """The same attempt falls on different calendar days in different zones.

    The dashboard used to take its zone from a client query parameter while
    `add_attempt` silently used the Seoul default, so the streak and the daily
    XP cap could disagree about which day an attempt belonged to. Both now read
    `User.timezone`.
    """
    from datetime import UTC, datetime

    quiz = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="cloze",
        language="english",
        quiz_data={},
    )
    attempt = await add_attempt(
        db_session,
        user_id=iso_user.id,
        quiz=quiz,
        idempotency_key="tz-attempt",
        answer_payload={"answer": "x"},
        correct=True,
        quality=5,
        tutor_feedback=None,
        hint_level=0,
        revealed_tokens=[],
        answer_revealed=False,
    )
    # 02:00 UTC is 11:00 the same day in Seoul, but 19:00 the *previous* day in
    # Los Angeles — the exact case a hardcoded Seoul default gets wrong.
    attempt.answered_at = datetime(2026, 8, 7, 2, 0, tzinfo=UTC)
    await db_session.commit()

    def active_days(result: dict) -> set[str]:
        return {row["date"] for row in result["week"] if row["total"] > 0}

    seoul = await dashboard(db_session, iso_user, timezone_name="Asia/Seoul")
    la = await dashboard(db_session, iso_user, timezone_name="America/Los_Angeles")

    assert active_days(seoul) == {"2026-08-07"}
    assert active_days(la) == {"2026-08-06"}


@pytest.mark.asyncio
async def test_dashboard_defaults_to_the_zone_stored_on_the_user(db_session, iso_user):
    """No explicit argument -> the learner's own zone, not Seoul."""
    from datetime import UTC, datetime

    quiz = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="cloze",
        language="english",
        quiz_data={},
    )
    attempt = await add_attempt(
        db_session,
        user_id=iso_user.id,
        quiz=quiz,
        idempotency_key="tz-stored",
        answer_payload={"answer": "x"},
        correct=True,
        quality=5,
        tutor_feedback=None,
        hint_level=0,
        revealed_tokens=[],
        answer_revealed=False,
    )
    attempt.answered_at = datetime(2026, 8, 7, 2, 0, tzinfo=UTC)
    iso_user.timezone = "America/Los_Angeles"
    await db_session.commit()

    result = await dashboard(db_session, iso_user)
    assert result["timezone"] == "America/Los_Angeles"
    assert {row["date"] for row in result["week"] if row["total"] > 0} == {"2026-08-06"}


def test_user_timezone_name_rejects_names_the_tz_database_does_not_know():
    """The stored value reaches Postgres as a timezone argument, so a malformed
    name must never survive validation."""
    from types import SimpleNamespace

    from app.quiz_progress import DEFAULT_TIMEZONE, user_timezone_name

    assert user_timezone_name(SimpleNamespace(timezone="Europe/Berlin")) == "Europe/Berlin"
    for bad in ("", "Not/AZone", "../../etc/passwd", None):
        assert user_timezone_name(SimpleNamespace(timezone=bad)) == DEFAULT_TIMEZONE


@pytest.mark.asyncio
async def test_settings_ignores_an_unresolvable_zone_instead_of_resetting(
    db_session, iso_user
):
    """A device reporting nonsense must not silently move the learner to Seoul."""
    await crud.update_user_profile_settings(
        db_session, iso_user, timezone="Europe/Berlin"
    )
    assert iso_user.timezone == "Europe/Berlin"

    for bad in ("Not/AZone", "../../etc/passwd", "xyz"):
        await crud.update_user_profile_settings(db_session, iso_user, timezone=bad)
        assert iso_user.timezone == "Europe/Berlin"
