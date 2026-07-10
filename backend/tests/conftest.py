"""Pytest fixtures for graph pipeline tests."""

from __future__ import annotations

import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import async_session_factory, engine, init_db
from app.dev_user import get_dev_user

_db_initialized = False


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
    try:
        yield user
    finally:
        # Clean up in a FRESH session — the yielded one is mid-teardown.
        async with async_session_factory() as cleanup:
            await cleanup.execute(sa_delete(User).where(User.id == user.id))
            await cleanup.commit()
