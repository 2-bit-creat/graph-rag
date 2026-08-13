"""The coverage guard must not buy a second extraction for nothing.

The repair call is a full re-extraction — the largest single item in the graph
draft's latency (measured 10–42 s per draft, all of it output tokens). Two
sources of false alarms made it fire on entries that had lost nothing:

1. Speaker labels. The coverage source is the speaker-labeled transcript
   ("[박병준]: 출근완"), while a claim's statement never contains the label — it
   lives on `claim["speaker"]`. On short chat turns the label is a large share of
   the characters, so every multi-speaker entry scored as lossy.
2. Laughter and acknowledgements. "ㅋㅋㅋ", "ㅇㅇ", "ㅎㅎ" carry no proposition,
   so folding them into a neighbouring turn drops nothing.

Genuine loss must still be repaired — see test_kg_extraction_coverage.py.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from app.routers import kg_build

# The pasted group-chat entry that took 42 s to draft.
CHAT_LOG = "\n".join(
    [
        "[박병준]: 투표 늦게해서 미안타~~~",
        "[박병준]: 중복도 되는거였네 하지만 난 소신을 지키겠음",
        "[박병준]: 근데 워터파크도 좋음 ㅎㅎ",
        "[박의준]: ㅋㅋㅋ",
        "[박의준]: 고럼 계곡으로 가는구마 ㅎㅎ",
        "[이영호]: 좋다..의준승현이다하네..",
        "[이영호]: 출근완",
        "[박의준]: 운동완",
        "[박의준]: 가보자고",
    ]
)


def _claim(speaker: str, statement: str) -> dict:
    return {"speaker": speaker, "title": statement[:12], "statement": statement, "concepts": []}


FAITHFUL = {
    "claims": [
        _claim("박병준", "투표 늦게해서 미안타~~~"),
        _claim("박병준", "중복도 되는거였네 하지만 난 소신을 지키겠음."),
        _claim("박병준", "근데 워터파크도 좋음 ㅎㅎ."),
        _claim("박의준", "고럼 계곡으로 가는구마 ㅎㅎ."),
        _claim("이영호", "좋다.. 의준 승현이다 하네.."),
        _claim("이영호", "출근 완료."),
        _claim("박의준", "운동 완료."),
        _claim("박의준", "가보자고."),
    ]
}


class _Completions:
    def __init__(self, responses: list[dict]) -> None:
        self.responses = responses
        self.calls: list[dict] = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(
            choices=[
                SimpleNamespace(
                    message=SimpleNamespace(content=json.dumps(self.responses.pop(0))),
                    finish_reason="stop",
                )
            ]
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


def test_speaker_labels_are_not_scored_as_lost_content() -> None:
    report = kg_build._coverage_report(CHAT_LOG, FAITHFUL)
    assert report is not None
    assert report["uncovered"] == [], report["uncovered"]
    assert report["score"] >= kg_build.get_settings().kg_extract_coverage_min


def test_laughter_only_turn_is_reported_but_never_repaired() -> None:
    """"ㅋㅋㅋ" folded into the next claim is not a loss — but it stays visible."""
    dropped = {"claims": [c for c in FAITHFUL["claims"] if "계곡" not in c["statement"]]}
    report = kg_build._coverage_report(CHAT_LOG, dropped)
    assert report is not None
    # The real sentence is missing; the interjection turn is only 'ignored'.
    assert any("계곡" in unit for unit in report["uncovered"])
    assert "ㅋㅋㅋ" not in " ".join(report["uncovered"])


def test_filler_classification() -> None:
    for unit in ["[박의준]: ㅋㅋㅋ", "ㅎㅎ", "ㅇㅇ", "네", "...", "😀", "lol"]:
        assert not kg_build._is_propositional(unit), unit
    for unit in ["[이영호]: 출근완", "운동완", "가보자고", "워터파크도 좋음"]:
        assert kg_build._is_propositional(unit), unit


@pytest.mark.asyncio
async def test_faithful_chat_extraction_costs_no_repair_call(fake_llm) -> None:
    completions = fake_llm([])
    result, coverage = await kg_build._ensure_source_coverage(
        source=CHAT_LOG,
        result=FAITHFUL,
        raw=json.dumps(FAITHFUL),
        system_prompt="sys",
        user_prompt="usr",
        native_language="korean",
        model="gpt-test",
    )
    assert completions.calls == [], "a faithful draft must not pay for a second extraction"
    assert result is FAITHFUL
    assert coverage["uncovered"] == []


@pytest.mark.asyncio
async def test_dropped_chat_turn_is_still_repaired(fake_llm) -> None:
    lossy = {"claims": FAITHFUL["claims"][:3]}
    completions = fake_llm([FAITHFUL])
    result, coverage = await kg_build._ensure_source_coverage(
        source=CHAT_LOG,
        result=lossy,
        raw=json.dumps(lossy),
        system_prompt="sys",
        user_prompt="usr",
        native_language="korean",
        model="gpt-test",
    )
    assert len(completions.calls) == 1
    assert coverage["repaired"] is True
    assert len(result["claims"]) == len(FAITHFUL["claims"])
    assert isinstance(coverage["repair_ms"], int)


def test_matched_flags_are_not_asked_of_the_model() -> None:
    """They are overwritten from the DB, so paying decode tokens for them is waste."""
    schema = kg_build._EXTRACTION_RESPONSE_FORMAT["json_schema"]["schema"]
    claim = schema["properties"]["claims"]["items"]
    assert "speaker_matched" not in claim["properties"]
    assert "concepts_matched" not in claim["properties"]
    # strict structured outputs demand required == properties.
    assert set(claim["required"]) == set(claim["properties"])

    prompt = kg_build._build_extraction_system_prompt(
        content_type="대화", fixed_speaker=None, native_language="korean"
    )
    assert "speaker_matched" not in prompt
    assert "concepts_matched" not in prompt
