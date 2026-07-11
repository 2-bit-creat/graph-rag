"""Quiz type constants."""

from __future__ import annotations

QUIZ_TYPES = frozenset({"cloze", "scramble", "mcq_nuance", "composition"})
QUEUE_KINDS = frozenset({"new", "review", "archived"})

# All four types are servable. They are generated together as a bundle from a
# single Statement (see quiz_bundle.py) and queued per target language.
ENABLED_QUIZ_TYPES = frozenset({"cloze", "scramble", "mcq_nuance", "composition"})


def validate_quiz_type(quiz_type: str) -> str:
    if quiz_type not in QUIZ_TYPES:
        raise ValueError(f"Invalid quiz_type: {quiz_type}")
    return quiz_type


def ensure_quiz_type_enabled(quiz_type: str) -> str:
    if quiz_type not in ENABLED_QUIZ_TYPES:
        raise ValueError(f"Disabled quiz_type: {quiz_type}")
    return quiz_type
