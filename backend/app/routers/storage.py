"""저장공간 관리 — what this account is holding, and how to give parts of it back.

Lives on its own prefix rather than under /graph or /journal because the whole
point is a single surface: "지식그래프 전체 삭제" used to sit in the graph
screen's overflow menu next to view toggles, which put an irreversible wipe one
mis-tap away from a zoom control and left the equally destructive audio/image
purges with no home at all.

Everything here is scoped to the caller's own account. Deleting *someone else's*
account is account administration and stays in ``routers/auth.py`` behind the
main-space gate.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from .. import storage_usage
from ..db import get_session
from ..deps import request_user_dep
from ..models import User
from .auth import require_main_account

router = APIRouter(prefix="/storage", tags=["storage"])


@router.get("/usage")
async def get_usage(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Per-category byte usage for the signed-in account.

    Reads whole rows to size them (``pg_column_size``), so it is an on-demand
    report — never call it from a poll or a screen's build path.
    """
    return await storage_usage.collect_usage(session, user.id)


@router.delete("/categories/{key}")
async def purge_category(
    key: str,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Erase one category (사진/음성/일기/지식그래프/대화/퀴즈/디버그).

    Irreversible and immediate — the confirmation is the client's job. The
    account itself survives; use ``DELETE /auth/me`` to remove it entirely.
    """
    if key not in storage_usage.CATEGORY_KEYS:
        raise HTTPException(
            status_code=404,
            detail={"code": "unknown_category", "message": f"unknown storage category: {key}"},
        )
    removed = await storage_usage.purge_category(session, user.id, key)
    return {"ok": True, "category": key, "removed": removed}


@router.post("/admin/gc")
async def run_orphan_gc(
    dry_run: bool = False,
    _user: User = Depends(require_main_account),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Sweep the whole server for data nothing references any more.

    Server-wide (an orphan has no account left to scope it to), so it is gated
    on the reserved "main" space exactly like account administration. The delete
    paths keep things clean going forward; this is for what earlier gaps left
    behind, and for the window between a database commit and a file unlink.

    Pass ``dry_run=true`` to see the same report without deleting anything.
    """
    return await storage_usage.gc_orphans(session, dry_run=dry_run)


@router.delete("/all")
async def purge_everything(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Reset the account to empty — every category — while keeping the account.

    This is the "지식그래프를 처음부터 다시 만들고 싶다" button: the handle,
    native language, and consent record stay; everything derived from the user's
    content goes.
    """
    removed = await storage_usage.purge_all(session, user.id)
    return {"ok": True, "removed": removed}
