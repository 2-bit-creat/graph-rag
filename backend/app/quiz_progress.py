"""Quiz-attempt persistence, XP policy, and learner progress aggregates."""

from __future__ import annotations

import math
import uuid
from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Quiz, QuizAttempt, User

XP_POLICY_VERSION = 1
DEFAULT_TIMEZONE = "Asia/Seoul"


def safe_timezone(name: str | None) -> ZoneInfo:
    try:
        return ZoneInfo(name or DEFAULT_TIMEZONE)
    except ZoneInfoNotFoundError:
        return ZoneInfo(DEFAULT_TIMEZONE)


def raw_xp(
    *,
    quiz_type: str,
    correct: bool,
    quality: int,
    queue_kind: str,
    hint_level: int,
    answer_revealed: bool,
) -> int:
    if quiz_type == "composition":
        points = 4 + max(0, min(5, quality)) * 2
    else:
        points = 10 if correct else 2
    if queue_kind == "review":
        points += 2
    points -= 2 if hint_level == 1 else 4 if hint_level >= 2 else 0
    if answer_revealed:
        points = min(points, 1)
    return max(1, points)


async def find_idempotent_attempt(
    session: AsyncSession, user_id: uuid.UUID, key: str | None
) -> QuizAttempt | None:
    if not key:
        return None
    return await session.scalar(
        select(QuizAttempt).where(
            QuizAttempt.user_id == user_id,
            QuizAttempt.idempotency_key == key,
        )
    )


async def add_attempt(
    session: AsyncSession,
    *,
    user_id: uuid.UUID,
    quiz: Quiz,
    idempotency_key: str,
    answer_payload: dict,
    correct: bool,
    quality: int,
    tutor_feedback: dict | None,
    hint_level: int,
    revealed_tokens: list[str],
    answer_revealed: bool,
    timezone_name: str = DEFAULT_TIMEZONE,
) -> QuizAttempt:
    now = datetime.now(UTC)
    tz = safe_timezone(timezone_name)
    local_day = now.astimezone(tz).date()
    start = datetime.combine(local_day, time.min, tzinfo=tz).astimezone(UTC)
    end = start + timedelta(days=1)
    earned_before = int(
        await session.scalar(
            select(func.coalesce(func.sum(QuizAttempt.xp_awarded), 0)).where(
                QuizAttempt.user_id == user_id,
                QuizAttempt.quiz_id == quiz.id,
                QuizAttempt.answered_at >= start,
                QuizAttempt.answered_at < end,
            )
        )
        or 0
    )
    score = raw_xp(
        quiz_type=quiz.quiz_type,
        correct=correct,
        quality=quality,
        queue_kind=quiz.queue_kind,
        hint_level=hint_level,
        answer_revealed=answer_revealed,
    )
    attempt = QuizAttempt(
        user_id=user_id,
        quiz_id=quiz.id,
        idempotency_key=idempotency_key,
        quiz_type=quiz.quiz_type,
        language=quiz.language or str((quiz.quiz_data or {}).get("language") or "english"),
        queue_kind=quiz.queue_kind,
        answer_payload=answer_payload,
        correct=correct,
        quality=quality,
        tutor_feedback=tutor_feedback,
        hint_level=hint_level,
        revealed_tokens=revealed_tokens,
        answer_revealed=answer_revealed,
        xp_awarded=max(0, score - earned_before),
        xp_policy_version=XP_POLICY_VERSION,
        source="live",
        answered_at=now,
    )
    session.add(attempt)
    return attempt


