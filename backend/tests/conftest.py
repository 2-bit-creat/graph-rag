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
