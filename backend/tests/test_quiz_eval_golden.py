"""Semantic golden contracts for learner-facing quiz translations."""

from scripts.quiz_eval import (
    _accumulate_usage,
    _check_golden_expectation,
    _estimated_usage_cost,
    _load_golden,
)


CASE_ID = "polysemy-conservative-rate-001"


def test_one_quality_case_id_selects_both_language_directions() -> None:
    statements = _load_golden({CASE_ID})
    assert {(item["native"], item["id"]) for item in statements} == {
        ("korean", "ko-025"),
        ("english", "en-013"),
    }


def test_korean_to_english_golden_rejects_adverb_only_gloss() -> None:
    # scramble/composition views: question_native is the untranslated Korean
    # source (never model-generated), so only the English TARGET text can
    # signal a quality regression here — a translation that collapses the
    # noun phrase "conservative discount rate" into a bare adverb.
    statement = next(item for item in _load_golden({CASE_ID}) if item["native"] == "korean")
    bad = [{
        "quiz_type": "composition",
        "model_answers": ["He acted conservatively because of the uncertainty."],
    }]
    good = [{
        "quiz_type": "composition",
        "model_answers": ["He is applying a conservative discount rate to account for uncertainty."],
    }]
    assert _check_golden_expectation(statement, bad)["passed"] is False
    assert _check_golden_expectation(statement, good)["passed"] is True


def test_english_to_korean_golden_requires_full_financial_noun_phrase() -> None:
    statement = next(item for item in _load_golden({CASE_ID}) if item["native"] == "english")
    bad = [{
        "quiz_type": "composition",
        "model_answers": ["그는 불확실성 때문에 보수적으로 행동하고 있다."],
    }]
    good = [{
        "quiz_type": "composition",
        "model_answers": ["그는 불확실성을 고려하기 위해 보수적인 할인율을 적용하고 있다."],
    }]
    assert _check_golden_expectation(statement, bad, target_language="korean")["passed"] is False
    assert _check_golden_expectation(statement, good, target_language="korean")["passed"] is True


def test_target_contains_accepts_any_synonym_in_a_group() -> None:
    # ko-025's german expectation lists "diskontsatz"/"abzinsungssatz" as
    # interchangeable domain terms for "discount rate" — either satisfies it.
    statement = next(
        item for item in _load_golden({CASE_ID}) if item["native"] == "korean"
    )
    abzinsungssatz = [{
        "quiz_type": "scramble",
        "sentence_target": "Er wendet einen konservativen Abzinsungssatz an.",
    }]
    diskontsatz = [{
        "quiz_type": "scramble",
        "sentence_target": "Er wendet einen konservativen Diskontsatz an.",
    }]
    neither = [{
        "quiz_type": "scramble",
        "sentence_target": "Er wendet einen konservativen Zinssatz an.",
    }]
    assert _check_golden_expectation(statement, abzinsungssatz, target_language="german")["passed"] is True
    assert _check_golden_expectation(statement, diskontsatz, target_language="german")["passed"] is True
    assert _check_golden_expectation(statement, neither, target_language="german")["passed"] is False


def test_null_expect_cloze_skips_the_check() -> None:
    # ko-028's expect_cloze is deliberately null: the possessive-in-isolated-
    # blank concern it encoded doesn't apply once scramble/composition always
    # show the full sentence (and its subject) together.
    golden = _load_golden(None)
    statement = next(item for item in golden if item["id"] == "ko-028")
    views = [{
        "quiz_type": "composition",
        "model_answers": ["Er überarbeitete in seiner freien Zeit seine Präsentationsunterlagen."],
    }]
    assert _check_golden_expectation(statement, views, target_language="german") is None


def test_usage_accounting_includes_review_repair_and_cache_details() -> None:
    totals = {
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "cached_prompt_tokens": 0,
        "reasoning_tokens": 0,
        "by_model": {},
    }
    _accumulate_usage({
        "review": {"prompt_tokens": 100, "completion_tokens": 20, "cached_prompt_tokens": 80},
        "repair": [{"prompt_tokens": 40, "completion_tokens": 10, "reasoning_tokens": 4}],
    }, totals, model="quality-model")
    assert totals["prompt_tokens"] == 140
    assert totals["completion_tokens"] == 30
    assert totals["cached_prompt_tokens"] == 80
    assert totals["reasoning_tokens"] == 4
    assert totals["by_model"]["quality-model"]["prompt_tokens"] == 140


def test_usage_cost_prices_cached_tokens_only_once() -> None:
    cost, by_model = _estimated_usage_cost({
        "by_model": {
            "gpt-5.4-mini": {
                "prompt_tokens": 1_000_000,
                "cached_prompt_tokens": 600_000,
                "completion_tokens": 100_000,
            }
        }
    })
    # 400k uncached input + 600k cached input + 100k output.
    assert cost == 0.795
    assert by_model == {"gpt-5.4-mini": 0.795}


def test_usage_cost_refuses_to_guess_unknown_model_price() -> None:
    assert _estimated_usage_cost({"by_model": {"future-model": {}}}) == (None, {})
