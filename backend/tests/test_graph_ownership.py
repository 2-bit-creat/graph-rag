"""P0-1 auth hardening: node/edge CRUD must enforce ownership so one account
can never touch another's graph by guessing an id, and cross-user edges are
rejected at creation."""

from __future__ import annotations

import uuid

import pytest_asyncio

from app import crud
from app.db import async_session_factory
from app.models import User


@pytest_asyncio.fixture
async def iso_user_b(db_session):
    """A second ephemeral user, isolated from `iso_user`."""
    from sqlalchemy import delete as sa_delete

    user = User(
        id=uuid.uuid4(),
        email=f"isob-{uuid.uuid4().hex[:12]}@test.local",
        password_hash="x",
    )
    db_session.add(user)
    await db_session.commit()
    try:
        yield user
    finally:
        async with async_session_factory() as cleanup:
            await cleanup.execute(sa_delete(User).where(User.id == user.id))
            await cleanup.commit()


async def _stmt_pair(db_session, user_id):
    """Two connected nodes owned by `user_id`, plus the edge between them."""
    a = await crud._get_or_create_node(db_session, name=f"A-{uuid.uuid4().hex[:6]}", type_="Person", user_id=user_id)
    b = await crud._get_or_create_node(db_session, name=f"B-{uuid.uuid4().hex[:6]}", type_="Statement", user_id=user_id)
    edge = await crud.create_edge(db_session, source_id=a.id, target_id=b.id, relation="SPOKE_OR_PUBLISHED", user_id=user_id)
    await db_session.commit()
    return a, b, edge


async def test_delete_node_rejects_foreign_owner(db_session, iso_user, iso_user_b):
    a, _b, _edge = await _stmt_pair(db_session, iso_user.id)

    # User B may not delete user A's node.
    assert await crud.delete_node(db_session, a.id, owner_id=iso_user_b.id) is False
    assert await db_session.get(type(a), a.id) is not None  # still there

    # The owner can.
    assert await crud.delete_node(db_session, a.id, owner_id=iso_user.id) is True
    assert await db_session.get(type(a), a.id) is None


async def test_delete_edge_rejects_foreign_owner(db_session, iso_user, iso_user_b):
    _a, _b, edge = await _stmt_pair(db_session, iso_user.id)

    assert await crud.delete_edge(db_session, edge.id, user_id=iso_user_b.id) is False
    assert await db_session.get(type(edge), edge.id) is not None

    assert await crud.delete_edge(db_session, edge.id, user_id=iso_user.id) is True
    assert await db_session.get(type(edge), edge.id) is None


async def test_update_edge_rejects_foreign_owner(db_session, iso_user, iso_user_b):
    _a, _b, edge = await _stmt_pair(db_session, iso_user.id)

    result = await crud.update_edge(db_session, edge.id, relation="HACKED", user_id=iso_user_b.id)
    assert result is None
    refreshed = await db_session.get(type(edge), edge.id)
    assert refreshed.relation == "SPOKE_OR_PUBLISHED"  # unchanged


async def test_create_edge_rejects_cross_user_nodes(db_session, iso_user, iso_user_b):
    a_owner = await crud._get_or_create_node(db_session, name=f"OWN-{uuid.uuid4().hex[:6]}", type_="Person", user_id=iso_user.id)
    b_foreign = await crud._get_or_create_node(db_session, name=f"FOR-{uuid.uuid4().hex[:6]}", type_="Statement", user_id=iso_user_b.id)
    await db_session.commit()

    # Wiring my node to someone else's node is rejected.
    edge = await crud.create_edge(
        db_session, source_id=a_owner.id, target_id=b_foreign.id,
        relation="MENTIONS", user_id=iso_user.id,
    )
    assert edge is None
