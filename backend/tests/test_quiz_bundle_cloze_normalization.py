import pytest

from app.quiz_bundle import _is_teachable_cloze, _normalize_bundle_cloze
from app.quiz_generator import validate_quiz_payload


def test_normalizes_legacy_underscore_run_and_requires_a_korean_meaning() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_target": "I carried out a task to ______ the findings.",
            "blank": "validate",
            "sentence_ko": "결과를 검증하는 작업을 수행했습니다.",
            "target_ko": "검증",
        },
        language="english",
    )

    assert result == (
        "I carried out a task to validate the findings.",
        "I carried out a task to ___ the findings.",
        "validate",
        "결과를 <span color='#FFA500'>검증</span>하는 작업을 수행했습니다.",
    )


def test_normalizes_two_character_model_placeholder() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "Ich habe die Berichte __.",
            "blank": "sorgfältig verglichen",
            "sentence_ko": "\ubcf4\uace0\uc11c\ub97c \uaf3c\uaf3c\ud788 \ube44\uad50\ud588\ub2e4.",
            "target_ko": "\uaf3c\uaf3c\ud788 \ube44\uad50\ud588\ub2e4",
        },
        language="german",
    )

    assert result is not None
    assert result[0] == "Ich habe die Berichte sorgfältig verglichen."
    assert result[1] == "Ich habe die Berichte ___."


def test_rejects_target_language_text_in_korean_alignment_field() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "Ich habe die Berichte sorgfältig verglichen.",
            "blank": "sorgfältig verglichen",
            "sentence_ko": "\ubcf4\uace0\uc11c\ub97c ______\ud588\ub2e4.",
            "target_ko": "sorgfältig vergleichen",
        },
        language="german",
    )

    assert result is None


def test_rejects_native_sentence_with_target_language_answer() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_target": "평가 매뉴얼을 ______하고 있습니다.",
            "blank": "understand",
            "sentence_ko": "평가 매뉴얼을 이해하고 있습니다.",
            "target_ko": "이해",
        },
        language="english",
    )

    assert result is None


def test_rejects_generic_korean_context_without_a_real_meaning() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "Please check out the revised report.",
            "prompt_en": "Please ___ the revised report.",
            "blank": "check out",
            "sentence_ko": "이것은 일반적인 표현입니다.",
            "target_ko": "표현",
        },
        language="english",
    )

    assert result is None


def test_missing_target_alignment_is_rejected_instead_of_highlighting_everything() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "You can inspect the screen on the webpage.",
            "blank": "on the webpage",
            "sentence_ko": "웹페이지에서 화면을 확인할 수 있습니다.",
            "target_ko": "",
        },
        language="english",
    )

    assert result is None


def test_normalized_cloze_passes_the_production_validator() -> None:
    sentence_en, prompt_en, blank, context_ko = _normalize_bundle_cloze(
        {
            "sentence_en": "I need to compare the results before submitting the report.",
            "prompt_en": "I need to ___ the results before submitting the report.",
            "blank": "compare",
            "sentence_ko": "보고서를 제출하기 전에 결과를 비교해야 합니다.",
            "target_ko": "비교",
        },
        language="english",
    )

    validated = validate_quiz_payload(
        "cloze",
        {
            "question_ko": "빈칸에 들어갈 표현을 입력해 보세요.",
            "sentence_en": sentence_en,
            "quiz_data": {
                "prompt_en": prompt_en,
                "blank": blank,
                "accepted_answers": [blank],
                "context_ko": context_ko,
            },
        },
        target_level=20,
        target_language="english",
    )

    assert validated["quiz_data"]["sentence_en_complete"] == sentence_en


def test_rebuilds_a_safe_prompt_from_the_complete_sentence() -> None:
    sentence_en, prompt_en, _, _ = _normalize_bundle_cloze(
        {
            "sentence_en": "The platform has eight drivers.",
            "prompt_en": "The platform has ___ eight drivers.",
            "blank": "eight",
            "sentence_ko": "해당 플랫폼에는 8개의 드라이버가 있다.",
            "target_ko": "8개",
        },
        language="english",
    )

    assert sentence_en == "The platform has eight drivers."
    assert prompt_en == "The platform has ___ drivers."


def test_restores_one_native_placeholder_from_explicit_target_translation() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "I carefully compared the two reports.",
            "blank": "carefully compared",
            "sentence_ko": "\ub450 \ubcf4\uace0\uc11c\ub97c ______\ud588\ub2e4.",
            "target_ko": "\uaf3c\uaf3c\ud788 \ube44\uad50",
        },
        language="english",
    )

    assert result is not None
    assert result[3] == (
        "\ub450 \ubcf4\uace0\uc11c\ub97c "
        "<span color='#FFA500'>\uaf3c\uaf3c\ud788 \ube44\uad50</span>\ud588\ub2e4."
    )


def test_rejects_a_completed_sentence_that_contains_the_answer_twice() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "The platform has ____ eight drivers.",
            "blank": "eight",
            "sentence_ko": "해당 플랫폼에는 8개의 드라이버가 있다.",
            "target_ko": "8개",
        },
        language="english",
    )

    assert result is None


def test_rejects_numbers_function_words_and_word_fragments_as_clozes() -> None:
    assert not _is_teachable_cloze("eight", language="english")
    assert not _is_teachable_cloze("has", language="english")
    assert not _is_teachable_cloze("sub", language="english")
    assert not _is_teachable_cloze("the two reports", language="english")
    assert not _is_teachable_cloze("their key results", language="english")
    assert _is_teachable_cloze("key results", language="english")
    assert _is_teachable_cloze("check out", language="english")


def test_production_validator_rejects_a_prompt_that_leaks_the_answer() -> None:
    with pytest.raises(ValueError, match="leaks the answer"):
        validate_quiz_payload(
            "cloze",
            {
                "sentence_en": "The platform has eight drivers.",
                "quiz_data": {
                    "prompt_en": "The platform has ___ eight drivers.",
                    "blank": "eight",
                    "accepted_answers": ["eight"],
                    "context_ko": "플랫폼에는 <span color='#FFA500'>8개</span>의 드라이버가 있다.",
                },
            },
            target_level=20,
            target_language="english",
        )


def test_german_unicode_cloze_survives_normalization_and_validation() -> None:
    sentence, prompt, blank, context = _normalize_bundle_cloze(
        {
            "sentence_en": "Berücksichtigen Sie alle relevanten Faktoren.",
            "blank": "Berücksichtigen",
            "sentence_ko": "모든 관련 요소를 고려하세요.",
            "target_ko": "고려하세요",
        },
        language="german",
    )

    validated = validate_quiz_payload(
        "cloze",
        {
            "question_ko": "빈칸을 완성하세요.",
            "sentence_en": sentence,
            "quiz_data": {
                "prompt_en": prompt,
                "blank": blank,
                "accepted_answers": [blank],
                "context_ko": context,
            },
        },
        target_level=45,
        target_language="german",
    )

    assert validated["quiz_data"]["prompt_en"] == "___ Sie alle relevanten Faktoren."
