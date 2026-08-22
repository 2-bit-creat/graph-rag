import asyncio
import re
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..auth_utils import create_access_token, hash_password, verify_password
from ..config import get_settings
from ..db import get_session
from ..deps import get_current_user, request_user_dep
from ..dev_user import DEV_EMAIL, DEV_USER_ID, get_dev_user
from ..google_auth import GoogleAuthError, verify_id_token
from ..languages import SUPPORTED_NATIVE
from ..models import ChatSession, JournalEntry, Node, Quiz, User
from .. import storage_usage
from ..storage import purge_debug_runs, purge_user_storage
from ..schemas import (
    AccountCreateRequest,
    AccountSummaryOut,
    ConsentRequest,
    GoogleLoginRequest,
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
# Google accounts are keyed by the immutable `sub`, not the address, and are
# encoded like the handle accounts so one unique column keeps serving both.
_GOOGLE_PREFIX = "google:"
_LOCAL_SUFFIX = "@local"


def require_main_account(user: User = Depends(request_user_dep)) -> User:
    """Restrict account administration to the reserved "main" space.

    Account admin enumerates every handle on the server and can delete other
    people's spaces, so it must not be reachable from an ordinary handle —
    being merely logged in is not enough.
    """
    if user.id != DEV_USER_ID:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "code": "main_account_required",
                "message": 'Account administration is only available in the "main" space',
            },
        )
    return user


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
            if not payload.create:
                raise HTTPException(
                    status_code=404,
                    detail={
                        "code": "account_not_found",
                        "message": "No account is registered for this ID",
                    },
                )
            native_language = (payload.native_language or "").strip().lower()
            if native_language not in SUPPORTED_NATIVE:
                raise HTTPException(
                    status_code=400,
                    detail={
                        "code": "native_language_required",
                        "message": "Choose a supported native language when creating an account",
                    },
                )
            user = await crud.create_user(
                session,
                email,
                password_hash="",
                native_language=native_language,
            )
    return TokenResponse(access_token=create_access_token(str(user.id)))


@router.post("/google", response_model=TokenResponse)
async def google_login(
    payload: GoogleLoginRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    """Enter (or create) a space with a Google account.

    The account is keyed by Google's ``sub`` rather than the email address.
    Google permits an address change, which would otherwise strand the user's
    journals behind an identifier they no longer own, and keying on ``sub``
    also means the address itself never has to be stored.
    """
    if not get_settings().google_login_enabled:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "google_login_unavailable",
                "message": "Google sign-in is not configured on this server",
            },
        )
    try:
        subject = await verify_id_token(payload.id_token)
    except GoogleAuthError:
        raise HTTPException(
            status_code=401,
            detail={"code": "bad_google_token", "message": "Google sign-in failed"},
        )

    email = f"{_GOOGLE_PREFIX}{subject}{_LOCAL_SUFFIX}"
    user = await crud.get_user_by_email(session, email)
    if user is None:
        native_language = (payload.native_language or "").strip().lower()
        if native_language not in SUPPORTED_NATIVE:
            # First sign-in for this Google account. The app re-sends the same
            # token with a language once the picker is answered; the token is
            # still valid because verification happened only moments ago.
            raise HTTPException(
                status_code=400,
                detail={
                    "code": "native_language_required",
                    "message": "Choose a supported native language when creating an account",
                },
            )
        user = await crud.create_user(
            session,
            email,
            password_hash="",
            native_language=native_language,
        )
    return TokenResponse(
        access_token=create_access_token(str(user.id)),
        handle=handle_from_email(user.email),
    )


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
    await _delete_user_completely(session, user)
    return {"status": "deleted"}


async def _delete_user_completely(session: AsyncSession, user: User) -> None:
    """Remove a user row and every artifact that outlives the FK cascade.

    Three things do not go by themselves and each one used to become permanent
    garbage: ``debug_runs/`` is keyed by journal entry (gone by the time the
    cascade finishes), quiz TTS lives outside the per-user prefix under
    ``static/audio``/``quiz-audio``, and ``quiz_audio_assets`` has no
    ``user_id`` at all. So the ids are collected *before* the delete and the
    files swept after it.
    """
    user_id = user.id
    entry_ids = [
        row[0]
        for row in (
            await session.execute(
                select(JournalEntry.id).where(JournalEntry.user_id == user_id)
            )
        ).all()
    ]
    quiz_ids = [
        row[0]
        for row in (
            await session.execute(select(Quiz.id).where(Quiz.user_id == user_id))
        ).all()
    ]

    await session.delete(user)
    await session.commit()

    await asyncio.to_thread(purge_user_storage, user_id, entry_ids)
    # Quiz generation traces are keyed by quiz id, not entry id, so they are not
    # part of the entry sweep above.
    await asyncio.to_thread(purge_debug_runs, quiz_ids)
    await storage_usage.purge_quiz_audio_for_quizzes(quiz_ids)
    await storage_usage.gc_orphan_quiz_audio(session)


async def resolve_admin_target(session: AsyncSession, handle: str) -> User | None:
    """Find the account the overview displayed as ``handle``.

    The overview lists *every* user row, and ``handle_from_email`` falls back to
    the raw address for anything that is not a ``/auth/simple`` handle — legacy
    password accounts and leftover test fixtures such as
    ``journal_9f3972ea@test.com``. Looking those up as ``simple:{handle}@local``
    finds nothing, which is why every delete on them 404'd with
    ``account_not_found`` while the row stayed on the server forever. So try the
    handle encoding first, then the literal address.
    """
    normalized = (handle or "").strip().lower()
    if not normalized:
        return None
    user = await crud.get_user_by_email(session, f"simple:{normalized}@local")
    if user is not None:
        return user
    return (
        await session.execute(select(User).where(func.lower(User.email) == normalized))
    ).scalars().first()


