"""Diagnose speaker diarization on 01f099a1 matcha WAV."""

from __future__ import annotations

import asyncio
from collections import Counter
from pathlib import Path

import httpx

from app.config import get_settings
from app.speaker_diarization import _deepgram_diarize, diarize_audio
from app.speaker_refinement import (
    distinct_speaker_labels,
    refine_diarization_segments,
    should_refine_diarization,
)

WAV = Path(
    "uploads/00000000-0000-0000-0000-000000000001"
    "/01f099a1-8bbf-4a3d-b4e9-f46f2acb6f95.wav"
)


async def inspect_deepgram_words() -> None:
    settings = get_settings()
    url = (
        "https://api.deepgram.com/v1/listen"
        "?model=nova-2&language=ko&diarize=true&punctuate=true&smart_format=true"
    )
    headers = {
        "Authorization": f"Token {settings.deepgram_api_key}",
        "Content-Type": "audio/wav",
    }
    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(url, headers=headers, content=WAV.read_bytes())
        resp.raise_for_status()
        alt = resp.json()["results"]["channels"][0]["alternatives"][0]

    words = alt["words"]
    print("TRANSCRIPT:", alt.get("transcript", ""))
    print("WORD_SPEAKERS:", dict(Counter(int(w.get("speaker", 0)) for w in words)))
    for i in range(1, len(words)):
        if words[i].get("speaker") != words[i - 1].get("speaker"):
            print(
                "TRANSITION at word",
                i,
                words[i - 1].get("punctuated_word"),
                "->",
                words[i].get("punctuated_word"),
                "spk",
                words[i].get("speaker"),
            )
    for w in words:
        print(f" spk={w.get('speaker')} {w.get('punctuated_word') or w.get('word')}")


async def inspect_pipeline() -> None:
    settings = get_settings()
    raw = await _deepgram_diarize(WAV, settings.deepgram_api_key)
    print("\nRAW:", len(raw), distinct_speaker_labels(raw))
    for seg in raw:
        print(" ", seg.to_dict())
    print("should_refine", should_refine_diarization(raw, WAV))

    refined, meta = await refine_diarization_segments(WAV, raw)
    print("REFINED meta", meta)
    for seg in refined:
        print(" ", seg.to_dict())

    full, provider, fmeta = await diarize_audio(WAV)
    print("FULL provider", provider, "meta", fmeta)
    labels = distinct_speaker_labels(full)
    print("FINAL labels", labels)
    for seg in full:
        print(" ", seg.to_dict())

    assert len(labels) >= 2, f"expected 2 speakers, got {labels}"


async def main() -> int:
    assert WAV.exists(), WAV
    await inspect_deepgram_words()
    await inspect_pipeline()
    print("OK matcha diarization")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
