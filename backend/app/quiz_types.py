"""Quiz type constants."""

from __future__ import annotations

QUIZ_TYPES = frozenset({"cloze", "scramble", "mcq_nuance", "composition"})
QUEUE_KINDS = frozenset({"new", "review", "archived"})

# Only composition is currently servable; the other types stay in QUIZ_TYPES so
# existing rows, queue counts, and schemas keep working while their UI is hidden.
ENABLED_QUIZ_TYPES = frozenset({"composition"})


def validate_quiz_type(quiz_type: str) -> str:
    if quiz_type not in QUIZ_TYPES:
        raise ValueError(f"Invalid quiz_type: {quiz_type}")
    return quiz_type


def ensure_quiz_type_enabled(quiz_type: str) -> str:
    if quiz_type not in ENABLED_QUIZ_TYPES:
        raise ValueError(f"Disabled quiz_type: {quiz_type}")
    return quiz_type
