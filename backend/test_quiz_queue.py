"""Tests for quiz queue grading (no DB)."""

from types import SimpleNamespace

from app.quiz_queue import grade_answer


def _quiz(quiz_type: str, quiz_data: dict):
    return SimpleNamespace(quiz_type=quiz_type, quiz_data=quiz_data)


def test_grade_cloze():
    q = _quiz("cloze", {"accepted_answers": ["espresso"]})
    ok, quality = grade_answer(q, {"answer": "Espresso"})
    assert ok is True
    assert quality == 4


def test_grade_scramble():
    q = _quiz("scramble", {"correct_order": [1, 0, 2]})
    ok, _ = grade_answer(q, {"order": [1, 0, 2]})
    assert ok is True
    ok2, _ = grade_answer(q, {"order": [0, 1, 2]})
    assert ok2 is False


def test_grade_mcq():
    q = _quiz("mcq_nuance", {"correct_index": 2})
    ok, _ = grade_answer(q, {"selected_index": 2})
    assert ok is True
