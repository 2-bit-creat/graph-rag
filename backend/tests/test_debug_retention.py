"""P0-3 debug retention & deletion:

- With debug off, the pipeline tracer writes nothing to disk and redacts raw
  prompts/inputs/outputs from the trace kept in the DB.
- The debug endpoints 404 when debug is off.
- Account deletion purges on-disk artifacts (uploads + debug_runs).
- The startup sweep removes stale debug_runs directories.
"""

from __future__ import annotations

import os
import time
import uuid
from pathlib import Path

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from app import crud
from app.config import get_settings
from app.db import async_session_factory
from app.main import app
from app.models import JournalEntry, User


def _reload_settings(monkeypatch, **env) -> None:
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    get_settings.cache_clear()


@pytest_asyncio.fixture
async def client(db_session):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


def test_tracer_redacts_and_skips_disk_when_debug_off(tmp_path, monkeypatch):
    _reload_settings(monkeypatch, DEBUG_FEATURES_ENABLED="false", DEBUG_RUNS_DIR=str(tmp_path))
    try:
        from app.pipeline_trace import PipelineTracer

        eid = uuid.uuid4()
        tracer = PipelineTracer(eid)
        step = tracer.begin_step(
            "extract", "llm", system_prompt="SECRET SYSTEM", input_data={"text": "diary content"}
        )
        tracer.finish_step(step, output={"claims": ["x"]}, artifacts=[("out", "raw response", "text/plain")])
        tracer.save_audio_bytes(b"RAWAUDIOBYTES", "voice.wav")
        data = tracer.finish()

        # Nothing written to disk.
        assert not (tmp_path / str(eid)).exists()
        # Structure kept, sensitive fields redacted.
        s0 = data["steps"][0]
        assert s0["name"] == "extract"
        assert s0["system_prompt"] is None
        assert s0["input"] == {}
        assert s0["output"] == {}
        assert s0["artifacts"] == []
    finally:
        get_settings.cache_clear()


def test_tracer_persists_when_debug_on(tmp_path, monkeypatch):
    _reload_settings(monkeypatch, DEBUG_FEATURES_ENABLED="true", DEBUG_RUNS_DIR=str(tmp_path))
    try:
        from app.pipeline_trace import PipelineTracer

        eid = uuid.uuid4()
        tracer = PipelineTracer(eid)
        step = tracer.begin_step("extract", "llm", system_prompt="P", input_data={"text": "t"})
        tracer.finish_step(step, output={"a": "b"})
        data = tracer.finish()

        assert (tmp_path / str(eid) / "trace.json").is_file()
        assert data["steps"][0]["system_prompt"] == "P"
    finally:
        get_settings.cache_clear()


def test_cleanup_old_debug_runs(tmp_path, monkeypatch):
    _reload_settings(monkeypatch, DEBUG_RUNS_DIR=str(tmp_path))
    try:
        from app.pipeline_trace import cleanup_old_debug_runs

        old = tmp_path / "old-entry"
        fresh = tmp_path / "fresh-entry"
        old.mkdir()
        fresh.mkdir()
        (old / "trace.json").write_text("{}", encoding="utf-8")
        # Backdate the old dir by 10 days.
        ten_days_ago = time.time() - 10 * 86400
        os.utime(old, (ten_days_ago, ten_days_ago))

        removed = cleanup_old_debug_runs(7)
        assert removed == 1
        assert not old.exists()
        assert fresh.exists()
    finally:
        get_settings.cache_clear()


async def test_debug_runs_endpoint_404_when_off(client, monkeypatch):
    _reload_settings(monkeypatch, ENVIRONMENT="production", DEBUG_FEATURES_ENABLED="false")
    try:
        handle = "dbg" + uuid.uuid4().hex[:8]
        token = (await client.post("/auth/simple", json={"handle": handle})).json()["access_token"]
        resp = await client.get("/kg/debug/runs", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 404

        # Cleanup the ephemeral user.
        async with async_session_factory() as s:
            from sqlalchemy import delete as sa_delete
            u = await crud.get_user_by_email(s, f"simple:{handle}@local")
            if u is not None:
                await s.execute(sa_delete(User).where(User.id == u.id))
                await s.commit()
    finally:
        get_settings.cache_clear()


async def test_debug_runs_endpoint_ok_when_on(client, monkeypatch):
    _reload_settings(monkeypatch, DEBUG_FEATURES_ENABLED="true")
    try:
        # development-ish: token-less dev fallback + debug on.
        monkeypatch.delenv("ENVIRONMENT", raising=False)
        get_settings.cache_clear()
        resp = await client.get("/kg/debug/runs")
        assert resp.status_code == 200
        assert isinstance(resp.json(), list)
    finally:
        get_settings.cache_clear()


async def test_account_deletion_purges_files(client, tmp_path, monkeypatch):
    uploads = tmp_path / "uploads"
    debug_runs = tmp_path / "debug_runs"
    _reload_settings(
        monkeypatch,
        ENVIRONMENT="production",
        UPLOAD_DIR=str(uploads),
        DEBUG_RUNS_DIR=str(debug_runs),
    )
    try:
        handle = "del" + uuid.uuid4().hex[:8]
        token = (await client.post("/auth/simple", json={"handle": handle})).json()["access_token"]

        async with async_session_factory() as s:
            user = await crud.get_user_by_email(s, f"simple:{handle}@local")
            entry = JournalEntry(user_id=user.id, status="ready")
            s.add(entry)
            await s.commit()
            await s.refresh(entry)
            entry_id = entry.id
            user_id = user.id

        # Seed on-disk artifacts the deletion must remove.
        (uploads / str(user_id)).mkdir(parents=True, exist_ok=True)
        (uploads / str(user_id) / "voice.m4a").write_bytes(b"audio")
        (uploads / str(user_id) / "user_node_expressions.json").write_text("{}", encoding="utf-8")
        (debug_runs / str(entry_id)).mkdir(parents=True, exist_ok=True)
        (debug_runs / str(entry_id) / "trace.json").write_text("{}", encoding="utf-8")

        resp = await client.delete("/auth/me", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200

        assert not (uploads / str(user_id)).exists()
        assert not (debug_runs / str(entry_id)).exists()
        # And the DB row is gone.
        async with async_session_factory() as s:
            assert await s.get(User, user_id) is None
    finally:
        get_settings.cache_clear()
