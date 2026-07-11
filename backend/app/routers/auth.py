import asyncio
import re
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..auth_utils import create_access_token, hash_password, verify_password
from ..db import get_session
from ..deps import get_current_user, request_user_dep
from ..dev_user import DEV_USER_ID, get_dev_user
from ..models import JournalEntry, User
from ..storage import purge_user_storage
from ..schemas import (
    LoginRequest,
    RegisterRequest,
    SimpleLoginRequest,
    TokenResponse,
    UserOut,
)

router = APIRouter(prefix="/auth", tags=["auth"])

# ID-entry accounts: a handle is just a lowercase alnum id, no password. The
# reserved handle "main" maps to the original local space so all pre-existing
# journals/graph/quizzes stay accessible under it.
_HANDLE_RE = re.compile(r"^[a-z0-9]{3,20}$")
_RESERVED_MAIN = "main"


@router.post("/simple", response_model=TokenResponse)
async def simple_login(
    payload: SimpleLoginRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    """Enter (or create) a space by handle — no password, no registration form."""
    handle = (payload.handle or "").strip().lower()
    if not _HANDLE_RE.match(handle):
        raise HTTPException(
            status_code=400,
            detail={"code": "bad_handle", "message": "handle must be 3-20 lowercase letters or digits"},
        )
    if handle == _RESERVED_MAIN:
        # The pre-existing local data lives on the dev user; "main" opens it.
        user = await get_dev_user(session)
    else:
        email = f"simple:{handle}@local"
        user = await crud.get_user_by_email(session, email)
        if user is None:
            user = await crud.create_user(session, email, password_hash="")
    return TokenResponse(access_token=create_access_token(str(user.id)))


@router.delete("/me")
async def delete_me(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Delete the current account and all its data.

    DB rows cascade via FK; on-disk artifacts (audio, file-based vocab/expression
    stores, and pipeline debug dumps) are purged explicitly so nothing survives."""
    if user.id == DEV_USER_ID:
        raise HTTPException(
            status_code=400,
            detail={"code": "protected", "message": "the primary account cannot be deleted"},
        )
    user_id = user.id
    # Collect entry ids before the cascade removes them — debug_runs/ is keyed by entry.
    entry_id_rows = await session.execute(
        select(JournalEntry.id).where(JournalEntry.user_id == user_id)
    )
    entry_ids = [row[0] for row in entry_id_rows.all()]

    await session.delete(user)
    await session.commit()

    await asyncio.to_thread(purge_user_storage, user_id, entry_ids)
    return {"status": "deleted"}


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def register(
    payload: RegisterRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    if len(payload.password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")
    existing = await crud.get_user_by_email(session, payload.email)
    if existing:
        raise HTTPException(status_code=409, detail="Email already registered")
    user = await crud.create_user(
        session, payload.email, hash_password(payload.password)
    )
    token = create_access_token(str(user.id))
    return TokenResponse(access_token=token)


@router.post("/login", response_model=TokenResponse)
async def login(
    payload: LoginRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    user = await crud.get_user_by_email(session, payload.email)
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = create_access_token(str(user.id))
    return TokenResponse(access_token=token)


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)) -> User:
    return user
