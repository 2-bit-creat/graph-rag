"""PATCH /graph/nodes/{id} — correcting a Statement's event day after commit.

Text written in plain past tense never states which day it describes, so the
date stays editable long after the entry was committed. These cover the HTTP
surface for that, plus the ownership guard on the same endpoint.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete as sa_delete

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


async def _handle(client, monkeypatch=None):
    """Create an isolated handle account and return (token, user_id)."""
    handle = "dt" + uuid.uuid4().hex[:8]
    resp = await client.post(
        "/auth/simple", json={"handle": handle, "native_language": "korean"}
    )
    token = resp.json()["access_token"]
    async with async_session_factory() as s:
        user = await crud.get_user_by_email(s, f"simple:{handle}@local")
        return token, user.id, handle


async def _cleanup(*handles: str) -> None:
    async with async_session_factory() as s:
        for h in handles:
            u = await crud.get_user_by_email(s, f"simple:{h}@local")
            if u is not None:
                await s.execute(sa_delete(User).where(User.id == u.id))
        await s.commit()


async def _statement(user_id, name: str) -> uuid.UUID:
    async with async_session_factory() as s:
        node = await crud._get_or_create_node(
            s,
            name=name,
            type_="Statement",
            description='{"context_type":"일기","content":"친구가 이직한대."}',
            user_id=user_id,
            claim_key=f"endpoint-{uuid.uuid4().hex[:8]}",
            occurred_at=date(2026, 7, 30),
            recorded_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
            temporal_precision="recorded_date",
            temporal_confidence=0.6,
        )
        await s.commit()
        return node.id


@pytest.fixture(autouse=True)
def _production_env(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


async def test_owner_can_correct_the_event_day(client):
    token, user_id, handle = await _handle(client)
    try:
        node_id = await _statement(user_id, f"이직 소식 {uuid.uuid4().hex[:4]}")

        resp = await client.patch(
            f"/graph/nodes/{node_id}",
            json={"name": "친구 이직 소식", "type": "Statement", "occurred_at": "2026-07-28"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["occurred_at"] == "2026-07-28"
        assert body["temporal_precision"] == "user_set"
        assert body["temporal_confidence"] == 1.0
    finally:
        await _cleanup(handle)


async def test_editing_text_without_a_date_leaves_the_inferred_day_alone(client):
    """A text edit must not silently promote a guessed date to user-confirmed."""
    token, user_id, handle = await _handle(client)
    try:
        node_id = await _statement(user_id, f"본문만 수정 {uuid.uuid4().hex[:4]}")

        resp = await client.patch(
            f"/graph/nodes/{node_id}",
            json={"name": "제목만 바꿈", "type": "Statement"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["occurred_at"] == "2026-07-30"
        assert body["temporal_precision"] == "recorded_date"
    finally:
        await _cleanup(handle)


async def test_another_account_cannot_touch_the_node(client):
    """The 404 must come before the write, not after it."""
    token_a, user_a, handle_a = await _handle(client)
    token_b, _user_b, handle_b = await _handle(client)
    try:
        node_id = await _statement(user_a, f"남의 노드 {uuid.uuid4().hex[:4]}")

        resp = await client.patch(
            f"/graph/nodes/{node_id}",
            json={"name": "탈취 시도", "type": "Statement", "occurred_at": "2020-01-01"},
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert resp.status_code == 404

        # The owner's node is untouched — name, date, and precision all intact.
        async with async_session_factory() as s:
            after = await crud.get_node_out(s, node_id, user_a)
        assert after.name != "탈취 시도"
        assert after.occurred_at == date(2026, 7, 30)
        assert after.temporal_precision == "recorded_date"
    finally:
        await _cleanup(handle_a, handle_b)
