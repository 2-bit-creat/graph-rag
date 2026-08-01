"""Pytest fixtures for graph pipeline tests."""

from __future__ import annotations

import os

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import async_session_factory, engine, init_db
from app.dev_user import get_dev_user

_db_initialized = False


def pytest_configure(config: pytest.Config) -> None:
    """Refuse to run against a database that is not a throwaway test database.

    These tests use the `dev_user` fixture — the real local account — and several
    of them call `clear_user_knowledge_graph()` and COMMIT. Pointed at the dev
    database, `pytest tests` therefore destroys the developer's knowledge graph:
    nodes, edges, chunks, staged drafts, and every manual correction made in the
    KG screen. Journal entries survive, so the graph can be rebuilt, but the
    hand-made fixes cannot. This happened; the guard is why it will not again.

    Point DATABASE_URL at a database whose name ends in `_test`, or set
    ALLOW_TESTS_ON_DEV_DB=1 to accept the loss deliberately.
    """
    if os.environ.get("ALLOW_TESTS_ON_DEV_DB") == "1":
        return
    from app.config import get_settings

    url = get_settings().database_url
    db_name = url.rsplit("/", 1)[-1].split("?", 1)[0]
    if db_name.endswith("_test") or db_name.endswith("_tests"):
        return
    raise pytest.UsageError(
        f"Refusing to run the suite against database {db_name!r}: these tests "
        "delete the dev user's knowledge graph and commit. Use a database whose "
        "name ends in '_test', or set ALLOW_TESTS_ON_DEV_DB=1 to override."
    )


@pytest_asyncio.fixture
async def db_session() -> AsyncSession:
    global _db_initialized
    if not _db_initialized:
        await init_db()
        _db_initialized = True
    async with async_session_factory() as session:
        try:
            yield session
        finally:
            await session.rollback()
            await engine.dispose()

@pytest_asyncio.fixture
async def dev_user(db_session: AsyncSession):
    return await get_dev_user(db_session)


@pytest_asyncio.fixture
async def iso_user(db_session: AsyncSession):
    """Ephemeral user so tests never pollute the shared/dev DB.

    Deleting the user cascades its nodes, profiles, and entries (ON DELETE CASCADE).
    """
    import uuid

    from sqlalchemy import delete as sa_delete

    from app.db import async_session_factory
    from app.models import User

    user = User(
        id=uuid.uuid4(),
        email=f"iso-{uuid.uuid4().hex[:12]}@test.local",
        password_hash="x",
    )
    db_session.add(user)
    await db_session.commit()
    user_id = user.id
    try:
        yield user
    finally:
        # pytest tears fixtures down LIFO, so THIS runs before db_session's own
        # `finally: await session.rollback()`. If the test flush()ed (but never
        # committed) a change on db_session, that row lock is still held here —
        # the cascading DELETE below would block on it forever, and db_session
        # can't roll back until this generator finishes: a guaranteed deadlock.
        # Rolling back db_session first releases those locks before we touch
        # the same rows from a fresh session.
        #
        # Session.rollback() expires every ORM object attached to db_session
        # regardless of expire_on_commit, so `user` is expired the instant
        # this call returns — accessing user.id afterward would trigger an
        # async lazy-load outside of SQLAlchemy's greenlet context and raise
        # MissingGreenlet. user_id was captured above, before the expiry.
        await db_session.rollback()
        # Clean up in a FRESH session — the yielded one is mid-teardown.
        async with async_session_factory() as cleanup:
            await cleanup.execute(sa_delete(User).where(User.id == user_id))
            await cleanup.commit()
