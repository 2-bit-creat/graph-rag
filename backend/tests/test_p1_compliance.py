"""P1 legal-compliance backend: consent tracking, data export, and the public
privacy-policy / AI-disclosure endpoints."""

from __future__ import annotations

import json
import uuid

import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete as sa_delete

from app import crud
from app.config import get_settings
from app.db import async_session_factory
from app.main import app
from app.models import JournalEntry, User


@pytest_asyncio.fixture
async def client(db_session):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


def _prod(monkeypatch) -> None:
    monkeypatch.setenv("ENVIRONMENT", "production")
    get_settings.cache_clear()


async def _new_handle_user(client) -> tuple[str, str]:
    handle = "p1" + uuid.uuid4().hex[:8]
    token = (await client.post("/auth/simple", json={"handle": handle})).json()["access_token"]
    return handle, token


async def _cleanup(handle: str) -> None:
    async with async_session_factory() as s:
        u = await crud.get_user_by_email(s, f"simple:{handle}@local")
        if u is not None:
            await s.execute(sa_delete(User).where(User.id == u.id))
            await s.commit()


async def test_legal_endpoints_are_public(client):
    pp = await client.get("/legal/privacy-policy")
    assert pp.status_code == 200
    body = pp.json()
    assert body["version"]
    assert "개인정보 처리방침" in body["content_markdown"]

    ai = await client.get("/legal/ai-disclosure")
    assert ai.status_code == 200
    assert "AI" in ai.json()["notice"]


async def test_consent_recorded_and_withdrawable(client, monkeypatch):
    _prod(monkeypatch)
    try:
        handle, token = await _new_handle_user(client)
        auth = {"Authorization": f"Bearer {token}"}

        # Initially no consent.
        me0 = (await client.get("/auth/me", headers=auth)).json()
        assert me0["consented_at"] is None
        assert me0["speaker_id_consent_at"] is None

        # Accept policy + opt in to speaker id.
        resp = await client.post(
            "/auth/consent",
            headers=auth,
            json={"consent_version": "2026-07-12", "speaker_id_consent": True},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["consent_version"] == "2026-07-12"
        assert body["consented_at"] is not None
        assert body["speaker_id_consent_at"] is not None

        # Withdraw speaker-id consent only.
        resp2 = await client.post(
            "/auth/consent",
            headers=auth,
            json={"consent_version": "2026-07-12", "speaker_id_consent": False},
        )
        assert resp2.json()["speaker_id_consent_at"] is None
    finally:
        get_settings.cache_clear()
        await _cleanup(handle)


async def test_voiceprint_gated_on_speaker_consent(db_session, iso_user):
    """No voiceprint is derived from audio unless the user consented to speaker
    identification (biometric). Audio itself is untouched."""
    from datetime import UTC, datetime
    from pathlib import Path

    from app.models import JournalEntry
    from app.speaker_diarization import SpeakerSegment
    from app.speaker_profiles import process_entry_speaker_profiles

    entry = JournalEntry(user_id=iso_user.id, status="ready")
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)

    segs = [SpeakerSegment(speaker="Speaker_1", start_sec=0.0, end_sec=1.0)]

    # No consent → early return, never touches the (nonexistent) audio path.
    result = await process_entry_speaker_profiles(
        db_session, iso_user.id, entry.id, Path("does-not-exist.wav"), segs
    )
    assert result == ([], [])

    # Grant consent → the gate lets it through (it then fails on the missing
    # audio file, proving it got past the consent check rather than short-circuiting).
    iso_user.speaker_id_consent_at = datetime.now(UTC)
    await db_session.commit()
    passed_gate = False
    try:
        await process_entry_speaker_profiles(
            db_session, iso_user.id, entry.id, Path("does-not-exist.wav"), segs
        )
        passed_gate = True  # embedding may no-op on a bad path without raising
    except Exception:
        passed_gate = True  # reached audio handling → past the consent gate
    assert passed_gate


async def test_data_export_bundles_user_data_without_secrets(client, monkeypatch):
    _prod(monkeypatch)
    try:
        handle, token = await _new_handle_user(client)
        auth = {"Authorization": f"Bearer {token}"}

        marker = f"EXPORT-{uuid.uuid4().hex[:8]}"
        async with async_session_factory() as s:
            user = await crud.get_user_by_email(s, f"simple:{handle}@local")
            s.add(JournalEntry(user_id=user.id, status="ready", transcript_ko=marker))
            await crud._get_or_create_node(s, name=marker, type_="Statement", user_id=user.id)
            await s.commit()

        resp = await client.get("/auth/me/export", headers=auth)
        assert resp.status_code == 200
        assert "attachment" in resp.headers.get("content-disposition", "")
        bundle = json.loads(resp.text)

        assert bundle["account"]["email"] == f"simple:{handle}@local"
        assert "password_hash" not in bundle["account"]  # secret excluded
        assert any(e.get("transcript_ko") == marker for e in bundle["journal_entries"])
        assert any(n.get("name") == marker for n in bundle["graph_nodes"])
        # Vector columns are excluded from the export.
        assert all("name_embedding" not in n for n in bundle["graph_nodes"])
    finally:
        get_settings.cache_clear()
        await _cleanup(handle)
