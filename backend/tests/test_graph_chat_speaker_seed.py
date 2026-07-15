"""graph_chat_answer / _retrieve_speaker_seeds — deterministic speaker-exact
seeding for the reproduced bug: "하승목 연구원이 어떤 질문을 했었지? 성장성
모형 관련해서" must surface 하승목연구원's SPOKE_OR_PUBLISHED statement even
though the compound query's embedding would miss it under the similarity
cutoff. Embeddings are mocked to point AWAY from the statement so passing
tests only through the exact-match path (not embedding luck) is verifiable.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app import crud, graph_chat, rag
from app.models import NodeAliasEmbedding


def _unit_vec(dim: int = 1536, hot: int = 0) -> list[float]:
    v = [0.0] * dim
    v[hot] = 1.0
    return v


@pytest.mark.asyncio
async def test_speaker_exact_match_seeds_statement_even_with_orthogonal_embedding(
    db_session, iso_user, monkeypatch
):
    speaker = await crud._get_or_create_node(
        db_session, name="하승목연구원", type_="Person", user_id=iso_user.id
    )
    stmt = await crud._get_or_create_node(
        db_session,
        name="성장성 모형 질문",
        type_="Statement",
        description=json.dumps(
            {"context_type": "회의록", "content": "성장성 모형 관련해서 질문함"}
        ),
        user_id=iso_user.id,
    )
    # Orthogonal embedding: nowhere near whatever the (mocked) query vector is,
    # so if this statement is retrieved it MUST be via the exact-match path.
    stmt.name_embedding = _unit_vec(hot=500)
    await crud.create_edge(
        db_session, source_id=speaker.id, target_id=stmt.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    await db_session.commit()

    # Pre-seed the alias embedding index so the lazy backfill in
    # graph_chat_answer is a no-op and never makes a real embedding call.
    db_session.add(
        NodeAliasEmbedding(
            user_id=iso_user.id, node_id=speaker.id,
            text="하승목연구원", embedding=_unit_vec(hot=42),
        )
    )
    await db_session.commit()

    captured_embed_calls: list[str] = []

    async def fake_embed(text: str) -> list[float]:
        captured_embed_calls.append(text)
        return _unit_vec(hot=1)  # orthogonal to stmt's hot=500

    async def fake_create(**kwargs):
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content="ok"))],
        )

    client = SimpleNamespace()
    client.chat = SimpleNamespace()
    client.chat.completions = SimpleNamespace()
    client.chat.completions.create = fake_create

    monkeypatch.setattr(graph_chat, "embed_text", fake_embed)
    monkeypatch.setattr(rag, "embed_text", fake_embed)
    monkeypatch.setattr(graph_chat, "_get_client", lambda: client)

    result = await graph_chat.graph_chat_answer(
        db_session,
        iso_user,
        "하승목 연구원이 어떤 질문을 했었지? 성장성 모형 관련해서",
        [],
    )

    assert str(stmt.id) in result.referenced_node_ids
    assert str(speaker.id) in result.referenced_node_ids
    # The embedded text must have had the speaker name stripped (질의 분해) —
    # asserts the residual, not the raw message, reached embed_text.
    assert captured_embed_calls
    assert "하승목" not in captured_embed_calls[0]


@pytest.mark.asyncio
async def test_no_speaker_detected_falls_back_to_embedding_only(
    db_session, iso_user, monkeypatch
):
    """No identity name present in the message → behaves exactly as before
    (regression guard for the non-speaker path)."""

    async def fake_embed(text: str) -> list[float]:
        return _unit_vec(hot=1)

    async def fake_create(**kwargs):
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content="ok"))],
        )

    client = SimpleNamespace()
    client.chat = SimpleNamespace()
    client.chat.completions = SimpleNamespace()
    client.chat.completions.create = fake_create

    monkeypatch.setattr(graph_chat, "embed_text", fake_embed)
    monkeypatch.setattr(graph_chat, "_get_client", lambda: client)

    result = await graph_chat.graph_chat_answer(
        db_session, iso_user, "오늘 날씨가 좋다", []
    )
    assert result.answer == "ok"
    assert result.referenced_node_ids == []


@pytest.mark.asyncio
async def test_speaker_seed_limit_zero_disables_feature(
    db_session, iso_user, monkeypatch
):
    from app.config import get_settings

    speaker = await crud._get_or_create_node(
        db_session, name="하승목연구원", type_="Person", user_id=iso_user.id
    )
    stmt = await crud._get_or_create_node(
        db_session,
        name="성장성 모형 질문",
        type_="Statement",
        description=json.dumps({"context_type": "회의록", "content": "질문 내용"}),
        user_id=iso_user.id,
    )
    stmt.name_embedding = _unit_vec(hot=500)
    await crud.create_edge(
        db_session, source_id=speaker.id, target_id=stmt.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    await db_session.commit()

    settings = get_settings()
    monkeypatch.setattr(settings, "graph_chat_speaker_seed_limit", 0)
    monkeypatch.setattr(graph_chat, "get_settings", lambda: settings)

    matches, residual = await graph_chat._scan_speaker_matches(
        db_session, iso_user.id, "하승목 연구원이 뭐라고 했지?"
    )
    assert matches == []
    assert residual == "하승목 연구원이 뭐라고 했지?"
