import asyncio
import re
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..auth_utils import create_access_token, hash_password, verify_password
from ..db import get_session
from ..deps import get_current_user, request_user_dep
from ..dev_user import DEV_EMAIL, DEV_USER_ID, get_dev_user
from ..models import ChatSession, JournalEntry, Node, User
from ..storage import purge_user_storage
from ..schemas import (
    AccountSummaryOut,
    ConsentRequest,
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


def _handle_from_email(email: str) -> str:
    """Reverse the /auth/simple email encoding back to the handle the user
    actually typed. `dev@local` is the reserved "main" space."""
    if email == DEV_EMAIL:
        return _RESERVED_MAIN
    if email.startswith("simple:") and email.endswith("@local"):
        return email[len("simple:") : -len("@local")]
    return email


@router.get("/admin/accounts", response_model=list[AccountSummaryOut])
async def list_accounts(
    _user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[AccountSummaryOut]:
    """Dev-tools-only overview of every account and a rough DB-usage proxy
    (row counts, not disk bytes). Gated by being logged in already — same
    "no extra lock, just tucked away" posture as the rest of dev tools — but
    NEVER call this from an unauthenticated surface (e.g. the account entry
    screen): it enumerates every handle on the server, which is exactly the
    kind of cross-user exposure this app's privacy work has been avoiding.
    """
    users = (await session.execute(select(User).order_by(User.created_at))).scalars().all()

    journal_counts = dict(
        (await session.execute(
            select(JournalEntry.user_id, func.count()).group_by(JournalEntry.user_id)
        )).all()
    )
    node_counts = dict(
        (await session.execute(
            select(Node.user_id, func.count()).group_by(Node.user_id)
        )).all()
    )
    chat_counts = dict(
        (await session.execute(
            select(ChatSession.user_id, func.count()).group_by(ChatSession.user_id)
        )).all()
    )

    return [
        AccountSummaryOut(
            handle=_handle_from_email(u.email),
            created_at=u.created_at,
            journal_count=journal_counts.get(u.id, 0),
            node_count=node_counts.get(u.id, 0),
            chat_session_count=chat_counts.get(u.id, 0),
        )
        for u in users
    ]


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


@router.post("/consent", response_model=UserOut)
async def record_consent(
    payload: ConsentRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> User:
    """Record acceptance of the privacy policy / terms, and the separate opt-in
    for voice speaker-identification (biometric)."""
    from datetime import UTC, datetime

    now = datetime.now(UTC)
    user.consent_version = payload.consent_version
    user.consented_at = now
    if payload.speaker_id_consent is True:
        user.speaker_id_consent_at = now
    elif payload.speaker_id_consent is False:
        user.speaker_id_consent_at = None
    await session.commit()
    await session.refresh(user)
    return user


@router.get("/me/export")
async def export_me(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """Download all data held for this account as a JSON file (PIPA access right)."""
    from ..data_export import export_user_data
    from ..json_util import dumps_json

    bundle = await export_user_data(session, user)
    body = dumps_json(bundle, ensure_ascii=False, indent=2)
    filename = f"my-data-{user.id}.json"
    return Response(
        content=body,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
