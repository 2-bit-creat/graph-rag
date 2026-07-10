"""Quiz prompt helpers respect target/native language parameters."""

from __future__ import annotations

from app.level_guidelines import level_prompt_context
from app.quiz_generator import (
    _build_system_prompt,
    _default_question_ko,
    _mcq_nuance_distractor_rules,
    _strict_fact_based_prompt,
    _vocab_context_cloze_prompt,
)


def test_level_prompt_context_german():
    ctx = level_prompt_context(50, target_language="german")
    assert "German" in ctx
    assert "English sentence" not in ctx


def test_default_question_english_native():
    q = _default_question_ko("cloze", "german", native_language="english")
    assert "German" in q or "Deutsch" in q
    assert "독일어" not in q


def test_mcq_distractor_rules_target_label():
    rules = _mcq_nuance_distractor_rules(target_label="Korean")
    assert "Korean" in rules
    assert "English options" not in rules


def test_strict_fact_prompt_korean_target():
    prompt = _strict_fact_based_prompt("scramble", target_language="korean")
    assert "Korean" in prompt


def test_build_system_prompt_includes_both_languages():
    prompt = _build_system_prompt(
        "cloze",
        30,
        "graph",
        native_language="english",
        target_language="german",
    )
    assert "English" in prompt
    assert "German" in prompt


def test_vocab_cloze_prompt_native_english():
    prompt = _vocab_context_cloze_prompt(native_language="english", target_language="korean")
    assert "English" in prompt
    assert "Korean" in prompt
