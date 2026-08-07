"""Quiz queue engine — per-type dual queues, 7:3 session, SM-2."""

from __future__ import annotations

import math
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, case, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .level_guidelines import window_for_level
from .models import Quiz, User
from .quiz_policies import (
    PRESENTATION_POLICY_VERSION,
    REVIEW_POLICY_VERSION,
    presentation_reason,
    record_policy_decision,
    review_reason,
)
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
        # Prefer the indexed column; fall back to the JSON mirror for any rows
        # created before the language column existed and not yet backfilled.
        return stmt.where(
            or_(
                Quiz.language == lang,
                and_(Quiz.language.is_(None), Quiz.quiz_data["language"].astext == lang),
            )
        )

    # Review order: prior vocabulary misses → writing (lowest score first) →
    # correct vocabulary. Within each bucket, the oldest answered item wins.
    review_group = case(
        (and_(Quiz.quiz_type != "composition", Quiz.times_wrong > 0), 0),
        (Quiz.quiz_type == "composition", 1),
        else_=2,
    )
    review_quality = case(
        (Quiz.quiz_type == "composition", func.coalesce(Quiz.last_quality, 5)),
        else_=5,
    )
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
        .order_by(
            review_group.asc(),
            review_quality.asc(),
            Quiz.last_answered_at.asc().nullsfirst(),
            Quiz.created_at.asc(),
        )
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
            extra_filters.append(
                or_(
                    Quiz.language == lang,
                    and_(Quiz.language.is_(None), Quiz.quiz_data["language"].astext == lang),
                )
            )
        extra_review = (
            select(Quiz)
            .where(*extra_filters)
            .order_by(Quiz.created_at.asc())
            .limit(shortfall)
        )
        picked.extend((await session.execute(extra_review)).scalars().all())

    picked = picked[:size]
    for quiz in picked:
        tier, reason = presentation_reason(quiz)
        await record_policy_decision(
            session,
            user_id=user_id,
            policy="presentation",
            policy_version=PRESENTATION_POLICY_VERSION,
            entity_type="quiz",
            entity_id=quiz.id,
            reason=reason,
            details={"tier": tier, "quiz_type": quiz.quiz_type, "language": quiz.language},
        )
    return picked


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


def _normalize_answer(text: str, language: str) -> str:
    """Grading-time normalization for a learner's typed answer.

    Delegates to the target language pack — Latin-script targets fold to
    lowercase, trimmed; Korean also tolerates whitespace variants a learner
    naturally introduces around particles/spacing rules that don't change the
    answer's identity (e.g. "그 사람" vs "그사람").
    """
    from .language_packs import target_pack

    return target_pack(language).normalize_learner_answer(text)


def grade_answer(quiz: Quiz, payload: dict) -> tuple[bool, int]:
    """Return (correct, quality 0-5)."""
    # Flashcard deck: the learner already graded themselves against the revealed
    # back of the card, so there is nothing to compare. Quality mirrors what the
    # typed path produces (4 correct / 1 wrong) so record_quiz_result's SM-2
    # branches behave identically for both entry points.
    self_grade = payload.get("self_grade")
    if self_grade in ("known", "again"):
        correct = self_grade == "known"
        return correct, (4 if correct else 1)

    quiz_type = quiz.quiz_type
    data = quiz.quiz_data or {}
    language = getattr(quiz, "language", None) or data.get("language") or "english"

    if quiz_type == "cloze":
        answer = _normalize_answer(payload.get("answer") or "", language)
        accepted = [_normalize_answer(a, language) for a in (data.get("accepted_answers") or [])]
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
    commit: bool = True,
) -> Quiz:
    """SM-2 update on quiz row."""
    if correct:
        quiz.times_correct += 1
    else:
        quiz.times_wrong += 1
    answered_at = datetime.now(UTC)
    if quiz.first_answered_at is None:
        quiz.first_answered_at = answered_at
    quiz.last_answered_at = answered_at
    quiz.is_solved = True
    quiz.last_quality = max(0, min(5, int(quality)))

    if quality < 3:
        quiz.repetitions = 0
        # Failed items re-enter the review pool after three days, while the
        # daily batch remains an immutable snapshot.
        quiz.interval_days = 3.0
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

    reason, details = review_reason(quiz, correct=correct, quality=quality)
    await record_policy_decision(
        session,
        user_id=quiz.user_id,
        policy="review",
        policy_version=REVIEW_POLICY_VERSION,
        entity_type="quiz",
        entity_id=quiz.id,
        reason=reason,
        details=details,
    )

    if commit:
        await session.commit()
        await session.refresh(quiz)
    else:
        await session.flush()
    return quiz


async def count_queues(
    session: AsyncSession, user_id: uuid.UUID
) -> dict[str, dict[str, int]]:
    """Per-type new/review counts.

    Counted in Postgres. The previous version loaded every non-archived Quiz row
    the user owns — each carrying its full ``quiz_data`` JSONB question payload —
    to add up four integers, which made ``GET /quiz/profile`` one of the slowest
    calls in the app and one that got worse with every quiz generated.
    """
    now = datetime.now(UTC)
    result: dict[str, dict[str, int]] = {
        t: {"new": 0, "review": 0}
        for t in ("cloze", "composition")
    }
    rows = await session.execute(
        select(
            Quiz.quiz_type,
            func.count()
            .filter(and_(Quiz.queue_kind == "new", Quiz.repetitions == 0))
            .label("new"),
            func.count()
            .filter(
                and_(
                    Quiz.queue_kind == "review",
                    or_(
                        Quiz.next_review_at.is_(None),
                        Quiz.next_review_at <= now,
                    ),
                )
            )
            .label("review"),
        )
        .where(
            Quiz.user_id == user_id,
            Quiz.queue_kind != "archived",
            Quiz.quiz_type.in_(tuple(result)),
        )
        .group_by(Quiz.quiz_type)
    )
    for quiz_type, new_count, review_count in rows.all():
        result[str(quiz_type)] = {"new": int(new_count), "review": int(review_count)}
    return result
