"""Inspect full Deepgram payload with diarize_version=latest."""

import asyncio
import json
from pathlib import Path

import httpx

from app.config import get_settings

WAV = Path(
    "uploads/00000000-0000-0000-0000-000000000001"
    "/01f099a1-8bbf-4a3d-b4e9-f46f2acb6f95.wav"
)


async def main() -> None:
    settings = get_settings()
    url = (
        "https://api.deepgram.com/v1/listen"
        "?model=nova-2&language=ko&diarize=true&diarize_version=latest"
        "&utterances=true&punctuate=true&smart_format=true"
    )
    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            url,
            headers={
                "Authorization": f"Token {settings.deepgram_api_key}",
                "Content-Type": "audio/wav",
            },
            content=WAV.read_bytes(),
        )
        payload = resp.json()
    alt = payload["results"]["channels"][0]["alternatives"][0]
    print(json.dumps(alt.get("utterances"), ensure_ascii=False, indent=2))
    for w in alt["words"]:
        print(w.get("speaker"), w.get("punctuated_word"), w.get("start"), w.get("end"))


if __name__ == "__main__":
    asyncio.run(main())
