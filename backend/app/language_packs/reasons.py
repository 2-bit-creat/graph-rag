"""Closed set of deterministic quiz-quality gate reason codes.

Every gate function in this package returns either ``None`` (pass) or a
string of the form ``"<code>: <human message>"``. The codes below are the
vocabulary shared by three consumers that must agree on the same names:

- the deterministic gates themselves (``language_packs.base`` / the
  target-specific packs), which decide whether a candidate card survives;
- the repair feedback handed back to the cloze-author LLM, which already
  expects short machine-readable codes (``_build_cloze_qa_system_prompt`` in
  ``quiz_bundle.py`` asks the reviewer for codes like ``answer_boundary`` and
  ``sibling_expression_leak``); and
- the offline eval harness (``scripts/quiz_eval.py``), which histograms
  rejections by code across a run so a regression or an improvement is
  visible as a bucket moving, not just a headline pass-rate number.

Keeping the vocabulary here (rather than inventing a string per call site)
means a code can never quietly drift between what a gate reports and what the
eval harness expects to see.
"""

from __future__ import annotations

# Structural / cross-language codes — apply to any target or native pack.
ENTITY_LEAK = "entity_leak"
ANSWER_NOT_CONTIGUOUS = "answer_not_contiguous"
NATIVE_TARGET_MISALIGNMENT = "native_target_misalignment"
NATIVE_TRANSLATION_MISSING = "native_translation_missing"
NATIVE_GENERIC_FILLER = "native_generic_filler"
TAUTOLOGY = "tautology"
SENTENCE_TOO_SHORT = "sentence_too_short"
NOT_TEACHABLE = "not_teachable"
LEADING_DETERMINER = "leading_determiner"
INTERNAL_POSSESSIVE = "internal_possessive"
FUNCTION_WORD_ANSWER = "function_word_answer"
NOT_BASE_FORM = "not_base_form"
SIBLING_JOIN = "sibling_join"
CLAUSE_ANSWER = "clause_answer"
TOO_LONG = "too_long"
PROPER_NAME = "proper_name"
WRONG_LANGUAGE = "wrong_language"

# English-specific.
EN_INFLECTED_FIRST_WORD = "en_inflected_first_word"

# German-specific.
DE_NOT_INFINITIVE = "de_not_infinitive"
DE_SEPARABLE_SPLIT = "de_separable_split"
DE_CASE_DRIFT = "de_case_drift"
DE_ALL_CAPS_NAME = "de_all_caps_name"

# Korean-specific.
KO_PARTICLE_BOUNDARY = "ko_particle_boundary"
KO_NOT_DICTIONARY_FORM = "ko_not_dictionary_form"
KO_FUNCTION_WORD_ONLY = "ko_function_word_only"
KO_CLAUSE_ANSWER = "ko_clause_answer"
KO_SPACING = "ko_spacing"

ALL_CODES = frozenset({
    ENTITY_LEAK, ANSWER_NOT_CONTIGUOUS, NATIVE_TARGET_MISALIGNMENT,
    NATIVE_TRANSLATION_MISSING, NATIVE_GENERIC_FILLER, TAUTOLOGY,
    SENTENCE_TOO_SHORT, NOT_TEACHABLE, LEADING_DETERMINER, INTERNAL_POSSESSIVE,
    FUNCTION_WORD_ANSWER, NOT_BASE_FORM, SIBLING_JOIN, CLAUSE_ANSWER,
    TOO_LONG, PROPER_NAME, WRONG_LANGUAGE, EN_INFLECTED_FIRST_WORD,
    DE_NOT_INFINITIVE, DE_SEPARABLE_SPLIT, DE_CASE_DRIFT, DE_ALL_CAPS_NAME,
    KO_PARTICLE_BOUNDARY, KO_NOT_DICTIONARY_FORM, KO_FUNCTION_WORD_ONLY,
    KO_CLAUSE_ANSWER, KO_SPACING,
})


def reason(code: str, message: str) -> str:
    """Build a ``"<code>: <message>"`` gate-rejection string.

    Every gate should return this shape (or ``None``) rather than a bare
    message, so ``split_reason`` can always recover the code for metrics.
    """
    if code not in ALL_CODES:
        raise ValueError(f"unknown gate reason code {code!r}; add it to ALL_CODES")
    return f"{code}: {message}"


def split_reason(value: str | None) -> tuple[str | None, str]:
    """Recover ``(code, message)`` from a gate-rejection string.

    Tolerates legacy free-text reasons (no ``code: `` prefix, or a prefix
    that collides with a random ``:`` in the message) by returning
    ``(None, value)`` — the eval harness buckets those under an explicit
    ``"uncoded"`` group rather than mis-attributing them to a real code.
    """
    if not value:
        return None, ""
    prefix, sep, rest = value.partition(": ")
    if sep and prefix in ALL_CODES:
        return prefix, rest
    return None, value
