"""Dev-mode smoke test."""

import sys
import time
from pathlib import Path

import httpx

BASE = "http://localhost:8000"
AUDIO = Path(__file__).parent / "test_audio_ko.mp3"


def main() -> int:
    client = httpx.Client(base_url=BASE, timeout=120.0)

    with AUDIO.open("rb") as f:
        r = client.post("/journal/upload", files={"file": ("r.mp3", f, "audio/mpeg")})
    print("upload", r.status_code, r.json().get("status"))
    if r.status_code != 201 or r.json().get("status") != "ready":
        return 1

    entry_id = r.json()["id"]
    r = client.post(f"/journal/entries/{entry_id}/examples")
    print("examples", r.status_code, len(r.json().get("examples", [])))
    if r.status_code != 200:
        return 1

    r = client.post(f"/journal/entries/{entry_id}/graph")
    print("graph build", r.status_code, r.json())

    print("DEV MODE OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
