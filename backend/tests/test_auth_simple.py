"""ID-entry account auth: /auth/simple + /auth/me delete guard."""

from __future__ import annotations

import uuid

import pytest
from fastapi import HTTPException
from sqlalchemy import delete as sa_delete

from app.auth_utils import decode_access_token
from app.db import async_session_factory
from app.dev_user import DEV_USER_ID
from app.models import User
from app.routers.auth import delete_me, simple_login
from app.schemas import SimpleLoginRequest


@pytest.mark.asyncio
async def test_simple_login_main_opens_dev_space(db_session):
    resp = await simple_login(SimpleLoginRequest(handle="main"), db_session)
    payload = decode_access_token(resp.access_token)
    assert payload is not None
    assert uuid.UUID(payload["sub"]) == DEV_USER_ID


@pytest.mark.asyncio
async def test_simple_login_new_handle_creates_space(db_session):
    handle = f"iso{uuid.uuid4().hex[:8]}"
    resp = await simple_login(SimpleLoginRequest(handle=handle), db_session)
    payload = decode_access_token(resp.access_token)
    uid = uuid.UUID(payload["sub"])
    assert uid != DEV_USER_ID
    user = await db_session.get(User, uid)
    assert user is not None
    assert user.email == f"simple:{handle}@local"
    # Re-entering the same handle returns the SAME space.
    resp2 = await simple_login(SimpleLoginRequest(handle=handle), db_session)
    assert uuid.UUID(decode_access_token(resp2.access_token)["sub"]) == uid
    # Cleanup.
    async with async_session_factory() as s:
        await s.execute(sa_delete(User).where(User.id == uid))
        await s.commit()


@pytest.mark.asyncio
async def test_simple_login_bad_handle_400(db_session):
    # NB: uppercase is normalized to lowercase (accepted), not rejected.
    for bad in ("ab", "has space", "a" * 30, "bad!", "under_score"):
        with pytest.raises(HTTPException) as exc:
            await simple_login(SimpleLoginRequest(handle=bad), db_session)
        assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_delete_me_protects_main(db_session):
    dev = await db_session.get(User, DEV_USER_ID)
    if dev is None:
        from app.dev_user import get_dev_user

        dev = await get_dev_user(db_session)
    with pytest.raises(HTTPException) as exc:
        await delete_me(user=dev, session=db_session)
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_delete_me_removes_other_account(db_session, iso_user):
    result = await delete_me(user=iso_user, session=db_session)
    assert result["status"] == "deleted"
    assert await db_session.get(User, iso_user.id) is None
