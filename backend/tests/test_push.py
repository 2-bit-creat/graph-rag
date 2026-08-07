"""Web Push delivery — pruning, failure accounting, and the disabled path.

pywebpush itself is stubbed; what matters here is what the app does with each
status the push service can return.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import push as push_mod
from app.config import get_settings
from app.models import PushSubscription, User


@pytest.fixture(autouse=True)
def _reset_settings_cache():
    yield
    get_settings.cache_clear()


def _enable(monkeypatch) -> None:
    settings = get_settings()
    monkeypatch.setattr(settings, "vapid_public_key", "pub", raising=False)
    monkeypatch.setattr(settings, "vapid_private_key", "priv", raising=False)


async def _add_sub(session: AsyncSession, user: User, endpoint: str) -> PushSubscription:
    """Add a subscription with a run-unique endpoint.

    send_to_user commits, so these rows outlive db_session's rollback. A fixed
    endpoint string would therefore collide with the previous run on the unique
    index — the suffix keeps each run independent.
    """
    sub = PushSubscription(
        id=uuid.uuid4(),
        user_id=user.id,
        endpoint=f"{endpoint}-{uuid.uuid4().hex[:12]}",
        p256dh="key",
        auth="auth",
    )
    session.add(sub)
    await session.flush()
    return sub


class TestPushEnabled:
    def test_requires_both_keys(self, monkeypatch) -> None:
        settings = get_settings()
        monkeypatch.setattr(settings, "vapid_public_key", "pub", raising=False)
        monkeypatch.setattr(settings, "vapid_private_key", "", raising=False)
        assert push_mod.push_enabled() is False

        monkeypatch.setattr(settings, "vapid_private_key", "priv", raising=False)
        assert push_mod.push_enabled() is True


class TestSendToUser:
    @pytest.mark.asyncio
    async def test_disabled_config_sends_nothing_and_does_not_raise(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        settings = get_settings()
        monkeypatch.setattr(settings, "vapid_private_key", "", raising=False)
        await _add_sub(db_session, iso_user, "https://push.example/a")

        report = await push_mod.send_to_user(db_session, iso_user.id, {"title": "x"})
        assert (report.sent, report.pruned, report.failed) == (0, 0, 0)

    @pytest.mark.asyncio
    async def test_successful_send_stamps_last_success(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _enable(monkeypatch)
        sub = await _add_sub(db_session, iso_user, "https://push.example/ok")
        sub.failure_count = 3
        monkeypatch.setattr(push_mod, "_send_one", lambda s, p: 201)

        report = await push_mod.send_to_user(db_session, iso_user.id, {"title": "x"})
        assert report.sent == 1
        await db_session.refresh(sub)
        assert sub.last_success_at is not None
        # A success clears the accumulated failure count.
        assert sub.failure_count == 0

    @pytest.mark.asyncio
    @pytest.mark.parametrize("status", [404, 410])
    async def test_gone_endpoints_are_deleted_not_retried(
        self, db_session: AsyncSession, iso_user: User, monkeypatch, status: int
    ) -> None:
        _enable(monkeypatch)
        await _add_sub(db_session, iso_user, f"https://push.example/dead{status}")
        monkeypatch.setattr(push_mod, "_send_one", lambda s, p: status)

        report = await push_mod.send_to_user(db_session, iso_user.id, {"title": "x"})
        assert report.pruned == 1

        rows = await db_session.execute(
            select(PushSubscription).where(PushSubscription.user_id == iso_user.id)
        )
        assert rows.scalars().first() is None

    @pytest.mark.asyncio
    async def test_transient_failure_increments_but_keeps_the_row(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _enable(monkeypatch)
        sub = await _add_sub(db_session, iso_user, "https://push.example/500")
        monkeypatch.setattr(push_mod, "_send_one", lambda s, p: 500)

        report = await push_mod.send_to_user(db_session, iso_user.id, {"title": "x"})
        assert (report.failed, report.pruned) == (1, 0)
        await db_session.refresh(sub)
        assert sub.failure_count == 1

    @pytest.mark.asyncio
    async def test_one_broken_endpoint_does_not_stop_the_others(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _enable(monkeypatch)
        await _add_sub(db_session, iso_user, "https://push.example/boom")
        await _add_sub(db_session, iso_user, "https://push.example/fine")

        def _send(sub, payload):
            if "boom" in sub.endpoint:
                raise RuntimeError("transport exploded")
            return 201

        monkeypatch.setattr(push_mod, "_send_one", _send)

        report = await push_mod.send_to_user(db_session, iso_user.id, {"title": "x"})
        assert (report.sent, report.failed) == (1, 1)

    @pytest.mark.asyncio
    async def test_only_the_target_users_endpoints_are_used(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        _enable(monkeypatch)
        other = User(
            id=uuid.uuid4(), email=f"o-{uuid.uuid4().hex[:8]}@t.local", password_hash="x"
        )
        db_session.add(other)
        await db_session.flush()
        mine = await _add_sub(db_session, iso_user, "https://push.example/mine")
        await _add_sub(db_session, other, "https://push.example/theirs")

        seen: list[str] = []

        def _send(sub, payload):
            seen.append(sub.endpoint)
            return 201

        monkeypatch.setattr(push_mod, "_send_one", _send)
        try:
            await push_mod.send_to_user(db_session, iso_user.id, {"title": "x"})
            assert seen == [mine.endpoint]
        finally:
            # send_to_user committed, so this user is not covered by any
            # fixture rollback. Its subscription cascades with it.
            from sqlalchemy import delete as sa_delete

            await db_session.execute(sa_delete(User).where(User.id == other.id))
            await db_session.commit()


class TestDailyReminders:
    @pytest.mark.asyncio
    async def test_disabled_config_is_a_no_op(
        self, db_session: AsyncSession, monkeypatch
    ) -> None:
        settings = get_settings()
        monkeypatch.setattr(settings, "vapid_private_key", "", raising=False)
        report = await push_mod.send_daily_reminders(db_session)
        assert (report.sent, report.failed) == (0, 0)

    @pytest.mark.asyncio
    async def test_user_with_no_due_cards_gets_nothing(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        """A "0 cards due" notification trains people to ignore the channel."""
        from datetime import UTC, datetime, timedelta

        from app.models import Quiz

        _enable(monkeypatch)
        await _add_sub(db_session, iso_user, "https://push.example/idle")
        db_session.add(
            Quiz(
                quiz_type="cloze",
                user_id=iso_user.id,
                queue_kind="review",
                next_review_at=datetime.now(UTC) + timedelta(days=5),
            )
        )
        await db_session.commit()

        monkeypatch.setattr(push_mod, "_send_one", lambda s, p: 201)
        report = await push_mod.send_daily_reminders(db_session)
        assert report.sent == 0

    @pytest.mark.asyncio
    async def test_user_with_due_cards_is_notified_once(
        self, db_session: AsyncSession, iso_user: User, monkeypatch
    ) -> None:
        from datetime import UTC, datetime, timedelta

        from app.models import Quiz

        _enable(monkeypatch)
        await _add_sub(db_session, iso_user, "https://push.example/due")
        for _ in range(3):
            db_session.add(
                Quiz(
                    quiz_type="cloze",
                    user_id=iso_user.id,
                    queue_kind="review",
                    next_review_at=datetime.now(UTC) - timedelta(days=1),
                )
            )
        await db_session.commit()

        payloads: list[dict] = []

        def _send(sub, payload):
            payloads.append(payload)
            return 201

        monkeypatch.setattr(push_mod, "_send_one", _send)
        report = await push_mod.send_daily_reminders(db_session)

        assert report.sent == 1
        # Three due cards, one notification carrying the count.
        assert len(payloads) == 1
        assert "3" in payloads[0]["body"]