def _level_for_xp(total_xp: int) -> tuple[int, int, int]:
    # threshold(level) = 100 * level * (level + 1) / 2
    level = max(1, int((math.sqrt(1 + 8 * total_xp / 100) - 1) // 2) + 1)
    start = 100 * (level - 1) * level // 2
    end = 100 * level * (level + 1) // 2
    return level, start, end


def _streaks(active_days: set[date], today: date) -> tuple[int, int, bool]:
    anchor = today if today in active_days else today - timedelta(days=1)
    at_risk = today not in active_days and anchor in active_days
    current = 0
    cursor = anchor
    while cursor in active_days:
        current += 1
        cursor -= timedelta(days=1)

    longest = run = 0
    previous: date | None = None
    for day in sorted(active_days):
        run = run + 1 if previous and day == previous + timedelta(days=1) else 1
        longest = max(longest, run)
        previous = day
    return current, longest, at_risk


async def dashboard(
    session: AsyncSession,
    user: User,
    *,
    timezone_name: str = DEFAULT_TIMEZONE,
) -> dict:
    tz = safe_timezone(timezone_name)
    timezone_name = getattr(tz, "key", DEFAULT_TIMEZONE)
    now = datetime.now(UTC)
    today = now.astimezone(tz).date()
    attempts = list(
        (
            await session.scalars(
                select(QuizAttempt)
                .where(QuizAttempt.user_id == user.id)
                .order_by(QuizAttempt.answered_at.asc())
            )
        ).all()
    )
    total_xp = int(
        await session.scalar(
            select(func.coalesce(func.sum(QuizAttempt.xp_awarded), 0)).where(
                QuizAttempt.user_id == user.id
            )
        )
        or 0
    )
    by_day: dict[date, dict] = {}
    for attempt in attempts:
        day = attempt.answered_at.astimezone(tz).date()
        row = by_day.setdefault(
            day, {"cloze": 0, "composition": 0, "xp": 0, "correct": 0, "total": 0}
        )
        row["composition" if attempt.quiz_type == "composition" else "cloze"] += 1
        row["xp"] += attempt.xp_awarded
        row["correct"] += int(attempt.correct)
        row["total"] += 1

    active_days = set(by_day)
    current, longest, at_risk = _streaks(active_days, today)
    languages = max(1, len(getattr(user, "target_languages", None) or [user.target_language]))
    cloze_goal = user.daily_cloze_target * languages
    composition_goal = user.daily_composition_target * languages
    today_row = by_day.get(
        today, {"cloze": 0, "composition": 0, "xp": 0, "correct": 0, "total": 0}
    )
    week = []
    week_completed = 0
    perfect_days = 0
    for offset in range(6, -1, -1):
        day = today - timedelta(days=offset)
        row = by_day.get(
            day, {"cloze": 0, "composition": 0, "xp": 0, "correct": 0, "total": 0}
        )
        perfect = (
            cloze_goal + composition_goal > 0
            and row["cloze"] >= cloze_goal
            and row["composition"] >= composition_goal
        )
        perfect_days += int(perfect)
        week_completed += row["total"]
        week.append({"date": day.isoformat(), **row, "perfect": perfect})

    total_attempts = sum(row["total"] for row in by_day.values())
    total_correct = sum(row["correct"] for row in by_day.values())
    cloze_count = sum(row["cloze"] for row in by_day.values())
    composition_count = sum(row["composition"] for row in by_day.values())
    growth_level, level_start, next_level = _level_for_xp(total_xp)
    achievement_specs = [
        ("first_quiz", "첫걸음", total_attempts, 1),
        ("perfect_day", "퍼펙트 데이", perfect_days, 1),
        ("streak_3", "3일 연속", longest, 3),
        ("streak_7", "7일 연속", longest, 7),
        ("streak_30", "30일 연속", longest, 30),
        ("cloze_100", "단어 100", cloze_count, 100),
        ("composition_20", "작문 20", composition_count, 20),
        ("weekly_5", "주간 목표 5일", perfect_days, 5),
    ]
    return {
        "timezone": timezone_name,
        "current_streak": current,
        "longest_streak": longest,
        "streak_at_risk": at_risk,
        "total_xp": total_xp,
        "today_xp": today_row["xp"],
        "growth_level": growth_level,
        "level_start_xp": level_start,
        "next_level_xp": next_level,
        "today": {
            **today_row,
            "cloze_goal": cloze_goal,
            "composition_goal": composition_goal,
            "language_count": languages,
            "perfect": (
                cloze_goal + composition_goal > 0
                and today_row["cloze"] >= cloze_goal
                and today_row["composition"] >= composition_goal
            ),
        },
        "week": week,
        "week_completed": week_completed,
        "accuracy": round(total_correct / total_attempts, 4) if total_attempts else 0.0,
        "achievements": [
            {
                "id": key,
                "title": title,
                "current": min(current_value, target),
                "target": target,
                "unlocked": current_value >= target,
            }
            for key, title, current_value, target in achievement_specs
        ],
    }
