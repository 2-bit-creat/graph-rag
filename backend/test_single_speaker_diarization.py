"""Regression: single-speaker audio must stay 1 speaker after diarization pipeline."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from app.speaker_diarization import _deepgram_diarize, diarize_audio
from app.speaker_refinement import distinct_speaker_labels, refine_diarization_segments
from app.config import get_settings

SINGLE_SPEAKER_WAV = (
    Path(__file__).parent
    / "uploads"
    / "00000000-0000-0000-0000-000000000001"
    / "d0f34fa6-26d7-4306-84ab-b8400c7a2569.wav"
)
TWO_SPEAKER_WAV = (
    Path(__file__).parent
    / "uploads"
    / "00000000-0000-0000-0000-000000000001"
    / "1f6e137b-061a-42d4-8223-70541433f152.wav"
)


async def test_single_speaker_stays_one_after_refinement():
    assert SINGLE_SPEAKER_WAV.exists(), f"missing {SINGLE_SPEAKER_WAV}"
    settings = get_settings()
    assert settings.deepgram_api_key, "DEEPGRAM_API_KEY required"

    raw = await _deepgram_diarize(SINGLE_SPEAKER_WAV, settings.deepgram_api_key)
    assert len(distinct_speaker_labels(raw)) == 1, raw

    refined, meta = await refine_diarization_segments(SINGLE_SPEAKER_WAV, raw)
    assert meta.get("refined") is not True, meta
    assert meta.get("reason") == "split_rejected_same_speaker", meta
    assert len(distinct_speaker_labels(refined)) == 1, refined
    print("OK single_speaker_stays_one_after_refinement", meta)


async def test_single_speaker_full_pipeline():
    segments, provider, meta = await diarize_audio(SINGLE_SPEAKER_WAV)
    labels = distinct_speaker_labels(segments)
    assert len(labels) == 1, (labels, provider, meta, segments)
    assert "+embedding_refine" not in provider, provider
    print("OK single_speaker_full_pipeline", provider, meta, labels)


async def test_two_speaker_still_splits_when_collapsed():
    """When Deepgram collapses to one label, refinement may still recover two voices."""
    settings = get_settings()
    raw = await _deepgram_diarize(TWO_SPEAKER_WAV, settings.deepgram_api_key)
    if len(distinct_speaker_labels(raw)) >= 2:
        print("SKIP two_speaker_still_splits (Deepgram already separated)")
        return

    refined, meta = await refine_diarization_segments(TWO_SPEAKER_WAV, raw)
    assert meta.get("refined") is True, meta
    assert len(distinct_speaker_labels(refined)) >= 2, refined
    print("OK two_speaker_still_splits_when_collapsed", meta)


async def main() -> int:
    await test_single_speaker_stays_one_after_refinement()
    await test_single_speaker_full_pipeline()
    await test_two_speaker_still_splits_when_collapsed()
    print("ALL SINGLE-SPEAKER DIARIZATION TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
