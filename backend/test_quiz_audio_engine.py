"""Quiz audio engine unit checks."""

import asyncio
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from app.quiz_audio_engine import (
    build_complete_cloze_sentence,
    quiz_audio_relative_path,
    resolve_quiz_tts_text,
    synthesize_quiz_audio,
)


def test_quiz_audio_relative_path():
    qid = uuid.UUID("12345678-1234-5678-1234-567812345678")
    assert quiz_audio_relative_path(qid) == (
        "/static/audio/12345678-1234-5678-1234-567812345678.mp3"
    )


def test_build_complete_cloze_sentence():
    qd = {
        "prompt_en": "Jennifer carefully placed the matcha ___ the table.",
        "blank": "onto",
    }
    assert build_complete_cloze_sentence(qd, "onto") == (
        "Jennifer carefully placed the matcha onto the table."
    )


def test_resolve_quiz_tts_text_cloze():
    validated = {
        "sentence_en": "Jennifer carefully placed the matcha ___ the table.",
        "quiz_data": {
            "prompt_en": "Jennifer carefully placed the matcha ___ the table.",
            "blank": "onto",
            "accepted_answers": ["onto"],
        },
    }
    assert resolve_quiz_tts_text("cloze", validated) == (
        "Jennifer carefully placed the matcha onto the table."
    )


def test_synthesize_writes_and_returns_path(tmp_path):
    qid = uuid.uuid4()

    async def _run():
        with patch("app.quiz_audio_engine.AUDIO_DIR", tmp_path):
            mock_comm = MagicMock()
            mock_comm.save = AsyncMock(
                side_effect=lambda p: Path(p).write_bytes(b"x" * 600)
            )
            with patch("edge_tts.Communicate", return_value=mock_comm) as mock_ctor:
                url, err = await synthesize_quiz_audio(qid, "Hello world")
        assert url == f"/static/audio/{qid}.mp3"
        assert err is None
        mock_ctor.assert_called_once()
        mock_comm.save.assert_awaited_once()

    asyncio.run(_run())


def test_synthesize_empty_text_returns_none():
    url, err = asyncio.run(synthesize_quiz_audio(uuid.uuid4(), "   "))
    assert url is None
    assert err == "empty sentence_en"
