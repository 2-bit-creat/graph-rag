"""Tests for cleanup sanity detection (no LLM)."""

from app.journal_pipeline import (
    CLEANUP_SYSTEM_PROMPT,
    _detect_cleanup_anomalies,
    _build_cleanup_correction,
)


def test_prompt_includes_sanity_and_dialogue_rules():
    assert "PHYSICAL & LOGICAL SANITY CHECK" in CLEANUP_SYSTEM_PROMPT
    assert "MULTI-TURN DIALOGUE KEYWORD SYNC" in CLEANUP_SYSTEM_PROMPT
    assert "말차" in CLEANUP_SYSTEM_PROMPT
    assert "drink the carriage" not in CLEANUP_SYSTEM_PROMPT.lower() or "never" in CLEANUP_SYSTEM_PROMPT.lower()


def test_detects_macha_with_drink_verb():
    source = "[제니퍼] 저는 마차를 만들었어요.\n[장세영] 저는 마차를 마실 거예요."
    issues = _detect_cleanup_anomalies(
        source,
        "[제니퍼] 저는 마차를 만들었어요.\n[장세영] 저는 마차를 마실 거예요.",
        "[Jennifer] I made a carriage.\n[Jang Saeyoung] I will drink the carriage.",
    )
    assert any("말차" in i for i in issues)
    assert any("carriage" in i.lower() for i in issues)


def test_no_issue_when_matcha_corrected():
    source = "[제니퍼] 저는 마차를 만들었어요.\n[장세영] 저는 마차를 마실 거예요."
    issues = _detect_cleanup_anomalies(
        source,
        "[제니퍼] 저는 말차를 만들었어요.\n[장세영] 저는 말차를 마실 거예요.",
        "[Jennifer] I made matcha.\n[Jang Saeyoung] I will drink the matcha.",
    )
    assert issues == []


def test_detects_impossible_english_consumption():
    issues = _detect_cleanup_anomalies(
        "테스트",
        "컴퓨터를 먹었어",
        "I ate the computer.",
    )
    assert issues


def test_build_correction_message():
    msg = _build_cleanup_correction(["fix 말차"])
    assert "VALIDATION FAILED" in msg
    assert "말차" in msg


if __name__ == "__main__":
    test_prompt_includes_sanity_and_dialogue_rules()
    test_detects_macha_with_drink_verb()
    test_no_issue_when_matcha_corrected()
    test_detects_impossible_english_consumption()
    test_build_correction_message()
    print("OK")
