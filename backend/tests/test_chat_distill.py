"""Chat → journal distillation: extraction scoping + embedding dedup flagging."""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app import crud, chat_distill
from app.models import Node, User


def _vec(*head: float) -> list[float]:
    v = [0.0] * 1536
    for i, x in enumerate(head):
        v[i] = x
    return v


def _fake_llm(sentences: list):
    """Accept legacy list[str] or list[{text, speaker}] payloads."""
    client = SimpleNamespace()
    client.chat = SimpleNamespace()
    client.chat.completions = SimpleNamespace()
    resp = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps({"sentences": sentences})))]
    )
    client.chat.completions.create = AsyncMock(return_value=resp)
    return client


@pytest.mark.asyncio
async def test_distill_flags_existing_statement_as_duplicate(
    db_session: AsyncSession, iso_user: User
):
    # An existing Statement in the graph, embedded at a known direction.
    stmt = Node(
        user_id=iso_user.id,
        name="stmt-run",
        type="Statement",
        description=json.dumps({"content": "나는 매일 아침 조깅을 한다"}),
        name_embedding=_vec(1.0),
    )
    db_session.add(stmt)
    await db_session.commit()

    room = await crud.create_chat_session(db_session, iso_user.id)
    await crud.append_chat_messages(
        db_session,
        room,
        [
            {"role": "user", "content": "나 요즘 아침마다 조깅해."},
            {
                "role": "assistant",
                "content": "좋은 습관이네요!",
                "referenced_node_ids": [str(stmt.id)],
            },
            {"role": "user", "content": "그리고 새 카메라도 샀어."},
        ],
    )
    await db_session.commit()

    extracted = ["나는 아침마다 조깅을 한다", "새 카메라를 샀다"]
    # First sentence embeds ONTO the existing statement (distance 0 → duplicate);
    # second is orthogonal (distance 1 → new).
    dup_vec, new_vec = _vec(1.0), _vec(0.0, 1.0)

    with patch.object(chat_distill, "_get_client", return_value=_fake_llm(extracted)), patch.object(
        chat_distill, "embed_texts", AsyncMock(return_value=[dup_vec, new_vec])
    ):
        draft = await chat_distill.build_distill_draft(db_session, iso_user, room)
    await db_session.commit()

    sents = draft["sentences"]
    assert len(sents) == 2

    dup = sents[0]
    assert dup["duplicate"] is True
    assert dup["included"] is False  # duplicates start unchecked
    assert dup["matched_statement"] == "나는 매일 아침 조깅을 한다"
    assert dup["referenced"] is True  # the assistant cited this node this session
    assert dup.get("speaker", "나") == "나"

    fresh = sents[1]
    assert fresh["duplicate"] is False
    assert fresh["included"] is True
    assert fresh.get("speaker", "나") == "나"

    # Draft is persisted on the session for later refine/commit.
    reloaded = await crud.get_chat_session(db_session, iso_user.id, room.id)
    assert reloaded.distill_state["draft_id"] == draft["draft_id"]


@pytest.mark.asyncio
async def test_distill_ignores_assistant_utterances(
    db_session: AsyncSession, iso_user: User
):
    """Only the user's own words feed the extractor — RAG echoes must not leak in."""
    room = await crud.create_chat_session(db_session, iso_user.id)
    await crud.append_chat_messages(
        db_session,
        room,
        [
            {"role": "user", "content": "오늘 뭐 했더라"},
            {"role": "assistant", "content": "지난번에 부산 여행 다녀오셨다고 했어요."},
        ],
    )
    await db_session.commit()

    captured: dict = {}

    async def _capture(system, user_content):
        captured["user_content"] = user_content
        return []

    with patch.object(chat_distill, "_extract_sentences", _capture), patch.object(
        chat_distill, "embed_texts", AsyncMock(return_value=[])
    ):
        await chat_distill.build_distill_draft(db_session, iso_user, room)

    assert "오늘 뭐 했더라" in captured["user_content"]
    assert "부산 여행" not in captured["user_content"]  # assistant line excluded


@pytest.mark.asyncio
async def test_distill_accepts_speaker_tagged_sentences(
    db_session: AsyncSession, iso_user: User
):
    """Object-form keeps speaker; narration stays 나; legacy strings default to 나.

    Indirect reports ("엄마가 …래") must remain speaker=나. speaker=타인 is only
    for that person's actual first-person utterance (pipeline passthrough here).
    """
    room = await crud.create_chat_session(db_session, iso_user.id)
    await crud.append_chat_messages(
        db_session,
        room,
        [{"role": "user", "content": "엄마가 10시까지 오라고 했어. 엄마가 '나는 늦을게'라고 했어."}],
    )
    await db_session.commit()

    extracted = [
        {"text": "엄마가 10시까지 오라고 했다", "speaker": "나"},
        {"text": "나는 늦을게", "speaker": "엄마"},
        "나는 집에 있을게",
    ]
    with patch.object(chat_distill, "_get_client", return_value=_fake_llm(extracted)), patch.object(
        chat_distill, "embed_texts", AsyncMock(return_value=[_vec(0.0, 1.0), _vec(0.0, 0.0, 1.0), _vec(1.0)])
    ):
        draft = await chat_distill.build_distill_draft(db_session, iso_user, room)

    sents = draft["sentences"]
    assert sents[0]["speaker"] == "나"
    assert "엄마가" in sents[0]["text"]
    assert sents[1]["speaker"] == "엄마"
    assert sents[1]["text"] == "나는 늦을게"
    assert sents[2]["speaker"] == "나"
    assert sents[2]["text"] == "나는 집에 있을게"
