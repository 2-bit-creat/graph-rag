from __future__ import annotations

from datetime import UTC, datetime, timedelta

from app.models import Quiz
from app.quiz_policies import presentation_reason


def test_direct_node_has_highest_presentation_tier() -> None:
    quiz = Quiz(quiz_type="composition", queue_kind="new")
    tier, reason = presentation_reason(quiz, direct_node=True)
    assert tier == 0
    assert "직접 선택" in reason


def test_overdue_review_beats_new_card() -> None:
    overdue = Quiz(
        quiz_type="cloze",
        queue_kind="review",
        next_review_at=datetime.now(UTC) - timedelta(days=1),
        times_wrong=1,
    )
    new = Quiz(quiz_type="cloze", queue_kind="new")
    assert presentation_reason(overdue)[0] < presentation_reason(new)[0]
