"""Graph-chat identity seeding + context body-ing.

Identity heads (사람·기업/출처·반려동물) carry no ``Node.name_embedding`` — their
surface forms live in ``node_alias_embeddings``. Retrieval must seed from that index
too so "마야가 누구야?" finds the 마야 node itself, and the built context must carry the
identity's description plus the neighbouring statement bodies (not just short labels).

Uses one-hot vectors so no live embedding calls are needed (see
test_person_mention_resolution._unit_vec for the same trick).
"""

from __future__ import annotations

import json

import pytest

from app import crud, graph_chat
from app.models import NodeAliasEmbedding


def _unit_vec(dim: int = 1536, hot: int = 0) -> list[float]:
    v = [0.0] * dim
    v[hot] = 1.0
    return v


def _near(hot: int = 0) -> list[float]:
    """A vector cosine-close to the one-hot at ``hot`` (distance well under any cutoff)."""
    v = _unit_vec(hot=hot)
    v[(hot + 1) % len(v)] = 0.05
    return v


@pytest.mark.asyncio
async def test_find_identities_by_alias_embedding_dedups_by_node(db_session, iso_user):
    """Two aliases of one identity, both near the query → a single deduped node."""
    node = await crud._get_or_create_node(
        db_session, name="마야", type_="Identity", user_id=iso_user.id
    )
    for text in ("마야", "마야가"):
        db_session.add(NodeAliasEmbedding(
            user_id=iso_user.id, node_id=node.id, text=text, embedding=_unit_vec(hot=0),
        ))
    await db_session.commit()

    hits = await crud.find_identities_by_alias_embedding(
        db_session, iso_user.id, _near(hot=0)
    )
    assert len(hits) == 1                      # one row per node, not per alias
    assert hits[0][0].id == node.id

    # Orthogonal query stays out under the distance cutoff.
    assert await crud.find_identities_by_alias_embedding(
        db_session, iso_user.id, _unit_vec(hot=9), max_distance=0.5
    ) == []


@pytest.mark.asyncio
async def test_find_similar_nodes_with_distance_exposes_distance(db_session, iso_user):
    node = await crud._get_or_create_node(
        db_session, name="불안", type_="Concept", user_id=iso_user.id
    )
    node.name_embedding = _unit_vec(hot=3)
    await db_session.commit()

    hits = await crud.find_similar_nodes_with_distance(
        db_session, iso_user.id, _near(hot=3), max_distance=0.35
    )
    assert hits and hits[0][0].id == node.id
    assert 0.0 <= hits[0][1] < 0.35            # a real distance, not a boolean


@pytest.mark.asyncio
async def test_retrieve_seeds_includes_identity_head(db_session, iso_user, monkeypatch):
    """'마야가 누구야?' seeds the 마야 identity even though it has no name_embedding."""
    node = await crud._get_or_create_node(
        db_session, name="마야", type_="Identity", user_id=iso_user.id
    )
    db_session.add(NodeAliasEmbedding(
        user_id=iso_user.id, node_id=node.id, text="마야", embedding=_unit_vec(hot=0),
    ))
    await db_session.commit()

    async def fake_embed(_text: str) -> list[float]:
        return _near(hot=0)

    monkeypatch.setattr(graph_chat, "embed_text", fake_embed)

    seeds, _query_vec = await graph_chat._retrieve_seeds(db_session, iso_user.id, "마야가 누구야?")
    assert node.id in {s.id for s in seeds}


@pytest.mark.asyncio
async def test_build_context_surfaces_identity_and_neighbor_statement(db_session, iso_user):
    maya = await crud._get_or_create_node(
        db_session, name="마야", type_="Identity", description="내 고양이", user_id=iso_user.id
    )
    stmt = await crud._get_or_create_node(
        db_session,
        name="마야 병원",  # short label — must NOT be all the model sees
        type_="Statement",
        description=json.dumps({"context_type": "개인일기", "content": "오늘 마야가 아파서 병원에 갔다"}),
        user_id=iso_user.id,
    )
    await crud.create_edge(
        db_session, source_id=stmt.id, target_id=maya.id,
        relation="MENTIONS", user_id=iso_user.id,
    )
    await db_session.commit()

    ranked = await graph_chat._build_context(db_session, iso_user.id, [maya])
    ctx = ranked.text
    assert "내 고양이" in ctx                    # identity description surfaced
    assert "병원에 갔다" in ctx                   # neighbour statement BODY, not just label
    assert "언급된 인물: 마야" in ctx              # MENTIONS relation rendered as natural language
    assert "MENTIONS" not in ctx                 # not left as a raw/ambiguous triple
