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
    statement = next(item for item in _load_golden({CASE_ID}) if item["native"] == "korean")
    bad = [{
        "quiz_type": "cloze",
        "surface_answer": "a conservative discount rate",
        "target_native": "보수적으로",
    }]
    good = [{
        "quiz_type": "cloze",
        "surface_answer": "a conservative discount rate",
        "target_native": "보수적인 할인율을 적용하고 있다",
    }]
    assert _check_golden_expectation(statement, bad)["passed"] is False
    assert _check_golden_expectation(statement, good)["passed"] is True


def test_english_to_korean_golden_requires_full_financial_noun_phrase() -> None:
    statement = next(item for item in _load_golden({CASE_ID}) if item["native"] == "english")
    bad = [{
        "quiz_type": "cloze",
        "surface_answer": "보수적으로",
        "target_native": "conservatively",
    }]
    good = [{
        "quiz_type": "cloze",
        "surface_answer": "보수적인 할인율을 적용하고 있다",
        "target_native": "is applying a conservative discount rate",
    }]
    assert _check_golden_expectation(statement, bad)["passed"] is False
    assert _check_golden_expectation(statement, good)["passed"] is True


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
