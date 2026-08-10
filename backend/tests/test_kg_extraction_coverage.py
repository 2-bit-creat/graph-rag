"""The extractor must not silently drop sentences from a diary entry.

The regression this guards: a four-sentence entry about running out of tethering
data came back as a single claim whose statement was only the FIRST sentence.
The "80% of 2GB" and "it's only 11am" facts never reached the review screen, so
they never reached the graph and the user was never told anything was missing.

Two independent defences are tested here — the prompt that asks for full
coverage, and the deterministic check that does not trust the answer.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from app.routers import kg_build

# The actual entry that exposed the bug.
DIARY = (
    "클로드에게 프롬프트로 UI를 개선하는 작업을 하고 있었는데 해당 채팅 컨텍스트에 "
    "너무 많은 이미지 정보가 있어서 데이터를 짧은 시간에 상당히 많이 소진해버렸어. "
    "그래서 지금 테더링 한도 데이터 2GB의 80% 넘게 벌써 써 버렸어. "
    "아직 오전 11시 정도인데도 불구하고"
)

LOSSY = {
    "claims": [{
        "speaker": "나",
        "title": "클로드 UI 작업 중 데이터 소진",
        "statement": (
            "클로드에게 프롬프트로 UI를 개선하는 작업을 하고 있었는데 해당 채팅 "
            "컨텍스트에 너무 많은 이미지 정보가 있어서 데이터를 짧은 시간에 상당히 "
            "많이 소진해버렸다."
        ),
        "concepts": [],
    }]
}

COMPLETE = {
    "claims": [
        LOSSY["claims"][0],
        {
            "speaker": "나",
            "title": "테더링 한도 80% 초과 사용",
            "statement": (
                "그래서 지금 테더링 한도 데이터 2GB의 80% 넘게 벌써 써 버렸다. "
                "아직 오전 11시 정도인데도 불구하고."
            ),
            "concepts": [],
        },
    ]
}


class _Completions:
    """Same fake-client shape tests/test_quiz_bundle_repair_loop.py uses."""

    def __init__(self, responses: list[dict]) -> None:
        self.responses = responses
        self.calls: list[dict] = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(
            choices=[SimpleNamespace(
                message=SimpleNamespace(content=json.dumps(self.responses.pop(0))),
                finish_reason="stop",
            )]
        )


@pytest.fixture
def fake_llm(monkeypatch):
    def install(responses: list[dict]) -> _Completions:
        completions = _Completions(responses)
        monkeypatch.setattr(
            kg_build,
            "_llm_client",
            lambda: SimpleNamespace(chat=SimpleNamespace(completions=completions)),
        )
        return completions

    return install


# ── The deterministic measurement ─────────────────────────────────────────────

def test_coverage_report_names_the_dropped_sentences() -> None:
    report = kg_build._coverage_report(DIARY, LOSSY)
    assert report is not None
    assert report["score"] < kg_build.get_settings().kg_extract_coverage_min
    uncovered = " ".join(report["uncovered"])
    assert "80%" in uncovered
    assert "오전 11시" in uncovered
    # The sentence that DID survive must not be reported as missing.
    assert "이미지 정보" not in uncovered


def test_complete_extraction_scores_above_the_threshold() -> None:
    report = kg_build._coverage_report(DIARY, COMPLETE)
    assert report is not None
    assert report["score"] >= kg_build.get_settings().kg_extract_coverage_min
    assert report["uncovered"] == []


def test_short_entries_are_not_scored() -> None:
    """n-gram ratios are noise below kg_extract_coverage_min_chars."""
    assert kg_build._coverage_report("오늘 피곤함", {"claims": []}) is None


# ── The repair loop ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_lossy_extraction_is_repaired(fake_llm) -> None:
    completions = fake_llm([COMPLETE])
    result, coverage = await kg_build._ensure_source_coverage(
        source=DIARY, result=LOSSY, raw=json.dumps(LOSSY),
        system_prompt="sys", user_prompt="usr",
        native_language="korean", model="gpt-test",
    )
    assert len(completions.calls) == 1, "one repair call, not a retry loop"
    assert coverage["repaired"] is True
    assert coverage["uncovered"] == []
    assert len(result["claims"]) == 2

    # The repair must name what was dropped and forbid destroying existing work.
    repair_turn = completions.calls[0]["messages"][-1]["content"]
    assert "80%" in repair_turn
    assert "Do not delete any existing claim" in repair_turn


@pytest.mark.asyncio
async def test_complete_extraction_costs_no_extra_call(fake_llm) -> None:
    completions = fake_llm([])
    result, coverage = await kg_build._ensure_source_coverage(
        source=DIARY, result=COMPLETE, raw=json.dumps(COMPLETE),
        system_prompt="sys", user_prompt="usr",
        native_language="korean", model="gpt-test",
    )
    assert completions.calls == []
    assert result is COMPLETE
    assert coverage["uncovered"] == []


@pytest.mark.asyncio
async def test_regressing_repair_is_rejected(fake_llm) -> None:
    """A model told to add content can restructure and drop something else.
    Keeping the worse answer would make the guard actively harmful."""
    worse = {"claims": [{"speaker": "나", "title": "데이터", "statement": "데이터를 많이 썼다.", "concepts": []}]}
    fake_llm([worse])
    result, coverage = await kg_build._ensure_source_coverage(
        source=DIARY, result=LOSSY, raw=json.dumps(LOSSY),
        system_prompt="sys", user_prompt="usr",
        native_language="korean", model="gpt-test",
    )
    assert result is LOSSY
    assert coverage["repaired"] is False


@pytest.mark.asyncio
async def test_failed_repair_keeps_the_draft(fake_llm, monkeypatch) -> None:
    """A repair that errors must not cost the user the draft they already have."""
    class _Boom:
        async def create(self, **kwargs):
            raise RuntimeError("upstream down")

    monkeypatch.setattr(
        kg_build, "_llm_client",
        lambda: SimpleNamespace(chat=SimpleNamespace(completions=_Boom())),
    )
    result, coverage = await kg_build._ensure_source_coverage(
        source=DIARY, result=LOSSY, raw=json.dumps(LOSSY),
        system_prompt="sys", user_prompt="usr",
        native_language="korean", model="gpt-test",
    )
    assert result is LOSSY
    assert coverage["repaired"] is False
    assert coverage["uncovered"], "the loss stays visible instead of being swallowed"


# ── The prompt ────────────────────────────────────────────────────────────────

def test_extraction_prompt_demands_full_coverage() -> None:
    prompt = kg_build._build_extraction_system_prompt(
        content_type="개인일기", fixed_speaker="나", native_language="korean"
    )
    assert "COVERAGE" in prompt
    assert "exactly one claim" in prompt
    # The two wordings that caused the loss.
    assert "1–2 clean" not in prompt, "the sentence cap truncated claims to their first sentence"
    assert "above all else" not in prompt, "that turned the content-type table into a filter"
    # The table itself must survive — it still decides how claims are split.
    assert "CONTENT-TYPE EXTRACTION FOCUS" in prompt
