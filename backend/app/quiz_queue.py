"""Quiz queue engine — per-type dual queues, 7:3 session, SM-2."""

from __future__ import annotations

import math
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .level_guidelines import window_for_level
from .models import Quiz, User
from .quiz_types import validate_quiz_type


async def _get_user_level(session: AsyncSession, user_id: uuid.UUID) -> int:
    user = await session.get(User, user_id)
    return user.current_level if user else 10


async def build_session(
    session: AsyncSession,
    user_id: uuid.UUID,
    quiz_type: str,
    *,
    size: int | None = None,
    entry_id: uuid.UUID | None = None,
    vocab_source: str | None = None,
    language: str | None = None,
) -> list[Quiz]:
    """Pick quizzes: 70% review + 30% new, filtered by type and level window.

    When ``vocab_source`` is given, the primary review/new queries prefer quizzes
    stamped with that source (``quiz_data._source.vocab_id``); the shortfall backfill
    stays unfiltered so a session is never left empty just because few same-source
    quizzes exist yet.
    """
    settings = get_settings()
    quiz_type = validate_quiz_type(quiz_type)
    size = size or settings.quiz_session_size
    level = await _get_user_level(session, user_id)
    lo, hi = window_for_level(level, settings.quiz_level_window)

    review_count = math.ceil(size * settings.quiz_review_ratio)
    new_count = size - review_count
    now = datetime.now(UTC)
    lang = (language or "").strip().lower() or None

    def _source_filter(stmt):
        if not vocab_source:
            return stmt
        return stmt.where(
            Quiz.quiz_data["_source"]["vocab_id"].astext == vocab_source
        )

    def _language_filter(stmt):
        if not lang:
            return stmt
        return stmt.where(Quiz.quiz_data["language"].astext == lang)

    review_q = _source_filter(
        _language_filter(select(Quiz))
        .where(
            Quiz.user_id == user_id,
            Quiz.quiz_type == quiz_type,
            Quiz.queue_kind == "review",
            Quiz.difficulty_level >= lo,
            Quiz.difficulty_level <= hi,
            or_(Quiz.next_review_at.is_(None), Quiz.next_review_at <= now),
        )
        .order_by(Quiz.next_review_at.asc().nullsfirst())
        .limit(review_count)
    )
    new_q = (
        _language_filter(select(Quiz))
        .where(
            Quiz.user_id == user_id,
            Quiz.quiz_type == quiz_type,
            Quiz.queue_kind == "new",
            Quiz.repetitions == 0,
            Quiz.difficulty_level >= lo,
            Quiz.difficulty_level <= hi,
        )
        # FIFO: serve new items in the order they were generated
        .order_by(Quiz.created_at.asc())
        .limit(new_count)
    )
    if entry_id is not None:
        new_q = new_q.where(Quiz.associated_entry_id == entry_id)
    new_q = _source_filter(new_q)

    review_items = list((await session.execute(review_q)).scalars().all())
    new_items = list((await session.execute(new_q)).scalars().all())

    picked = review_items + new_items
    shortfall = size - len(picked)
    if shortfall > 0:
        extra_filters = [
            Quiz.user_id == user_id,
            Quiz.quiz_type == quiz_type,
            Quiz.queue_kind == "new",
        ]
        if picked:
            extra_filters.append(Quiz.id.not_in([q.id for q in picked]))
        if lang:
            extra_filters.append(Quiz.quiz_data["language"].astext == lang)
        extra_review = (
            select(Quiz)
            .where(*extra_filters)
            .order_by(Quiz.created_at.asc())
            .limit(shortfall)
        )
        picked.extend((await session.execute(extra_review)).scalars().all())

    return picked[:size]


async def pick_quizzes_by_ids(
    session: AsyncSession,
    user_id: uuid.UUID,
    quiz_ids: list[uuid.UUID],
) -> list[Quiz]:
    """Load specific quizzes in request order (for 'solve this one' from the hub)."""
    from . import crud

    picked: list[Quiz] = []
    for qid in quiz_ids:
        quiz = await crud.get_quiz(session, qid, user_id)
        if quiz is not None:
            picked.append(quiz)
    return picked


def grade_answer(quiz: Quiz, payload: dict) -> tuple[bool, int]:
    """Return (correct, quality 0-5)."""
    quiz_type = quiz.quiz_type
    data = quiz.quiz_data or {}

    if quiz_type == "cloze":
        answer = (payload.get("answer") or "").strip().lower()
        accepted = [a.strip().lower() for a in (data.get("accepted_answers") or [])]
        correct = answer in accepted
    elif quiz_type == "scramble":
        order = payload.get("order") or payload.get("correct_order") or []
        expected = data.get("correct_order") or []
        correct = list(order) == list(expected)
    elif quiz_type == "mcq_nuance":
        idx = payload.get("selected_index")
        correct = idx is not None and int(idx) == int(data.get("correct_index", -1))
    else:
        correct = False

    quality = 4 if correct else 1
    return correct, quality


async def record_quiz_result(
    session: AsyncSession,
    quiz: Quiz,
    *,
    correct: bool,
    quality: int,
) -> Quiz:
    """SM-2 update on quiz row."""
    if correct:
        quiz.times_correct += 1
    else:
        quiz.times_wrong += 1
    quiz.last_answered_at = datetime.now(UTC)
    quiz.is_solved = True

    if quality < 3:
        quiz.repetitions = 0
        quiz.interval_days = 1.0
    else:
        if quiz.repetitions == 0:
            quiz.interval_days = 1.0
        elif quiz.repetitions == 1:
            quiz.interval_days = 3.0
        else:
            quiz.interval_days = round(quiz.interval_days * quiz.ease_factor, 1)
        quiz.repetitions += 1
        quiz.ease_factor = max(
            1.3,
            quiz.ease_factor + 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02),
        )

    quiz.next_review_at = datetime.now(UTC) + timedelta(days=quiz.interval_days)
    if quiz.queue_kind == "new" and quiz.repetitions > 0:
        quiz.queue_kind = "review"

    await session.commit()
    await session.refresh(quiz)
    return quiz


async def count_queues(
    session: AsyncSession, user_id: uuid.UUID
) -> dict[str, dict[str, int]]:
    """Per-type new/review counts."""
    now = datetime.now(UTC)
    result: dict[str, dict[str, int]] = {
        t: {"new": 0, "review": 0}
        for t in ("cloze", "scramble", "mcq_nuance", "composition")
    }
    q = select(Quiz).where(Quiz.user_id == user_id, Quiz.queue_kind != "archived")
    for quiz in (await session.execute(q)).scalars().all():
        if quiz.quiz_type not in result:
            continue
        if quiz.queue_kind == "new" and quiz.repetitions == 0:
            result[quiz.quiz_type]["new"] += 1
        elif quiz.queue_kind == "review":
            if quiz.next_review_at is None or quiz.next_review_at <= now:
                result[quiz.quiz_type]["review"] += 1
    return result
