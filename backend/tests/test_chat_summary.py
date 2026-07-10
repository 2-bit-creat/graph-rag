"""Rolling chat summary: trigger logic, incremental updates, failure handling."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app import crud
from app.chat_summary import (
    apply_summary_update,
    needs_summary_update,
    watermark_from_state,
)
from app.models import User


def _fake_summary_llm(text: str = "- 사용자가 코딩을 좋아함"):
    client = SimpleNamespace()
    client.chat = SimpleNamespace()
    client.chat.completions = SimpleNamespace()
    resp = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=text))],
        usage=SimpleNamespace(
            prompt_tokens=100,
            completion_tokens=50,
            total_tokens=150,
            prompt_tokens_details=SimpleNamespace(cached_tokens=0),
        ),
    )
    client.chat.completions.create = AsyncMock(return_value=resp)
    return client


async def _seed_text_turns(
    db_session: AsyncSession,
    room,
    count: int,
    *,
    base: datetime | None = None,
) -> list:
    """Append ``count`` user+assistant pairs (2*count messages)."""
    base = base or datetime.now(UTC)
    rows = []
    for i in range(count):
        pair = await crud.append_chat_messages(
            db_session,
            room,
            [
                {"role": "user", "content": f"user-{i}"},
                {"role": "assistant", "content": f"assistant-{i}"},
            ],
        )
        for j, row in enumerate(pair):
            row.created_at = base + timedelta(seconds=i * 2 + j)
        rows.extend(pair)
    await db_session.flush()
    return rows


@pytest.mark.parametrize(
    "count,expected",
    [
        (20, False),
        (21, True),
        (40, True),
    ],
)
def test_needs_summary_update_trigger(count: int, expected: bool):
    assert needs_summary_update(count, history_turns=12, batch=8, enabled=True) is expected
    assert needs_summary_update(count, enabled=False) is False


def test_watermark_from_state_none_and_present():
    assert watermark_from_state(None) is None
    assert watermark_from_state({}) is None
    ts = datetime(2026, 1, 1, tzinfo=UTC)
    assert watermark_from_state({"upto_created_at": ts.isoformat()}) == ts


@pytest.mark.asyncio
async def test_apply_summary_update_writes_state(db_session: AsyncSession, iso_user: User):
    room = await crud.create_chat_session(db_session, iso_user.id)
    await db_session.commit()

    all_rows = await _seed_text_turns(db_session, room, 11)
    await db_session.commit()

    fake = _fake_summary_llm("- 첫 요약")
    with patch("app.chat_summary._get_client", return_value=fake):
        updated = await apply_summary_update(db_session, room)
    assert updated is True
    await db_session.commit()

    reloaded = await crud.get_chat_session(db_session, iso_user.id, room.id)
    state = reloaded.summary_state
    assert state is not None
    assert state["text"] == "- 첫 요약"
    assert state["covered_count"] == 8
    assert state["upto_message_id"] == str(all_rows[7].id)

    wm = watermark_from_state(state)
    after = await crud.list_chat_messages(
        db_session, room.id, kinds=["text"], after=wm, limit=50
    )
    assert len(after) == 14
    assert after[0].content == "user-4"
    assert after[-1].content == "assistant-10"


@pytest.mark.asyncio
async def test_apply_summary_update_incremental_includes_prior_summary(
    db_session: AsyncSession, iso_user: User
):
    room = await crud.create_chat_session(db_session, iso_user.id)
    await _seed_text_turns(db_session, room, 11)
    await db_session.commit()

    with patch("app.chat_summary._get_client", return_value=_fake_summary_llm("- 1차")):
        await apply_summary_update(db_session, room)
    await db_session.commit()

    reloaded = await crud.get_chat_session(db_session, iso_user.id, room.id)
    wm = watermark_from_state(reloaded.summary_state)
    await _seed_text_turns(db_session, room, 5, base=wm + timedelta(seconds=100))
    await db_session.commit()

    captured: dict = {}

    async def capture_create(**kwargs):
        captured["messages"] = kwargs["messages"]
        return _fake_summary_llm("- 2차").chat.completions.create.return_value

    fake = _fake_summary_llm("- 2차")
    fake.chat.completions.create = capture_create

    with patch("app.chat_summary._get_client", return_value=fake):
        await apply_summary_update(db_session, room)

    user_msg = captured["messages"][1]["content"]
    assert "[기존 요약]" in user_msg
    assert "- 1차" in user_msg
    assert "user-4" in user_msg


@pytest.mark.asyncio
async def test_apply_summary_update_llm_failure_keeps_state(
    db_session: AsyncSession, iso_user: User
):
    room = await crud.create_chat_session(db_session, iso_user.id)
    await _seed_text_turns(db_session, room, 11)
    await db_session.commit()

    prior_state = {
        "text": "- 기존",
        "upto_message_id": "00000000-0000-0000-0000-000000000001",
        "upto_created_at": datetime(2020, 1, 1, tzinfo=UTC).isoformat(),
        "covered_count": 3,
    }
    await crud.set_chat_session_summary_state(db_session, room, prior_state)
    await db_session.commit()

    client = SimpleNamespace()
    client.chat = SimpleNamespace()
    client.chat.completions = SimpleNamespace()
    client.chat.completions.create = AsyncMock(side_effect=RuntimeError("boom"))

    with patch("app.chat_summary._get_client", return_value=client):
        updated = await apply_summary_update(db_session, room)

    assert updated is False
    reloaded = await crud.get_chat_session(db_session, iso_user.id, room.id)
    assert reloaded.summary_state == prior_state


@pytest.mark.asyncio
async def test_apply_summary_update_concurrent_watermark_noop(
    db_session: AsyncSession, iso_user: User
):
    room = await crud.create_chat_session(db_session, iso_user.id)
    rows = await _seed_text_turns(db_session, room, 11)
    await db_session.commit()

    moved_state = {
        "text": "- 이미 갱신됨",
        "upto_message_id": str(rows[7].id),
        "upto_created_at": rows[7].created_at.isoformat(),
        "covered_count": 8,
    }
    await crud.set_chat_session_summary_state(db_session, room, moved_state)
    await db_session.commit()

    fake = _fake_summary_llm("- 새 요약")
    with patch("app.chat_summary._get_client", return_value=fake):
        updated = await apply_summary_update(db_session, room)

    assert updated is False
    reloaded = await crud.get_chat_session(db_session, iso_user.id, room.id)
    assert reloaded.summary_state["text"] == "- 이미 갱신됨"
