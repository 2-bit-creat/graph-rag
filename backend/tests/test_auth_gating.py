"""P0-1 auth hardening at the HTTP layer:

- A request with no Bearer token is rejected with 401 in production, but falls
  back to the dev user in development (local ergonomics).
- Graph endpoints resolve the caller from their token, so two handles see
  isolated graphs.
"""

from __future__ import annotations

import uuid

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from app import crud
from app.config import get_settings
from app.db import async_session_factory
from app.main import app
from app.models import User


@pytest_asyncio.fixture
async def client(db_session):
    # db_session ensures init_db() has run against the test DB.
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


def _set_env(monkeypatch, value: str) -> None:
    monkeypatch.setenv("ENVIRONMENT", value)
    get_settings.cache_clear()


async def test_no_token_is_401_in_production(client, monkeypatch):
    _set_env(monkeypatch, "production")
    try:
        resp = await client.get("/graph")
        assert resp.status_code == 401
    finally:
        get_settings.cache_clear()


async def test_no_token_falls_back_in_development(client, monkeypatch):
    _set_env(monkeypatch, "development")
    try:
        resp = await client.get("/graph")
        assert resp.status_code == 200
    finally:
        get_settings.cache_clear()


async def test_graph_is_isolated_per_handle(client, monkeypatch):
    _set_env(monkeypatch, "production")
    try:
        handle_a = "iso" + uuid.uuid4().hex[:8]
        handle_b = "iso" + uuid.uuid4().hex[:8]
        token_a = (await client.post("/auth/simple", json={"handle": handle_a})).json()["access_token"]
        token_b = (await client.post("/auth/simple", json={"handle": handle_b})).json()["access_token"]

        # Seed a node into handle A's graph directly (bypasses HTTP but uses A's user id).
        # Use a Statement node: bare Person/Concept orphans are GC'd by
        # sanitize_stale_voice_links when the graph is listed.
        marker = f"MARK-{uuid.uuid4().hex[:8]}"
        async with async_session_factory() as s:
            ua = await crud.get_user_by_email(s, f"simple:{handle_a}@local")
            await crud._get_or_create_node(s, name=marker, type_="Statement", user_id=ua.id)
            await s.commit()

        # A sees the node …
        ga = await client.get("/graph", headers={"Authorization": f"Bearer {token_a}"})
        assert ga.status_code == 200
        assert any(n["name"] == marker for n in ga.json()["nodes"])

        # … B does not.
        gb = await client.get("/graph", headers={"Authorization": f"Bearer {token_b}"})
        assert gb.status_code == 200
        assert not any(n["name"] == marker for n in gb.json()["nodes"])

        # Cleanup the two ephemeral handle users.
        async with async_session_factory() as s:
            from sqlalchemy import delete as sa_delete
            for h in (handle_a, handle_b):
                u = await crud.get_user_by_email(s, f"simple:{h}@local")
                if u is not None:
                    await s.execute(sa_delete(User).where(User.id == u.id))
            await s.commit()
    finally:
        get_settings.cache_clear()
