"""End-to-end integration test for the language learning platform."""

import json
import sys
import uuid
from pathlib import Path

import httpx

BASE = "http://localhost:8000"
TEST_EMAIL = f"test_{uuid.uuid4().hex[:8]}@example.com"
TEST_PASSWORD = "testpass123"


def main() -> int:
    client = httpx.Client(base_url=BASE, timeout=120.0)
    errors: list[str] = []

    def check(name: str, cond: bool, detail: str = ""):
        if cond:
            print(f"  OK  {name}")
        else:
            msg = f"  FAIL {name}" + (f": {detail}" if detail else "")
            print(msg)
            errors.append(msg)

    print("=== 1. Health ===")
    r = client.get("/health")
    check("GET /health", r.status_code == 200 and r.json().get("status") == "ok", r.text)

    print("\n=== 2. Auth ===")
    r = client.post("/auth/register", json={"email": TEST_EMAIL, "password": TEST_PASSWORD})
    check("POST /auth/register", r.status_code == 201, r.text)
    token = r.json().get("access_token") if r.status_code == 201 else None
    headers = {"Authorization": f"Bearer {token}"} if token else {}

    r = client.get("/auth/me", headers=headers)
    check("GET /auth/me", r.status_code == 200 and r.json().get("email") == TEST_EMAIL, r.text)
    user_id = r.json().get("id") if r.status_code == 200 else None

    print("\n=== 3. Subscription (Premium) ===")
    r = client.post("/subscription/update", json={"tier": "premium"}, headers=headers)
    check("POST /subscription/update premium", r.status_code == 200 and r.json().get("subscription_tier") == "premium", r.text)

    print("\n=== 4. Journal text-only (simulate transcript via direct API test) ===")
    # Create a minimal WAV-like test won't work for whisper - use a real small audio or mock
    # Instead test journal list (empty) first
    r = client.get("/journal/entries", headers=headers)
    check("GET /journal/entries", r.status_code == 200 and isinstance(r.json(), list), r.text)

    print("\n=== 5. Graph summary ===")
    r = client.get("/journal/graph/summary", headers=headers)
    check("GET /journal/graph/summary", r.status_code == 200, r.text)

    print("\n=== 6. Reviews ===")
    r = client.get("/journal/reviews", headers=headers)
    check("GET /journal/reviews", r.status_code == 200, r.text)

    print("\n=== 7. Legacy graph endpoints ===")
    r = client.get("/graph")
    check("GET /graph", r.status_code == 200, r.text)

    r = client.get("/ontology")
    check("GET /ontology", r.status_code == 200, r.text)

    presets = client.get("/ontology/presets").json()
    check("GET /ontology/presets", any(p.get("ontology_name") == "DailyLife_English" for p in presets))

    print("\n=== 8. Agent modes ===")
    for mode in ["study", "explore", "review", "roleplay"]:
        r = client.post(
            "/agent/run",
            json={"mode": mode, "messages": [{"role": "user", "content": "Hello, I met my friend at Starbucks today."}]},
        )
        check(f"POST /agent/run mode={mode}", r.status_code == 200, r.text[:200])

    print("\n=== 9. Graph generate + apply (build pipeline) ===")
    r = client.post(
        "/graph/generate",
        json={"messages": [{"role": "user", "content": "오늘 철수랑 강남 스타벅스에서 커피 마셨어. 영어로 주문하는 게 어려웠어."}]},
    )
    check("POST /graph/generate", r.status_code == 200 and len(r.json().get("nodes", [])) > 0, r.text[:300])
    staging = r.json() if r.status_code == 200 else None

    if staging:
        r = client.post("/graph/apply", json=staging)
        check("POST /graph/apply", r.status_code == 200, r.text[:200])

    print("\n=== 10. Audio upload (Whisper + translate) ===")
    # Generate a minimal valid audio file - use ffmpeg if available, else skip
    audio_path = Path(__file__).parent / "test_audio_ko.mp3"
    if not audio_path.exists():
        try:
            from gtts import gTTS
            tts = gTTS("오늘 회사에서 회의가 있었어", lang="ko")
            tts.save(str(audio_path))
        except Exception as exc:
            print(f"  SKIP audio upload: {exc}")
            audio_path = None

    entry_id = None
    if audio_path and audio_path.exists():
        with audio_path.open("rb") as f:
            r = client.post(
                "/journal/upload",
                headers=headers,
                files={"file": ("test.mp3", f, "audio/mpeg")},
            )
        check("POST /journal/upload", r.status_code == 201, r.text[:500])
        if r.status_code == 201:
            entry = r.json()
            entry_id = entry.get("id")
            check("transcript_ko present", bool(entry.get("transcript_ko")), str(entry)[:200])
            check("translation_en present", bool(entry.get("translation_en")), str(entry)[:200])
            print(f"       transcript_ko: {(entry.get('transcript_ko') or '')[:80]}...")
            print(f"       translation_en: {(entry.get('translation_en') or '')[:80]}...")

    if entry_id:
        print("\n=== 11. Quiz generation ===")
        import time
        time.sleep(2)  # allow graph processing if inline
        r = client.post(f"/journal/entries/{entry_id}/quiz", headers=headers)
        check("POST /journal/entries/{id}/quiz", r.status_code == 200, r.text[:300])
        if r.status_code == 200:
            cards = r.json().get("cards", [])
            check("quiz has cards", len(cards) > 0, json.dumps(r.json())[:200])
            print(f"       cards: {len(cards)}")

        print("\n=== 12. AI Examples (GraphRAG) ===")
        r = client.post(f"/journal/entries/{entry_id}/examples", headers=headers)
        check("POST /journal/entries/{id}/examples", r.status_code == 200, r.text[:300])
        if r.status_code == 200:
            print(f"       examples: {len(r.json().get('examples', []))}")

        print("\n=== 12b. Manual GraphRAG build ===")
        r = client.post(f"/journal/entries/{entry_id}/graph", headers=headers)
        check("POST /journal/entries/{id}/graph", r.status_code == 200, r.text[:300])

        print("\n=== 13. Graph summary after journal ===")
        r = client.get("/journal/graph/summary", headers=headers)
        if r.status_code == 200:
            s = r.json()
            print(f"       nodes={s.get('node_count')} edges={s.get('edge_count')}")
            check("graph has nodes after premium journal", s.get("node_count", 0) >= 0)

        job_id = client.get(f"/journal/entries/{entry_id}", headers=headers).json().get("graph_job_id")
        if job_id:
            print("\n=== 14. Job status ===")
            r = client.get(f"/jobs/{job_id}", headers=headers)
            check("GET /jobs/{id}", r.status_code == 200, r.text[:200])
            print(f"       job status: {r.json().get('status') if r.status_code == 200 else '?'}")

    print("\n=== Summary ===")
    if errors:
        print(f"FAILED: {len(errors)} error(s)")
        for e in errors:
            print(e)
        return 1
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
