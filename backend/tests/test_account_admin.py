"""Account administration from the reserved "main" space.

Covers the rule the login screen depends on: handles are minted by main (which
picks the immutable native language), so the entry screen only ever takes an id.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi import HTTPException
from sqlalchemy import delete as sa_delete

from app import crud
from app.db import async_session_factory
from app.dev_user import DEV_USER_ID, get_dev_user
from app.models import User
from app.routers.auth import (
    create_account,
    delete_account,
    list_accounts,
    require_main_account,
)
from app.schemas import AccountCreateRequest


async def _dev(db_session) -> User:
    user = await db_session.get(User, DEV_USER_ID)
    return user if user is not None else await get_dev_user(db_session)


async def _drop(email: str) -> None:
    async with async_session_factory() as s:
        await s.execute(sa_delete(User).where(User.email == email))
        await s.commit()


@pytest.mark.asyncio
async def test_require_main_account_rejects_other_handles(iso_user):
    """Being logged in is not enough — account admin enumerates every handle
    on the server and can delete other spaces."""
    with pytest.raises(HTTPException) as exc:
        require_main_account(user=iso_user)
    assert exc.value.status_code == 403
    assert exc.value.detail["code"] == "main_account_required"


@pytest.mark.asyncio
async def test_require_main_account_allows_main(db_session):
    dev = await _dev(db_session)
    assert require_main_account(user=dev) is dev


@pytest.mark.asyncio
async def test_create_account_provisions_without_switching(db_session):
    handle = f"adm{uuid.uuid4().hex[:8]}"
    dev = await _dev(db_session)
    try:
        created = await create_account(
            AccountCreateRequest(handle=handle, native_language="english"),
            _user=dev,
            session=db_session,
        )
        # No token comes back: main stays main, the new id is typed in at login.
        assert created.handle == handle
        assert created.journal_count == 0
        user = await crud.get_user_by_email(db_session, f"simple:{handle}@local")
        assert user is not None
        assert user.native_language == "english"
    finally:
        await _drop(f"simple:{handle}@local")


@pytest.mark.asyncio
async def test_create_account_rejects_duplicate_handle(db_session):
    handle = f"adm{uuid.uuid4().hex[:8]}"
    dev = await _dev(db_session)
    try:
        await create_account(
            AccountCreateRequest(handle=handle, native_language="korean"),
            _user=dev,
            session=db_session,
        )
        with pytest.raises(HTTPException) as exc:
            await create_account(
                AccountCreateRequest(handle=handle, native_language="korean"),
                _user=dev,
                session=db_session,
            )
        assert exc.value.status_code == 409
        assert exc.value.detail["code"] == "handle_taken"
    finally:
        await _drop(f"simple:{handle}@local")


@pytest.mark.asyncio
async def test_create_account_rejects_reserved_and_malformed_handles(db_session):
    dev = await _dev(db_session)
    for bad in ("main", "ab", "has space", "bad!", "a" * 30):
        with pytest.raises(HTTPException) as exc:
            await create_account(
                AccountCreateRequest(handle=bad, native_language="korean"),
                _user=dev,
                session=db_session,
            )
        assert exc.value.status_code == 400, bad


@pytest.mark.asyncio
async def test_create_account_requires_supported_native_language(db_session):
    dev = await _dev(db_session)
    with pytest.raises(HTTPException) as exc:
        await create_account(
            AccountCreateRequest(handle=f"adm{uuid.uuid4().hex[:8]}",
                                 native_language="klingon"),
            _user=dev,
            session=db_session,
        )
    assert exc.value.status_code == 400
    assert exc.value.detail["code"] == "native_language_required"


@pytest.mark.asyncio
async def test_delete_account_removes_other_space(db_session):
    handle = f"adm{uuid.uuid4().hex[:8]}"
    dev = await _dev(db_session)
    await create_account(
        AccountCreateRequest(handle=handle, native_language="korean"),
        _user=dev,
        session=db_session,
    )
    result = await delete_account(handle, _user=dev, session=db_session)
    assert result["status"] == "deleted"
    assert await crud.get_user_by_email(db_session, f"simple:{handle}@local") is None


@pytest.mark.asyncio
async def test_delete_account_protects_main(db_session):
    dev = await _dev(db_session)
    with pytest.raises(HTTPException) as exc:
        await delete_account("main", _user=dev, session=db_session)
    assert exc.value.status_code == 400
    assert exc.value.detail["code"] == "protected"


@pytest.mark.asyncio
async def test_delete_account_unknown_handle_404(db_session):
    dev = await _dev(db_session)
    with pytest.raises(HTTPException) as exc:
        await delete_account(f"adm{uuid.uuid4().hex[:8]}", _user=dev, session=db_session)
    assert exc.value.status_code == 404


@pytest.mark.asyncio
async def test_list_accounts_marks_main(db_session):
    dev = await _dev(db_session)
    accounts = await list_accounts(_user=dev, session=db_session)
    main_rows = [a for a in accounts if a.is_main]
    assert len(main_rows) == 1
    assert main_rows[0].handle == "main"