def handle_from_email(email: str) -> str:
    """Reverse the /auth/simple email encoding back to the handle the user
    actually typed. `dev@local` is the reserved "main" space."""
    if email == DEV_EMAIL:
        return _RESERVED_MAIN
    if email.startswith("simple:") and email.endswith("@local"):
        return email[len("simple:") : -len("@local")]
    if email.startswith(_GOOGLE_PREFIX) and email.endswith(_LOCAL_SUFFIX):
        # Google accounts have no handle the user ever typed. The subject id is
        # a ~21-digit opaque number, so the admin list shows a short prefix —
        # enough to tell two Google accounts apart without pretending it is a
        # name, and the address is not stored so it cannot be shown instead.
        subject = email[len(_GOOGLE_PREFIX) : -len(_LOCAL_SUFFIX)]
        return f"google:{subject[:8]}"
    return email


@router.get("/admin/accounts", response_model=list[AccountSummaryOut])
async def list_accounts(
    _user: User = Depends(require_main_account),
    session: AsyncSession = Depends(get_session),
) -> list[AccountSummaryOut]:
    """Overview of every account and a rough DB-usage proxy (row counts, not
    disk bytes), for the "main" space only.

    It enumerates every handle on the server, so it is restricted to main
    rather than to "any logged-in handle" — and it must NEVER be called from
    an unauthenticated surface such as the account entry screen.
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

    # Storage is what makes an unused account worth deleting, so the card shows
    # it without a detail tap. Row bytes come from one grouped pass over every
    # account; file bytes need a per-user listing, so that walk is threaded.
    db_bytes = await storage_usage.total_bytes_by_user(session)
    file_bytes = dict(
        zip(
            (u.id for u in users),
            await asyncio.gather(
                *(
                    asyncio.to_thread(storage_usage.file_bytes_for_user, u.id)
                    for u in users
                )
            ),
        )
    )

    out = []
    for u in users:
        handle = handle_from_email(u.email)
        out.append(
            AccountSummaryOut(
                handle=handle,
                created_at=u.created_at,
                journal_count=journal_counts.get(u.id, 0),
                node_count=node_counts.get(u.id, 0),
                chat_session_count=chat_counts.get(u.id, 0),
                storage_bytes=db_bytes.get(u.id, 0) + file_bytes.get(u.id, 0),
                is_main=u.id == DEV_USER_ID,
                # Legacy/test rows show their raw email as the "handle" and
                # cannot be entered through /auth/simple — only deleted.
                can_enter=u.id == DEV_USER_ID or bool(_HANDLE_RE.match(handle)),
            )
        )
    return out


@router.post(
    "/admin/accounts",
    response_model=AccountSummaryOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_account(
    payload: AccountCreateRequest,
    _user: User = Depends(require_main_account),
    session: AsyncSession = Depends(get_session),
) -> AccountSummaryOut:
    """Provision a handle from main, choosing its (immutable) native language.

    Returns no token: main stays signed in as main. The new handle is entered
    from the login screen by typing its id, which is why that screen no longer
    asks for a native language.
    """
    handle = (payload.handle or "").strip().lower()
    if not _HANDLE_RE.match(handle) or handle == _RESERVED_MAIN:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "bad_handle",
                "message": "handle must be 3-20 lowercase letters or digits, and not \"main\"",
            },
        )
    native_language = (payload.native_language or "").strip().lower()
    if native_language not in SUPPORTED_NATIVE:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "native_language_required",
                "message": "Choose a supported native language when creating an account",
            },
        )
    email = f"simple:{handle}@local"
    if await crud.get_user_by_email(session, email) is not None:
        raise HTTPException(
            status_code=409,
            detail={"code": "handle_taken", "message": "This ID is already in use"},
        )
    user = await crud.create_user(
        session, email, password_hash="", native_language=native_language
    )
    return AccountSummaryOut(
        handle=handle,
        created_at=user.created_at,
        journal_count=0,
        node_count=0,
        chat_session_count=0,
    )


@router.delete("/admin/accounts/{handle}")
async def delete_account(
    handle: str,
    _user: User = Depends(require_main_account),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Delete another handle and all of its data, from main.

    Mirrors ``DELETE /auth/me``: FK cascade clears the rows, then on-disk
    artifacts are purged explicitly. Main itself is not deletable.
    """
    normalized = (handle or "").strip().lower()
    if normalized == _RESERVED_MAIN:
        raise HTTPException(
            status_code=400,
            detail={"code": "protected", "message": "the primary account cannot be deleted"},
        )
    target = await resolve_admin_target(session, normalized)
    if target is None or target.id == DEV_USER_ID:
        raise HTTPException(
            status_code=404,
            detail={"code": "account_not_found", "message": "No account is registered for this ID"},
        )

    await _delete_user_completely(session, target)
    return {"status": "deleted", "handle": normalized}


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def register(
    payload: RegisterRequest, session: AsyncSession = Depends(get_session)
) -> TokenResponse:
    if len(payload.password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")
    native_language = payload.native_language.strip().lower()
    if native_language not in SUPPORTED_NATIVE:
        raise HTTPException(status_code=400, detail="Unsupported native language")
    existing = await crud.get_user_by_email(session, payload.email)
    if existing:
        raise HTTPException(status_code=409, detail="Email already registered")
    user = await crud.create_user(
        session,
        payload.email,
        hash_password(payload.password),
        native_language=native_language,
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
