"""FastAPI dependencies."""

import uuid

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from .auth_utils import decode_access_token
from .config import get_settings
from .db import get_session
from .models import User

_bearer = HTTPBearer(auto_error=False)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    session: AsyncSession = Depends(get_session),
) -> User:
    if credentials is None or not credentials.credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
        )
    payload = decode_access_token(credentials.credentials)
    if payload is None or "sub" not in payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
        )
    try:
        user_id = uuid.UUID(payload["sub"])
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token subject",
        ) from exc

    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
        )
    return user


async def get_optional_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    session: AsyncSession = Depends(get_session),
) -> User | None:
    if credentials is None or not credentials.credentials:
        return None
    payload = decode_access_token(credentials.credentials)
    if payload is None or "sub" not in payload:
        return None
    try:
        user_id = uuid.UUID(payload["sub"])
    except ValueError:
        return None
    return await session.get(User, user_id)


async def get_request_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    session: AsyncSession = Depends(get_session),
) -> User:
    """Resolve the request user from a Bearer token.

    A valid token always wins. A missing token is rejected with 401 — except in
    a local development environment, where it falls back to the shared dev user
    so curl/manual testing keeps working without a login. In production this
    fallback is disabled so a header-less request can never reach the primary
    account (see [[project_id_entry_accounts]])."""
    if credentials is not None and credentials.credentials:
        payload = decode_access_token(credentials.credentials)
        if payload is not None and "sub" in payload:
            try:
                user_id = uuid.UUID(payload["sub"])
            except ValueError:
                user_id = None
            if user_id is not None:
                user = await session.get(User, user_id)
                if user is not None:
                    return user
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
        )

    if not get_settings().is_production:
        from .dev_user import get_dev_user

        return await get_dev_user(session)

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Not authenticated",
    )


request_user_dep = get_request_user


def require_debug_enabled() -> None:
    """Gate debug/introspection endpoints — they expose raw prompts/transcripts,
    so they 404 when debug is off (production default)."""
    if not get_settings().debug_enabled:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Not found",
        )


def require_premium(user: User) -> None:
    if user.subscription_tier != "premium":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Premium subscription required",
        )
