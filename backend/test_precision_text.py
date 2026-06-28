"""Tests for precision text journal pipeline helpers."""

import uuid
from unittest.mock import AsyncMock, MagicMock

from app.precision_text import (
    dialogue_to_transcript,
    is_precision_text_entry,
    normalize_dialogue,
    resolve_text_speaker_context,
)


def test_normalize_dialogue_filters_ignore_and_empty():
    lines = normalize_dialogue(
        [
            {"speaker": "나", "text": "안녕하세요"},
            {"speaker": "무시", "text": "광고 문구"},
            {"speaker": "면접관", "text": "   "},
            {"speaker": "면접관", "text": "반갑습니다"},
        ]
    )
    assert len(lines) == 2
    assert lines[0]["speaker"] == "나"
    assert lines[1]["text"] == "반갑습니다"


def test_normalize_dialogue_requires_content():
    try:
        normalize_dialogue([{"speaker": "나", "text": "   "}])
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_dialogue_to_transcript():
    text = dialogue_to_transcript(
        [{"speaker": "나", "text": "hello"}, {"speaker": "면접관", "text": "hi"}]
    )
    assert "[나]" in text
    assert "[면접관]" in text


def test_is_precision_text_entry_from_trace():
    entry = MagicMock()
    entry.audio_url = None
    entry.pipeline_trace = {"entry_source": "precision_text"}
    entry.transcript_segments = [{"speaker": "나", "text": "x"}]
    assert is_precision_text_entry(entry) is True


def test_is_precision_text_entry_rejects_speaker_n_labels():
    entry = MagicMock()
    entry.audio_url = None
    entry.pipeline_trace = {}
    entry.transcript_segments = [{"speaker": "Speaker_1", "text": "x"}]
    assert is_precision_text_entry(entry) is False


async def test_resolve_text_speaker_context():
    user_id = uuid.uuid4()
    entry = MagicMock()
    entry.transcript_segments = [
        {"speaker": "나", "text": "안녕"},
        {"speaker": "면접관", "text": "네"},
        {"speaker": "나", "text": "감사합니다"},
    ]
    session = AsyncMock()
    ctx = await resolve_text_speaker_context(session, entry, user_id)
    assert ctx["confirmed_speaker_count"] == 2
    assert ctx["entry_source"] == "precision_text"


if __name__ == "__main__":
    test_normalize_dialogue_filters_ignore_and_empty()
    test_normalize_dialogue_requires_content()
    test_dialogue_to_transcript()
    test_is_precision_text_entry_from_trace()
    test_is_precision_text_entry_rejects_speaker_n_labels()
    import asyncio

    asyncio.run(test_resolve_text_speaker_context())
    print("OK precision text tests")
