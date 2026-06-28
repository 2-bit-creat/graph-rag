"""Journal upload E2E — fast path only; manual GraphRAG + examples."""

import sys
import time
from pathlib import Path

import httpx

BASE = "http://localhost:8000"
AUDIO = Path(__file__).parent / "test_audio_ko.mp3"


def main() -> int:
    if not AUDIO.exists():
        print(f"Missing {AUDIO}")
        return 1

    client = httpx.Client(base_url=BASE, timeout=180.0)

    print("Upload (fast path only)...")
    with AUDIO.open("rb") as f:
        r = client.post("/journal/upload", files={"file": ("recording.mp3", f, "audio/mpeg")})
    if r.status_code != 201:
        print(r.text)
        return 1

    entry = r.json()
    entry_id = entry["id"]
    print(f"  status={entry.get('status')} (expect ready)")
    if entry.get("status") != "ready":
        return 1

    trace = entry.get("pipeline_trace") or {}
    print(f"  trace steps: {len(trace.get('steps', []))}")

    print("\nManual GraphRAG build...")
    r = client.post(f"/journal/entries/{entry_id}/graph")
    print(f"  {r.status_code} {r.json()}")

    for i in range(45):
        st = client.get(f"/journal/entries/{entry_id}").json().get("status")
        print(f"  poll {i + 1}: {st}")
        if st in ("graph_ready", "ready_no_graph"):
            break
        time.sleep(2)

    print("\nAI examples (GraphRAG)...")
    r = client.post(f"/journal/entries/{entry_id}/examples")
    print(f"  status={r.status_code}")
    if r.status_code != 200:
        print(r.text)
        return 1
    ex = r.json()
    print(f"  examples={len(ex.get('examples', []))} graph_used={ex.get('graph_context_used')}")

    print("\nALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
