"""Graph-chat prompt assembly and retrieval context quality."""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app import crud, graph_chat


def _unit_vec(dim: int = 1536, hot: int = 0) -> list[float]:
    v = [0.0] * dim
    v[hot] = 1.0
    return v


def _near(hot: int = 0) -> list[float]:
    v = _unit_vec(hot=hot)
    v[(hot + 1) % len(v)] = 0.05
    return v


def test_build_graph_chat_messages_order_with_summary():
    messages = graph_chat.build_graph_chat_messages(
        message="새 질문",
        history=[{"role": "user", "content": "안녕"}],
        context="사용자의 일기 기억:\n- 코딩",
        summary="- 이전에 인사함",
    )
    roles = [m["role"] for m in messages]
    contents = [m["content"] for m in messages]
    assert roles == ["system", "system", "user", "system", "user"]
    assert "일기를 기억하는" in contents[0]
    assert "지금까지의 대화 요약" in contents[1]
    assert contents[2] == "안녕"
    assert "일기 기억" in contents[3]
    assert contents[4] == "새 질문"


def test_build_graph_chat_messages_omits_summary_when_none():
    messages = graph_chat.build_graph_chat_messages(
        message="hi",
        history=[],
        context="ctx",
        summary=None,
    )
    assert len(messages) == 3
    assert not any(m["content"].startswith("지금까지의 대화 요약") for m in messages)
    assert messages[1]["content"] == "ctx"


@pytest.mark.asyncio
async def test_graph_chat_answer_passes_reordered_messages(db_session, iso_user, monkeypatch):
    captured: dict = {}

    async def fake_create(**kwargs):
        captured["messages"] = kwargs["messages"]
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content="ok"))],
            usage=SimpleNamespace(
                prompt_tokens=10,
                completion_tokens=2,
                total_tokens=12,
                prompt_tokens_details=SimpleNamespace(cached_tokens=5),
            ),
        )

    client = SimpleNamespace()
    client.chat = SimpleNamespace()
    client.chat.completions = SimpleNamespace()
    client.chat.completions.create = fake_create

    monkeypatch.setattr(graph_chat, "_get_client", lambda: client)
    monkeypatch.setattr(graph_chat, "_retrieve_seeds", AsyncMock(return_value=([], None)))

    await graph_chat.graph_chat_answer(
        db_session,
        iso_user,
        "질문",
        [{"role": "user", "content": "이전"}],
        summary="- 요약본",
    )

    roles = [m["role"] for m in captured["messages"]]
    assert roles.index("system") < roles.index("user")
    assert captured["messages"][1]["content"].startswith("지금까지의 대화 요약")
    assert "관련된" in captured["messages"][-2]["content"] or "일기 기억" in captured["messages"][-2]["content"]


@pytest.mark.asyncio
async def test_retrieve_seeds_sorted_by_distance(db_session, iso_user, monkeypatch):
    near = await crud._get_or_create_node(
        db_session, name="가까움", type_="Concept", user_id=iso_user.id
    )
    near.name_embedding = _unit_vec(hot=1)
    far = await crud._get_or_create_node(
        db_session, name="멀음", type_="Concept", user_id=iso_user.id
    )
    far.name_embedding = _unit_vec(hot=2)
    await db_session.commit()

    async def fake_embed(_text: str) -> list[float]:
        return _near(hot=1)

    monkeypatch.setattr(graph_chat, "embed_text", fake_embed)

    seeds, _query_vec = await graph_chat._retrieve_seeds(db_session, iso_user.id, "query")
    assert seeds and seeds[0].id == near.id


@pytest.mark.asyncio
async def test_build_context_concept_seed_surfaces_linked_statement_content(db_session, iso_user):
    """Case A regression: a Concept seed must pull its linked Statement's actual
    sentence, not leave it as a short-label triple. This is the exact bug the
    graph_retrieval.py Context Package refactor fixed — graph_chat used to only
    do this for Identity seeds, silently dropping Concept-seeded statement bodies."""
    concept = await crud._get_or_create_node(
        db_session, name="Basel III", type_="Concept", user_id=iso_user.id
    )
    stmt = await crud._get_or_create_node(
        db_session,
        name="규제 자본 요건",  # short label — must NOT be all the model sees
        type_="Statement",
        description=json.dumps(
            {"context_type": "업무", "content": "Basel III 규제 자본 요건에 맞춰 수정안을 준비했다."}
        ),
        user_id=iso_user.id,
    )
    await crud.create_edge(
        db_session, source_id=stmt.id, target_id=concept.id,
        relation="CONTEXT", user_id=iso_user.id,
    )
    await db_session.commit()

    ranked = await graph_chat._build_context(db_session, iso_user.id, [concept])
    ctx = ranked.text

    assert "Basel III 규제 자본 요건에 맞춰 수정안을 준비했다." in ctx
    assert "연관 개념: Basel III" in ctx


async def _append_many_pairs(db_session, room, pairs: int) -> None:
    for i in range(pairs):
        await crud.append_chat_messages(
            db_session,
            room,
            [
                {"role": "user", "content": f"u{i}"},
                {"role": "assistant", "content": f"a{i}"},
            ],
        )


@pytest.mark.asyncio
async def test_send_message_schedules_summary_background_task(db_session, iso_user, monkeypatch):
    from app.routers import graph_chat as graph_chat_router
    from app.schemas import GraphChatRequest

    room = await crud.create_chat_session(db_session, iso_user.id)
    await _append_many_pairs(db_session, room, 10)
    await db_session.commit()

    scheduled: list = []
    bg = SimpleNamespace(add_task=lambda fn, *args: scheduled.append((fn, args)))

    monkeypatch.setattr(
        graph_chat_router,
        "graph_chat_answer",
        AsyncMock(
            return_value=graph_chat.GraphChatResult(answer="ok", referenced_node_ids=[])
        ),
    )

    await graph_chat_router.send_message(
        room.id,
        GraphChatRequest(message="one more"),
        bg,
        iso_user,
        db_session,
    )

    assert scheduled
    assert scheduled[0][0].__name__ == "update_session_summary"
