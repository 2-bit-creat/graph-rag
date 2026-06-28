"""E2E stub — full generate flow requires DB + OpenAI."""

from app.quiz_types import validate_quiz_type


def test_quiz_type_validation():
    assert validate_quiz_type("cloze") == "cloze"
    assert validate_quiz_type("scramble") == "scramble"
    assert validate_quiz_type("mcq_nuance") == "mcq_nuance"
