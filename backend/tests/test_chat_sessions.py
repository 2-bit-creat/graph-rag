"""Chat-session store: multi-room CRUD, ordering, cascade delete."""

from __future__ import annotations

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import crud
from app.models import ChatMessage, ChatSession, User


@pytest.mark.asyncio
async def test_session_crud_and_message_ordering(
    db_session: AsyncSession, iso_user: User
):
    # Two rooms; second created later.
    a = await crud.create_chat_session(db_session, iso_user.id, title="첫 방")
    b = await crud.create_chat_session(db_session, iso_user.id)
    await db_session.commit()

    # Append a user+assistant pair to room A in one batch.
    appended = await crud.append_chat_messages(
        db_session,
        a,
        [
            {"role": "user", "content": "마야 얘기 했었나?"},
            {
                "role": "assistant",
                "content": "응, 마야는 고양이야.",
                "referenced_node_ids": ["n1", "n2"],
            },
        ],
    )
    await db_session.commit()
    assert appended[0].created_at < appended[1].created_at  # stable batch ordering

    msgs = await crud.list_chat_messages(db_session, a.id)
    assert [m.role for m in msgs] == ["user", "assistant"]
    assert msgs[1].referenced_node_ids == ["n1", "n2"]

    # Preview = latest content.
    assert await crud.last_message_preview(db_session, a.id) == "응, 마야는 고양이야."

    # Appending bumps updated_at → room A floats above room B in the sidebar.
    rooms = await crud.list_chat_sessions(db_session, iso_user.id)
    assert rooms[0].id == a.id

    # kind filter excludes non-text records from RAG history.
    await crud.append_chat_messages(
        db_session, a, [{"role": "assistant", "kind": "quiz_prompt", "content": "Q"}]
    )
    await db_session.commit()
    text_only = await crud.list_chat_messages(db_session, a.id, kinds=["text"])
    assert all(m.kind == "text" for m in text_only)
    assert len(text_only) == 2

    # Rename + delete cascade.
    await crud.rename_chat_session(db_session, b, "두 번째 방")
    await db_session.commit()
    assert (await crud.get_chat_session(db_session, iso_user.id, b.id)).title == "두 번째 방"

    await crud.delete_chat_session(db_session, a)
    await db_session.commit()
    assert await crud.get_chat_session(db_session, iso_user.id, a.id) is None
    leftover = (
        await db_session.execute(
            select(ChatMessage).where(ChatMessage.session_id == a.id)
        )
    ).scalars().all()
    assert leftover == []  # ON DELETE CASCADE removed the messages


@pytest.mark.asyncio
async def test_distill_state_roundtrip(db_session: AsyncSession, iso_user: User):
    s = await crud.create_chat_session(db_session, iso_user.id)
    await db_session.commit()
    state = {"sentences": [{"text": "오늘 코딩했다", "included": True}]}
    await crud.set_chat_session_distill_state(db_session, s, state)
    await db_session.commit()
    reloaded = await crud.get_chat_session(db_session, iso_user.id, s.id)
    assert reloaded.distill_state == state
    await crud.set_chat_session_distill_state(db_session, s, None)
    await db_session.commit()
    reloaded = await crud.get_chat_session(db_session, iso_user.id, s.id)
    assert reloaded.distill_state is None
