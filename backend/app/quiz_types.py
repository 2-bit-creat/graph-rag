"""Quiz type constants."""

from __future__ import annotations

QUIZ_TYPES = frozenset({"cloze", "scramble", "mcq_nuance"})
QUEUE_KINDS = frozenset({"new", "review", "archived"})


def validate_quiz_type(quiz_type: str) -> str:
    if quiz_type not in QUIZ_TYPES:
        raise ValueError(f"Invalid quiz_type: {quiz_type}")
    return quiz_type
