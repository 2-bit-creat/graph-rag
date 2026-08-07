"""Per-user daily quotas for the endpoints that cost real money.

Every counted endpoint either calls an LLM, Whisper, or Textract. Before this
existed there was no ceiling of any kind, and the Lambda Function URL is
``AuthType: NONE`` — the only thing between an attacker and an unbounded gpt-4o
bill was that nobody had tried.

The counter is a single atomic UPSERT (see UsageCounter's docstring for why
Postgres and not Redis). Consumption happens *before* the work, so a request
that fails downstream still counts: the money is spent at the provider either
way, and a failure that refunds quota is a retry loop waiting to happen.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from zoneinfo import ZoneInfo

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import User

# Counter names. Endpoints that share a budget share a kind — the three quiz
# generation routes are one wallet, because they cost the same thing.
KIND_QUIZ_GEN = "quiz_gen"
KIND_KG_EXTRACT = "kg_extract"
KIND_OCR = "ocr"
KIND_CHAT = "chat"
KIND_STT = "stt"

ALL_KINDS = (KIND_QUIZ_GEN, KIND_KG_EXTRACT, KIND_OCR, KIND_CHAT, KIND_STT)


def local_day(now: datetime | None = None) -> date:
    """Today's date in the app's configured timezone.

    Quotas that reset at UTC midnight reset at 9am in Seoul — mid-morning, in
    the middle of a study session. Reset at local midnight instead.
    """
    tz = ZoneInfo(get_settings().chat_timezone)
    moment = now.astimezone(tz) if now is not None else datetime.now(tz)
    return moment.date()


def limit_for(user: User, kind: str) -> int | None:
    """The daily allowance for this user and counter. None means unlimited."""
    settings = get_settings()
    tier = (getattr(user, "subscription_tier", "free") or "free").strip().lower()
    limits = (
        settings.daily_limits_premium if tier == "premium" else settings.daily_limits_free
    )
    value = limits.get(kind)
    if value is None or value < 0:
        return None
    return value


class QuotaExceeded(Exception):
    """Raised when the caller has used their allowance for the day."""

    def __init__(self, kind: str, limit: int, used: int) -> None:
        super().__init__(f"daily quota exhausted for {kind}: {used}/{limit}")
        self.kind = kind
        self.limit = limit
        self.used = used


_INCREMENT_SQL = text(
    """
    INSERT INTO usage_counters (user_id, day, kind, count)
    VALUES (:user_id, :day, :kind, 1)
    ON CONFLICT (user_id, day, kind)
    DO UPDATE SET count = usage_counters.count + 1
    RETURNING count
    """
)


async def consume(
    session: AsyncSession,
    user: User,
    kind: str,
    *,
    commit: bool = True,
) -> tuple[int, int | None]:
    """Count one call against ``kind``. Returns (used_after, limit).

    Raises QuotaExceeded when this call would go past the allowance. The row is
    still incremented in that case — the increment and the check are the same
    statement, which is what makes it race-free — so a caller hammering an
    exhausted quota keeps climbing. That is intentional: the count doubles as an
    abuse signal, and the limit comparison uses > not >=.
    """
    limit = limit_for(user, kind)
    if limit is None:
        return 0, None

    result = await session.execute(
        _INCREMENT_SQL,
        {"user_id": user.id, "day": local_day(), "kind": kind},
    )
    used = int(result.scalar_one())
    # The counter must survive the request even when the handler later raises,
    # otherwise a rolled-back transaction hands the quota straight back.
    if commit:
        await session.commit()

    if used > limit:
        raise QuotaExceeded(kind, limit, used)
    return used, limit


async def remaining(
    session: AsyncSession, user_id: uuid.UUID, user: User
) -> dict[str, dict[str, int | None]]:
    """Today's usage per counter, for surfacing before the learner hits 429."""
    rows = await session.execute(
        text(
            "SELECT kind, count FROM usage_counters "
            "WHERE user_id = :user_id AND day = :day"
        ),
        {"user_id": user_id, "day": local_day()},
    )
    used_by_kind = {row[0]: int(row[1]) for row in rows}

    out: dict[str, dict[str, int | None]] = {}
    for kind in ALL_KINDS:
        limit = limit_for(user, kind)
        used = used_by_kind.get(kind, 0)
        out[kind] = {
            "used": used,
            "limit": limit,
            "remaining": None if limit is None else max(0, limit - used),
        }
    return out
