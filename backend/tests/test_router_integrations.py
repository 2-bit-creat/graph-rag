"""ASGI router-level tests for chat sessions and graph edges."""

from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app import crud
from app.main import app
from app.deps import request_user_dep
from app.dev_user import get_dev_user
from app.db import get_session


@pytest.fixture
async def api_client(iso_user, db_session):
    async def _override_user():
        return iso_user

    async def _override_session():
        yield db_session

    app.dependency_overrides[request_user_dep] = _override_user
    app.dependency_overrides[get_session] = _override_session
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client
    app.dependency_overrides.clear()


@pytest.mark.asyncio
async def test_chat_sessions_list_create_rename(api_client: AsyncClient):
    listed = await api_client.get("/graph/chat/sessions")
    assert listed.status_code == 200
    assert listed.json()["items"] == []

    created = await api_client.post("/graph/chat/sessions", json={"title": "테스트 방"})
    assert created.status_code == 200
    session_id = created.json()["id"]
    assert created.json()["title"] == "테스트 방"

    renamed = await api_client.patch(
        f"/graph/chat/sessions/{session_id}",
        json={"title": "이름 변경"},
    )
    assert renamed.status_code == 200
    assert renamed.json()["title"] == "이름 변경"

    listed2 = await api_client.get("/graph/chat/sessions")
    assert listed2.status_code == 200
    assert any(item["id"] == session_id for item in listed2.json()["items"])


@pytest.mark.asyncio
async def test_manual_edge_persists_in_graph_read(
    api_client: AsyncClient, iso_user, db_session
):
    a = await crud._get_or_create_node(
        db_session, name="노드A", type_="Concept", user_id=iso_user.id
    )
    b = await crud._get_or_create_node(
        db_session, name="노드B", type_="Concept", user_id=iso_user.id
    )
    await db_session.commit()

    created = await api_client.post(
        "/graph/edges",
        json={
            "source_id": str(a.id),
            "target_id": str(b.id),
            "relation": "RELATED_TO",
        },
    )
    assert created.status_code == 201
    edge_id = created.json()["id"]

    graph = await api_client.get("/graph")
    assert graph.status_code == 200
    edge_ids = {e["id"] for e in graph.json()["edges"]}
    assert edge_id in edge_ids

    deleted = await api_client.delete(f"/graph/edges/{edge_id}")
    assert deleted.status_code == 204

    graph2 = await api_client.get("/graph")
    edge_ids2 = {e["id"] for e in graph2.json()["edges"]}
    assert edge_id not in edge_ids2
