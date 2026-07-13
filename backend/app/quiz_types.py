"""Quiz type constants."""

from __future__ import annotations

QUIZ_TYPES = frozenset({"cloze", "composition"})
QUEUE_KINDS = frozenset({"new", "review", "archived"})

ENABLED_QUIZ_TYPES = frozenset({"cloze", "composition"})


def validate_quiz_type(quiz_type: str) -> str:
    if quiz_type not in QUIZ_TYPES:
        raise ValueError(f"Invalid quiz_type: {quiz_type}")
    return quiz_type


def ensure_quiz_type_enabled(quiz_type: str) -> str:
    if quiz_type not in ENABLED_QUIZ_TYPES:
        raise ValueError(f"Disabled quiz_type: {quiz_type}")
    return quiz_type
