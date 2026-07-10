"""apply_cleaned_text_to_segments maps STT-corrected wording back onto segments."""

from __future__ import annotations

from app.journal_pipeline import apply_cleaned_text_to_segments


def _segs():
    return [
        {"speaker": "Speaker_1", "text": "저는 마차를 만들었어요.", "start_sec": 0.0},
        {"speaker": "Speaker_2", "text": "저는 마차를 마실 거예요.", "start_sec": 2.0},
    ]


def test_sentence_fallback_when_labels_dropped():
    # Cleaned transcript lost speaker labels and merged into one line (the real bug).
    clean = "저는 말차를 만들었어요. 저는 말차를 마실 거예요."
    out = apply_cleaned_text_to_segments(_segs(), clean)
    assert out[0]["text"] == "저는 말차를 만들었어요."
    assert out[1]["text"] == "저는 말차를 마실 거예요."
    # Original preserved.
    assert out[0]["text_raw"] == "저는 마차를 만들었어요."


def test_labeled_lines_mapping():
    clean = "[Speaker_1] 저는 말차를 만들었어요.\n[Speaker_2] 저는 말차를 마실 거예요."
    out = apply_cleaned_text_to_segments(_segs(), clean)
    assert out[0]["text"] == "저는 말차를 만들었어요."
    assert out[1]["text"] == "저는 말차를 마실 거예요."


def test_no_remap_when_counts_mismatch():
    # 3 cleaned sentences but 2 segments → cannot map safely → keep raw.
    clean = "문장 하나. 문장 둘. 문장 셋."
    out = apply_cleaned_text_to_segments(_segs(), clean)
    assert out[0]["text"] == "저는 마차를 만들었어요."  # unchanged
    assert "text_raw" not in out[0]


def test_empty_inputs_are_safe():
    assert apply_cleaned_text_to_segments([], "anything") == []
    segs = _segs()
    assert apply_cleaned_text_to_segments(segs, "") == segs
