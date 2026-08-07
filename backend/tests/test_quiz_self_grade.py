"""Flashcard deck self-grading — the learner grades themselves after a flip.

The deck has no typed answer to compare, so ``grade_answer`` short-circuits and
``record_quiz_result`` must still drive SM-2 exactly as the typed path does.
"""

from __future__ import annotations

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Quiz, User
from app.quiz_queue import grade_answer, record_quiz_result


def test_self_grade_known_scores_as_correct() -> None:
    quiz = Quiz(quiz_type="cloze", quiz_data={"accepted_answers": ["ran into"]})
    assert grade_answer(quiz, {"self_grade": "known"}) == (True, 4)


def test_self_grade_again_scores_as_wrong() -> None:
    quiz = Quiz(quiz_type="cloze", quiz_data={"accepted_answers": ["ran into"]})
    assert grade_answer(quiz, {"self_grade": "again"}) == (False, 1)


def test_self_grade_ignores_the_typed_answer_comparison() -> None:
    """A "known" swipe wins even though no answer matches, and vice versa."""
    quiz = Quiz(quiz_type="cloze", quiz_data={"accepted_answers": ["ran into"]})
    assert grade_answer(quiz, {"self_grade": "known", "answer": "wrong"})[0] is True
    assert grade_answer(quiz, {"self_grade": "again", "answer": "ran into"})[0] is False


def test_absent_self_grade_falls_through_to_typed_grading() -> None:
    quiz = Quiz(quiz_type="cloze", quiz_data={"accepted_answers": ["ran into"]})
    assert grade_answer(quiz, {"answer": "ran into"}) == (True, 4)
    assert grade_answer(quiz, {"answer": "walked into"}) == (False, 1)


def test_unknown_self_grade_value_does_not_short_circuit() -> None:
    """Only the two documented values bypass grading; anything else is ignored."""
    quiz = Quiz(quiz_type="cloze", quiz_data={"accepted_answers": ["ran into"]})
    assert grade_answer(quiz, {"self_grade": "maybe", "answer": "ran into"})[0] is True


@pytest.mark.asyncio
async def test_again_swipe_resets_sm2_repetitions(
    db_session: AsyncSession, iso_user: User
) -> None:
    quiz = Quiz(
        quiz_type="cloze",
        user_id=iso_user.id,
        queue_kind="review",
        repetitions=4,
        interval_days=30.0,
    )
    db_session.add(quiz)
    await db_session.flush()

    correct, quality = grade_answer(quiz, {"self_grade": "again"})
    quiz = await record_quiz_result(
        db_session, quiz, correct=correct, quality=quality, commit=False
    )

    assert quiz.repetitions == 0
    assert quiz.interval_days == 3.0
    assert quiz.times_wrong == 1
    assert quiz.is_solved is True


@pytest.mark.asyncio
async def test_known_swipe_advances_sm2_interval(
    db_session: AsyncSession, iso_user: User
) -> None:
    quiz = Quiz(
        quiz_type="cloze",
        user_id=iso_user.id,
        queue_kind="new",
        repetitions=0,
        interval_days=1.0,
    )
    db_session.add(quiz)
    await db_session.flush()

    correct, quality = grade_answer(quiz, {"self_grade": "known"})
    quiz = await record_quiz_result(
        db_session, quiz, correct=correct, quality=quality, commit=False
    )

    assert quiz.repetitions == 1
    assert quiz.times_correct == 1
    # repetitions crossing zero promotes the card out of the "new" queue.
    assert quiz.queue_kind == "review"
    assert quiz.next_review_at is not None
