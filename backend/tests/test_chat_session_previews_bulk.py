"""Sidebar previews are resolved for every room in one pass.

`GET /graph/chat/sessions` used to call `last_message_preview` per room, which
at ~50 rooms made it the slowest call in the app's cold start — and the chat
history fetch cannot begin until it returns. `last_message_previews` answers the
whole list at once; it must agree with the per-room function it replaced.
"""

from __future__ import annotations

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app import crud
from app.models import User


@pytest.mark.asyncio
async def test_bulk_previews_match_the_per_room_function(
    db_session: AsyncSession, iso_user: User
):
    rooms = []
    for i in range(5):
        room = await crud.create_chat_session(db_session, iso_user.id, title=f"방{i}")
        await crud.append_chat_messages(
            db_session,
            room,
            [
                {"role": "user", "content": f"질문 {i}"},
                {"role": "assistant", "content": f"답변 {i}"},
            ],
        )
        rooms.append(room)
    # A room with no messages at all must resolve to None, not raise.
    empty = await crud.create_chat_session(db_session, iso_user.id, title="빈 방")
    rooms.append(empty)
    await db_session.commit()

    ids = [r.id for r in rooms]
    bulk = await crud.last_message_previews(db_session, ids, user_id=iso_user.id)

    for room in rooms:
        one = await crud.last_message_preview(
            db_session, room.id, user_id=iso_user.id
        )
        assert bulk[room.id] == one, f"mismatch for {room.title}"

    assert bulk[rooms[0].id] == "답변 0"
    assert bulk[empty.id] is None
    # Every requested room gets a key, so the route can index without a guard.
    assert set(bulk) == set(ids)


@pytest.mark.asyncio
async def test_bulk_previews_take_the_latest_message_per_room(
    db_session: AsyncSession, iso_user: User
):
    a = await crud.create_chat_session(db_session, iso_user.id, title="A")
    b = await crud.create_chat_session(db_session, iso_user.id, title="B")
    await crud.append_chat_messages(
        db_session,
        a,
        [{"role": "user", "content": "옛날"}, {"role": "assistant", "content": "최신 A"}],
    )
    await crud.append_chat_messages(
        db_session,
        b,
        [{"role": "user", "content": "옛날"}, {"role": "assistant", "content": "최신 B"}],
    )
    await db_session.commit()

    bulk = await crud.last_message_previews(db_session, [a.id, b.id])

    # Rooms must not bleed into each other — the window is per session_id.
    assert bulk[a.id] == "최신 A"
    assert bulk[b.id] == "최신 B"


@pytest.mark.asyncio
async def test_bulk_previews_skip_empty_content(
    db_session: AsyncSession, iso_user: User
):
    room = await crud.create_chat_session(db_session, iso_user.id, title="공백")
    await crud.append_chat_messages(
        db_session,
        room,
        [
            {"role": "user", "content": "실제 내용"},
            {"role": "assistant", "content": "   "},
        ],
    )
    await db_session.commit()

    bulk = await crud.last_message_previews(db_session, [room.id])

    assert bulk[room.id] == "실제 내용"


@pytest.mark.asyncio
async def test_bulk_previews_of_nothing_is_empty(db_session: AsyncSession):
    assert await crud.last_message_previews(db_session, []) == {}
