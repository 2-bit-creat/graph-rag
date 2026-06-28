"""Speaker diarization refinement + voice matching tests (2-speaker recording)."""

from __future__ import annotations

import asyncio
import sys
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, patch

from app.speaker_diarization import SpeakerSegment, diarize_audio
from app.speaker_profiles import build_llm_transcript_with_speaker_names
from app.speaker_refinement import (
    find_voice_change_boundaries,
    refine_diarization_segments,
    should_refine_diarization,
)

TWO_SPEAKER_WAV = Path(
    __file__).parent / "uploads" / "00000000-0000-0000-0000-000000000001" / (
    "1f6e137b-061a-42d4-8223-70541433f152.wav"
)


def test_should_refine_single_speaker_segment():
    assert TWO_SPEAKER_WAV.exists(), f"missing fixture audio: {TWO_SPEAKER_WAV}"
    segments = [
        SpeakerSegment(
            speaker="Speaker_1",
            start_sec=1.6,
            end_sec=14.34,
            text="제 이름은 제니예요. 그리고 저는 장세형이에요.",
        )
    ]
    assert should_refine_diarization(segments, TWO_SPEAKER_WAV) is True
    print("OK should_refine_single_speaker_segment")


def test_find_voice_change_boundaries_two_speakers():
    boundaries = find_voice_change_boundaries(TWO_SPEAKER_WAV)
    assert boundaries, "expected at least one voice change boundary"
    assert any(8.0 <= b <= 12.0 for b in boundaries), boundaries
    assert len(boundaries) <= 2, boundaries
    print(f"OK find_voice_change_boundaries: {boundaries}")


async def _mock_transcribe(_path: Path, start: float, end: float) -> str:
    if start < 9.0:
        return "제 이름은 제니예요. 그리고 오늘 한국에 도착했어요."
    return "그리고 저는 장세형이에요."


async def test_refine_splits_into_two_speakers():
    segments = [
        SpeakerSegment(
            speaker="Speaker_1",
            start_sec=1.6,
            end_sec=14.34,
            text="제 이름은 제니예요. 그리고 저는 장세형이에요.",
        )
    ]
    with patch(
        "app.speaker_refinement.transcribe_segment",
        new=AsyncMock(side_effect=_mock_transcribe),
    ):
        refined, meta = await refine_diarization_segments(TWO_SPEAKER_WAV, segments)

    assert meta.get("refined") is True, meta
    assert len(refined) >= 2, refined
    labels = {seg.speaker for seg in refined}
    assert len(labels) >= 2, labels
    assert any("제니" in seg.text for seg in refined)
    assert any("장세" in seg.text for seg in refined)
    print(f"OK refine_splits_into_two_speakers: {[s.to_dict() for s in refined]}")


async def test_build_llm_transcript_substitutes_known_speaker():
    node_id = uuid.uuid4()
    profile_id = uuid.uuid4()

    class FakeNode:
        def __init__(self):
            self.id = node_id
            self.user_id = uuid.UUID("00000000-0000-0000-0000-000000000001")
            self.name = "장세영"

    class FakeProfile:
        def __init__(self):
            self.id = profile_id
            self.node_id = node_id
            self.display_name = None

    session = AsyncMock()
    session.get = AsyncMock(return_value=FakeNode())

    segments = [
        {
            "speaker": "Speaker_1",
            "text": "제 이름은 제니예요.",
            "start_sec": 0.0,
            "end_sec": 8.0,
        },
        {
            "speaker": "Speaker_2",
            "text": "저는 장세형이에요.",
            "start_sec": 8.0,
            "end_sec": 14.0,
            "speaker_profile_id": str(profile_id),
        },
    ]

    with patch(
        "app.speaker_profiles.crud.list_speaker_profiles",
        new=AsyncMock(return_value=[FakeProfile()]),
    ):
        text = await build_llm_transcript_with_speaker_names(
            session,
            uuid.UUID("00000000-0000-0000-0000-000000000001"),
            segments,
        )

    assert "[Speaker_1]" in text
    assert "[장세영]" in text
    assert "장세형" in text
    print(f"OK build_llm_transcript_substitutes_known_speaker:\n{text}")


async def test_live_diarize_two_speakers():
    """Integration: Deepgram + embedding refinement on real 2-speaker recording."""
    from app.config import get_settings

    settings = get_settings()
    if not settings.speaker_diarization_enabled:
        print("SKIP live_diarize_two_speakers (diarization disabled)")
        return
    if not settings.deepgram_api_key and not settings.pyannote_hf_token:
        print("SKIP live_diarize_two_speakers (no diarization provider)")
        return
    if not settings.openai_api_key:
        print("SKIP live_diarize_two_speakers (no OpenAI key for segment STT)")
        return

    segments, provider, refine_meta = await diarize_audio(TWO_SPEAKER_WAV)
    assert segments, f"no segments from provider={provider}"
    labels = {seg.speaker for seg in segments}
    assert len(labels) >= 2, (
        f"expected >=2 speakers, got {labels} provider={provider} meta={refine_meta}"
    )
    print(
        "OK live_diarize_two_speakers:",
        provider,
        refine_meta,
        [s.to_dict() for s in segments],
    )


async def test_speaker_embeddings_are_separable():
    segments, _, _ = await diarize_audio(TWO_SPEAKER_WAV)
    from app.voice_embedding import cosine_similarity, embed_speaker_segments

    ranges = [(s.speaker, s.start_sec, s.end_sec) for s in segments]
    embeddings = embed_speaker_segments(TWO_SPEAKER_WAV, ranges)
    labels = list(embeddings.keys())
    assert len(labels) >= 2, labels
    sim = cosine_similarity(embeddings[labels[0]], embeddings[labels[1]])
    assert sim < 0.85, sim
    print(f"OK speaker_embeddings_are_separable: sim={sim:.4f}")


async def main() -> int:
    test_should_refine_single_speaker_segment()
    test_find_voice_change_boundaries_two_speakers()
    await test_refine_splits_into_two_speakers()
    await test_build_llm_transcript_substitutes_known_speaker()
    await test_speaker_embeddings_are_separable()
    await test_live_diarize_two_speakers()
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
