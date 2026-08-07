"""Web Push delivery.

Separate from routers/push.py so the scheduled reminder job can send without
importing the HTTP layer.

Two things about iOS are worth knowing before debugging this: Safari only
supports Web Push from iOS 16.4, and only for a site the user has added to the
Home Screen. A subscription request from a normal Safari tab does not fail
loudly — the browser simply never produces one. So "no subscriptions appeared"
usually means "not installed", not "the backend is broken".
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import delete, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import PushSubscription

logger = logging.getLogger(__name__)


def push_enabled() -> bool:
    settings = get_settings()
    return bool(settings.vapid_private_key and settings.vapid_public_key)


@dataclass
class SendReport:
    sent: int = 0
    pruned: int = 0
    failed: int = 0


def _send_one(subscription: PushSubscription, payload: dict) -> int:
    """Deliver to one endpoint. Returns the push service's status code.

    Raises on transport errors; a WebPushException carrying a response is
    converted to its status code so the caller can decide about pruning.
    """
    from pywebpush import WebPushException, webpush

    settings = get_settings()
    try:
        response = webpush(
            subscription_info={
                "endpoint": subscription.endpoint,
                "keys": {"p256dh": subscription.p256dh, "auth": subscription.auth},
            },
            data=json.dumps(payload),
            vapid_private_key=settings.vapid_private_key,
            vapid_claims={"sub": settings.vapid_subject},
            timeout=10,
        )
        return getattr(response, "status_code", 201)
    except WebPushException as exc:
        status = getattr(getattr(exc, "response", None), "status_code", None)
        if status is None:
            raise
        return status


async def send_to_user(
    session: AsyncSession, user_id, payload: dict
) -> SendReport:
    """Push to every endpoint this user has registered.

    404/410 mean the push service has permanently retired that endpoint (app
    uninstalled, browser data cleared). Those rows are deleted rather than
    retried — keeping them would mean paying for a guaranteed failure on every
    future send, forever.
    """
    report = SendReport()
    if not push_enabled():
        return report

    rows = await session.execute(
        select(PushSubscription).where(PushSubscription.user_id == user_id)
    )
    subscriptions = list(rows.scalars())
    dead: list[str] = []

    for subscription in subscriptions:
        try:
            status = _send_one(subscription, payload)
        except Exception:
            logger.exception("push send failed for endpoint %s", subscription.endpoint[:60])
            subscription.failure_count += 1
            report.failed += 1
            continue

        if status in (404, 410):
            dead.append(subscription.endpoint)
            report.pruned += 1
        elif 200 <= status < 300:
            subscription.last_success_at = datetime.now(UTC)
            subscription.failure_count = 0
            report.sent += 1
        else:
            subscription.failure_count += 1
            report.failed += 1

    if dead:
        await session.execute(
            delete(PushSubscription).where(PushSubscription.endpoint.in_(dead))
        )
    await session.commit()
    return report


async def send_daily_reminders(session: AsyncSession) -> SendReport:
    """One reminder per user who has cards due and at least one subscription.

    Driven by an EventBridge schedule through the Lambda's custom-event path
    (see lambda_handler). Users with nothing due are skipped — a notification
    that says "0 cards" trains people to ignore the channel.
    """
    total = SendReport()
    if not push_enabled():
        logger.info("push disabled (no VAPID keys); skipping reminders")
        return total

    rows = await session.execute(
        text(
            """
            SELECT q.user_id, COUNT(*) AS due
            FROM quizzes q
            WHERE q.next_review_at IS NOT NULL
              AND q.next_review_at <= NOW()
              AND q.queue_kind <> 'archived'
              AND EXISTS (
                  SELECT 1 FROM push_subscriptions p WHERE p.user_id = q.user_id
              )
            GROUP BY q.user_id
            """
        )
    )
    for user_id, due in rows:
        report = await send_to_user(
            session,
            user_id,
            {
                "title": "복습할 카드가 있어요",
                "body": f"오늘 복습할 카드 {int(due)}장이 기다리고 있습니다.",
                "url": "/",
                "tag": "daily-review",
            },
        )
        total.sent += report.sent
        total.pruned += report.pruned
        total.failed += report.failed

    logger.info(
        "daily reminders: sent=%d pruned=%d failed=%d",
        total.sent,
        total.pruned,
        total.failed,
    )
    return total
