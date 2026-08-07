"""Daily quota enforcement.

The counter's whole reason for being in Postgres is that it must be correct
under concurrency across Lambda containers, so the concurrent-increment test is
the one that matters most here.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app import rate_limit
from app.config import get_settings
from app.db import async_session_factory
from app.models import User


@pytest.fixture(autouse=True)
def _reset_settings_cache():
    """Settings are lru_cached; tests that tweak limits must not leak."""
    yield
    get_settings.cache_clear()


def _set_limits(monkeypatch, **kinds: int) -> None:
    settings = get_settings()
    monkeypatch.setattr(settings, "daily_limits_free", dict(kinds), raising=False)


class TestLocalDay:
    def test_uses_the_configured_zone_not_utc(self) -> None:
        """22:00 UTC is already tomorrow in Seoul — the quota must agree."""
        late_utc = datetime(2026, 8, 7, 22, 0, tzinfo=timezone.utc)
        assert rate_limit.local_day(late_utc).isoformat() == "2026-08-08"

    def test_early_utc_is_still_the_same_local_day(self) -> None:
        early_utc = datetime(2026, 8, 7, 1, 0, tzinfo=timezone.utc)
        assert rate_limit.local_day(early_utc).isoformat() == "2026-08-07"


class TestLimitFor:
    def test_premium_gets_the_premium_table(self, monkeypatch) -> None:
        free = User(email="f@t.local", password_hash="x", subscription_tier="free")
        premium = User(
            email="p@t.local", password_hash="x", subscription_tier="premium"
        )
        assert rate_limit.limit_for(free, "quiz_gen") == 20
        assert rate_limit.limit_for(premium, "quiz_gen") == 200

    def test_unknown_kind_is_unlimited(self) -> None:
        user = User(email="u@t.local", password_hash="x", subscription_tier="free")
        assert rate_limit.limit_for(user, "not_a_counter") is None

    def test_negative_limit_disables_the_counter(self, monkeypatch) -> None:
        user = User(email="n@t.local", password_hash="x", subscription_tier="free")
        _set_limits(monkeypatch, ocr=-1)
        assert rate_limit.limit_for(user, "ocr") is None


class TestConsume:
    @pytest.mark.asyncio
    async def test_counts_up_and_reports_the_limit(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _set_limits(monkeypatch, ocr=3)
        for expected in (1, 2, 3):
            used, limit = await rate_limit.consume(
                db_session, iso_user, "ocr", commit=False
            )
            assert (used, limit) == (expected, 3)

    @pytest.mark.asyncio
    async def test_raises_once_past_the_limit(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _set_limits(monkeypatch, ocr=2)
        await rate_limit.consume(db_session, iso_user, "ocr", commit=False)
        await rate_limit.consume(db_session, iso_user, "ocr", commit=False)

        with pytest.raises(rate_limit.QuotaExceeded) as excinfo:
            await rate_limit.consume(db_session, iso_user, "ocr", commit=False)
        assert excinfo.value.limit == 2
        assert excinfo.value.used == 3
        assert excinfo.value.kind == "ocr"

    @pytest.mark.asyncio
    async def test_counters_are_independent(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _set_limits(monkeypatch, ocr=1, quiz_gen=1)
        await rate_limit.consume(db_session, iso_user, "ocr", commit=False)
        # Exhausting OCR must not touch the quiz budget.
        used, _ = await rate_limit.consume(
            db_session, iso_user, "quiz_gen", commit=False
        )
        assert used == 1

    @pytest.mark.asyncio
    async def test_an_unlimited_kind_writes_no_row(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _set_limits(monkeypatch)  # every counter unlimited
        used, limit = await rate_limit.consume(
            db_session, iso_user, "ocr", commit=False
        )
        assert (used, limit) == (0, None)
        rows = await db_session.execute(
            text("SELECT count(*) FROM usage_counters WHERE user_id = :u"),
            {"u": iso_user.id},
        )
        assert rows.scalar_one() == 0

    @pytest.mark.asyncio
    async def test_yesterdays_usage_does_not_count_against_today(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _set_limits(monkeypatch, ocr=1)
        yesterday = rate_limit.local_day() - timedelta(days=1)
        await db_session.execute(
            text(
                "INSERT INTO usage_counters (user_id, day, kind, count) "
                "VALUES (:u, :d, 'ocr', 99)"
            ),
            {"u": iso_user.id, "d": yesterday},
        )
        used, _ = await rate_limit.consume(
            db_session, iso_user, "ocr", commit=False
        )
        assert used == 1

    @pytest.mark.asyncio
    async def test_concurrent_calls_each_count_exactly_once(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        """The point of the UPSERT: N racing requests must total exactly N.

        Each task uses its OWN session, the way separate Lambda containers do —
        sharing one session would serialise them and prove nothing.
        """
        _set_limits(monkeypatch, chat=1000)
        await db_session.commit()  # make iso_user visible to the other sessions

        async def one_call() -> None:
            async with async_session_factory() as s:
                user = await s.get(User, iso_user.id)
                await rate_limit.consume(s, user, "chat")

        await asyncio.gather(*(one_call() for _ in range(25)))

        async with async_session_factory() as s:
            total = await s.execute(
                text(
                    "SELECT count FROM usage_counters "
                    "WHERE user_id = :u AND kind = 'chat' AND day = :d"
                ),
                {"u": iso_user.id, "d": rate_limit.local_day()},
            )
            assert total.scalar_one() == 25


class TestRemaining:
    @pytest.mark.asyncio
    async def test_reports_used_limit_and_remaining_per_kind(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _set_limits(monkeypatch, ocr=5)
        await rate_limit.consume(db_session, iso_user, "ocr", commit=False)
        await rate_limit.consume(db_session, iso_user, "ocr", commit=False)

        report = await rate_limit.remaining(db_session, iso_user.id, iso_user)
        assert report["ocr"] == {"used": 2, "limit": 5, "remaining": 3}

    @pytest.mark.asyncio
    async def test_unlimited_kinds_report_null_limit(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _set_limits(monkeypatch, ocr=5)
        report = await rate_limit.remaining(db_session, iso_user.id, iso_user)
        assert report["chat"] == {"used": 0, "limit": None, "remaining": None}

    @pytest.mark.asyncio
    async def test_covers_every_declared_kind(
        self, db_session: AsyncSession, iso_user: User
    ) -> None:
        report = await rate_limit.remaining(db_session, iso_user.id, iso_user)
        assert set(report) == set(rate_limit.ALL_KINDS)
