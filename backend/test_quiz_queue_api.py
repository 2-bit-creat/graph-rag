"""Tests for quiz queue list API helpers (no pytest required)."""

import uuid
from datetime import UTC, datetime
from types import SimpleNamespace

from app.quiz_presenter import quiz_queue_item_dict


def _quiz(**kwargs):
    defaults = dict(
        id=uuid.uuid4(),
        quiz_type="scramble",
        queue_kind="new",
        difficulty_level=25,
        source_nodes=None,
        question_ko=None,
        sentence_en="I went to the cafe.",
        quiz_data={"sentence_en": "I went to the cafe.", "correct_order": [0, 1, 2, 3]},
        next_review_at=None,
        repetitions=0,
        times_correct=0,
        times_wrong=0,
        created_at=datetime.now(UTC),
        associated_entry_id=None,
    )
    defaults.update(kwargs)
    return SimpleNamespace(**defaults)


def test_presenter_with_source_nodes():
    nid = uuid.uuid4()
    quiz = _quiz(source_nodes=[nid], quiz_type="cloze", quiz_data={"prompt_en": "Hi ____."})
    out = quiz_queue_item_dict(quiz, {nid: "Cheolsu"})
    assert out["target_node"] == "Cheolsu"


def test_presenter_mcq_context():
    quiz = _quiz(
        quiz_type="mcq_nuance",
        quiz_data={
            "prompt_ko": "어색한 표현은?",
            "options": ["A", "B", "C"],
            "correct_index": 1,
        },
    )
    out = quiz_queue_item_dict(quiz, {})
    assert out["context_sentence"] == "어색한 표현은?"
    assert out["target_node"] == "B"


def test_streak_maps_repetitions():
    quiz = _quiz(queue_kind="review", repetitions=3, next_review_at=datetime.now(UTC))
    out = quiz_queue_item_dict(quiz, {})
    assert out["streak"] == 3
    assert out["queue_kind"] == "review"


def main():
    test_presenter_with_source_nodes()
    test_presenter_mcq_context()
    test_streak_maps_repetitions()
    print("All quiz queue API helper tests passed.")


if __name__ == "__main__":
    main()
