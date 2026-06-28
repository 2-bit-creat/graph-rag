"""Probe Deepgram response shapes for 01f099a1 matcha WAV."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import httpx

from app.config import get_settings
from app.voice_embedding import cosine_similarity, embed_speaker_segments

WAV = Path(
    "uploads/00000000-0000-0000-0000-000000000001"
    "/01f099a1-8bbf-4a3d-b4e9-f46f2acb6f95.wav"
)

URLS = [
    "model=nova-2&language=ko&diarize=true&punctuate=true&smart_format=true",
    "model=nova-2&language=ko&diarize=true&punctuate=true&smart_format=true&utterances=true",
    "model=nova-2&language=ko&diarize=true&punctuate=true&smart_format=true&utterances=true&diarize_version=latest",
    "model=nova-3&language=ko&diarize=true&punctuate=true&smart_format=true&utterances=true",
]


async def probe() -> None:
    settings = get_settings()
    headers = {
        "Authorization": f"Token {settings.deepgram_api_key}",
        "Content-Type": "audio/wav",
    }
    data = WAV.read_bytes()
    async with httpx.AsyncClient(timeout=120.0) as client:
        for qs in URLS:
            url = f"https://api.deepgram.com/v1/listen?{qs}"
            resp = await client.post(url, headers=headers, content=data)
            print("\n===", qs[:60], "... ===")
            print("status", resp.status_code)
            if resp.status_code != 200:
                print(resp.text[:300])
                continue
            payload = resp.json()
            alt = payload["results"]["channels"][0]["alternatives"][0]
            words = alt.get("words") or []
            spk_words = sorted({int(w.get("speaker", -1)) for w in words})
            print("word_speakers", spk_words, "count", len(words))
            utts = alt.get("utterances") or payload["results"].get("utterances") or []
            print("utterances", len(utts))
            for u in utts:
                print(
                    " utt",
                    u.get("speaker"),
                    u.get("start"),
                    u.get("end"),
                    (u.get("transcript") or "")[:60],
                )

    # Embedding split around sentence boundary (~3s guess)
    for cut in [2.5, 3.0, 3.5, 4.0]:
        embs = embed_speaker_segments(
            WAV,
            [("_a", 0.96, cut), ("_b", cut, 5.46)],
        )
        if len(embs) == 2:
            labs = list(embs.keys())
            sim = cosine_similarity(embs[labs[0]], embs[labs[1]])
            print(f"emb cut@{cut}s sim={sim:.4f}")


async def main() -> None:
    await probe()


if __name__ == "__main__":
    asyncio.run(main())
