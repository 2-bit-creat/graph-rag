"""Web Push subscription management."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..db import get_session
from ..deps import request_user_dep
from ..models import PushSubscription, User
from ..push import push_enabled, send_to_user

router = APIRouter(prefix="/push", tags=["push"])


class PushSubscribeRequest(BaseModel):
    endpoint: str = Field(min_length=1, max_length=2000)
    p256dh: str = Field(min_length=1, max_length=500)
    auth: str = Field(min_length=1, max_length=500)


class PushUnsubscribeRequest(BaseModel):
    endpoint: str = Field(min_length=1, max_length=2000)


@router.get("/vapid-key")
async def vapid_key() -> dict:
    """The public key the browser needs for pushManager.subscribe().

    Public by design — it is not a secret, and the client needs it before it can
    ask for permission. `enabled` lets the app hide the notification toggle
    entirely on a deployment with no keys configured.
    """
    return {
        "enabled": push_enabled(),
        "public_key": get_settings().vapid_public_key or None,
    }


@router.post("/subscribe")
async def subscribe(
    payload: PushSubscribeRequest,
    request: Request,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Register (or re-register) this browser for notifications.

    The endpoint is unique per browser install, so a repeat subscribe updates
    the existing row. Re-pointing it at the current user matters on a shared
    device: without that, notifications meant for whoever logged in second
    would keep going to the first account's schedule.
    """
    if not push_enabled():
        raise HTTPException(status_code=503, detail="푸시 알림이 설정되지 않았습니다.")

    existing = await session.scalar(
        select(PushSubscription).where(
            PushSubscription.endpoint == payload.endpoint
        )
    )
    if existing is not None:
        existing.user_id = user.id
        existing.p256dh = payload.p256dh
        existing.auth = payload.auth
        existing.user_agent = request.headers.get("user-agent")
        existing.failure_count = 0
    else:
        session.add(
            PushSubscription(
                id=uuid.uuid4(),
                user_id=user.id,
                endpoint=payload.endpoint,
                p256dh=payload.p256dh,
                auth=payload.auth,
                user_agent=request.headers.get("user-agent"),
            )
        )
    await session.commit()
    return {"status": "subscribed"}


@router.delete("/subscribe")
async def unsubscribe(
    payload: PushUnsubscribeRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Remove this browser's subscription. Deleting the row is the opt-out."""
    await session.execute(
        delete(PushSubscription).where(
            PushSubscription.endpoint == payload.endpoint,
            PushSubscription.user_id == user.id,
        )
    )
    await session.commit()
    return {"status": "unsubscribed"}


@router.post("/test")
async def send_test(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Send a notification to the caller's own devices.

    The only way to tell a broken VAPID config from an iOS install requirement
    without waiting for the nightly schedule.
    """
    if not push_enabled():
        raise HTTPException(status_code=503, detail="푸시 알림이 설정되지 않았습니다.")

    report = await send_to_user(
        session,
        user.id,
        {
            "title": "Daylog",
            "body": "알림이 정상적으로 설정되었습니다.",
            "url": "/",
            "tag": "push-test",
        },
    )
    return {"sent": report.sent, "pruned": report.pruned, "failed": report.failed}
