"""Changing a node's type must bring its Statement relations along.

The invariant the graph is supposed to hold:

    Identity|Source --SPOKE_OR_PUBLISHED--> Statement
    Statement       --MENTIONS-->           Identity|Source
    Statement       --CONTEXT-->            Concept

Retyping used to change only nodes.type, so an Identity demoted to Concept kept
its incoming MENTIONS edges — the concept node with MENTIONS arrows the user hit.
Both write paths (PATCH /graph/nodes and POST /kg/nodes/{id}/reclassify) now go
through crud.apply_type_change and must agree.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app import crud
from app.models import Edge, Node, NodeAliasEmbedding
from app.routers.kg_build import ReclassifyNodeRequest, kg_reclassify_node
from app.schemas import NodeUpdate


async def _node(db_session, user_id, name, type_) -> Node:
    node = Node(user_id=user_id, name=name, type=type_)
    db_session.add(node)
    await db_session.flush()
    return node


async def _edge(db_session, user_id, source, target, relation, weight=1) -> Edge:
    edge = Edge(
        user_id=user_id,
        source_id=source.id,
        target_id=target.id,
        relation=relation,
        weight=weight,
    )
    db_session.add(edge)
    await db_session.flush()
    return edge


async def _relations(db_session, node_id) -> list[tuple[str, str, str]]:
    """(source_name, relation, target_name) for every edge touching node_id."""
    rows = await db_session.execute(
        select(Edge).where(
            (Edge.source_id == node_id) | (Edge.target_id == node_id)
        )
    )
    out = []
    for edge in rows.scalars().all():
        src = await db_session.get(Node, edge.source_id)
        tgt = await db_session.get(Node, edge.target_id)
        out.append((src.name, edge.relation, tgt.name))
    return sorted(out)


@pytest.mark.asyncio
async def test_identity_to_concept_turns_mentions_into_context(db_session, iso_user):
    """The reported bug: 투자자 was stored as an Identity but is a Concept."""
    investor = await _node(db_session, iso_user.id, "투자자", "Identity")
    stmt = await _node(db_session, iso_user.id, "EOD 개념 설명", "Statement")
    await _edge(db_session, iso_user.id, stmt, investor, "MENTIONS")
    await db_session.commit()

    counts = await crud.apply_type_change(db_session, iso_user.id, investor, "Concept")
    await db_session.commit()

    assert counts["relations_fixed"] == 1
    assert counts["heads_demoted"] == 0
    assert await _relations(db_session, investor.id) == [
        ("EOD 개념 설명", "CONTEXT", "투자자")
    ]


@pytest.mark.asyncio
async def test_concept_to_identity_turns_context_into_mentions(db_session, iso_user):
    grandma = await _node(db_session, iso_user.id, "할머니", "Concept")
    stmt = await _node(db_session, iso_user.id, "할머니 이야기", "Statement")
    await _edge(db_session, iso_user.id, stmt, grandma, "CONTEXT")
    await db_session.commit()

    counts = await crud.apply_type_change(db_session, iso_user.id, grandma, "Identity")
    await db_session.commit()

    assert counts["relations_fixed"] == 1
    assert await _relations(db_session, grandma.id) == [
        ("할머니 이야기", "MENTIONS", "할머니")
    ]


@pytest.mark.asyncio
async def test_duplicate_triple_is_merged_with_summed_weight(db_session, iso_user):
    """uq_edge_triple: the rewritten edge can collide with one already there."""
    investor = await _node(db_session, iso_user.id, "투자자", "Identity")
    stmt = await _node(db_session, iso_user.id, "진술", "Statement")
    await _edge(db_session, iso_user.id, stmt, investor, "MENTIONS", weight=2)
    await _edge(db_session, iso_user.id, stmt, investor, "CONTEXT", weight=3)
    await db_session.commit()

    counts = await crud.apply_type_change(db_session, iso_user.id, investor, "Concept")
    await db_session.commit()

    assert counts["duplicates_merged"] == 1
    edges = (
        await db_session.execute(
            select(Edge).where(Edge.target_id == investor.id)
        )
    ).scalars().all()
    assert len(edges) == 1
    assert edges[0].relation == "CONTEXT"
    assert edges[0].weight == 5


@pytest.mark.asyncio
async def test_demoting_a_statement_head_reverses_the_edge(db_session, iso_user):
    """A head demoted to Concept can't keep pointing AT the statement."""
    head = await _node(db_session, iso_user.id, "뉴스", "Identity")
    stmt = await _node(db_session, iso_user.id, "뉴스가 말했다", "Statement")
    await _edge(db_session, iso_user.id, head, stmt, "SPOKE_OR_PUBLISHED")
    await db_session.commit()

    counts = await crud.apply_type_change(db_session, iso_user.id, head, "Concept")
    await db_session.commit()

    assert counts["heads_demoted"] == 1
    assert await _relations(db_session, head.id) == [
        ("뉴스가 말했다", "CONTEXT", "뉴스")
    ]


@pytest.mark.asyncio
async def test_hand_authored_relation_is_left_alone(db_session, iso_user):
    """The edge inspector lets the user type any relation — it stays authoritative."""
    node = await _node(db_session, iso_user.id, "투자자", "Identity")
    stmt = await _node(db_session, iso_user.id, "진술", "Statement")
    await _edge(db_session, iso_user.id, stmt, node, "DISAGREES_WITH")
    other = await _node(db_session, iso_user.id, "리스크", "Concept")
    await _edge(db_session, iso_user.id, node, other, "RELATED_TO")
    await db_session.commit()

    await crud.apply_type_change(db_session, iso_user.id, node, "Concept")
    await db_session.commit()

    assert await _relations(db_session, node.id) == [
        ("진술", "DISAGREES_WITH", "투자자"),
        ("투자자", "RELATED_TO", "리스크"),
    ]


@pytest.mark.asyncio
async def test_demotion_drops_alias_embeddings(db_session, iso_user):
    """Otherwise the demoted node keeps fuzzy-matching as an identity."""
    node = await _node(db_session, iso_user.id, "투자자", "Identity")
    db_session.add(
        NodeAliasEmbedding(
            user_id=iso_user.id,
            node_id=node.id,
            text="투자자",
            embedding=[0.0] * 1535 + [1.0],
        )
    )
    await db_session.commit()

    await crud.apply_type_change(db_session, iso_user.id, node, "Concept")
    await db_session.commit()

    rows = (
        await db_session.execute(
            select(NodeAliasEmbedding).where(NodeAliasEmbedding.node_id == node.id)
        )
    ).scalars().all()
    assert rows == []

    # And the vector search refuses it even if a stale row survived elsewhere.
    hit = await crud.find_identity_by_alias_embedding(
        db_session, iso_user.id, [0.0] * 1535 + [1.0]
    )
    assert hit is None or hit[0].id != node.id


@pytest.mark.asyncio
async def test_no_op_when_the_type_does_not_change(db_session, iso_user):
    node = await _node(db_session, iso_user.id, "투자자", "Identity")
    stmt = await _node(db_session, iso_user.id, "진술", "Statement")
    await _edge(db_session, iso_user.id, stmt, node, "MENTIONS")
    await db_session.commit()

    counts = await crud.apply_type_change(db_session, iso_user.id, node, "identity")
    await db_session.commit()

    assert counts == {
        "relations_fixed": 0,
        "duplicates_merged": 0,
        "heads_demoted": 0,
    }
    assert await _relations(db_session, node.id) == [("진술", "MENTIONS", "투자자")]


@pytest.mark.asyncio
async def test_patch_and_reclassify_produce_the_same_graph(db_session, iso_user):
    """The generic edit path used to be the unguarded back door."""
    results = []
    for name in ("가", "나"):
        node = await _node(db_session, iso_user.id, f"투자자{name}", "Identity")
        stmt = await _node(db_session, iso_user.id, f"진술{name}", "Statement")
        await _edge(db_session, iso_user.id, stmt, node, "MENTIONS")
        await db_session.commit()
        results.append((node, stmt))

    (patched, _), (reclassified, _) = results

    updated = await crud.update_node(
        db_session, patched.id, None, "Concept", None, user_id=iso_user.id
    )
    assert updated is not None
    _, patch_fixup = updated

    reclassify_result = await kg_reclassify_node(
        reclassified.id,
        ReclassifyNodeRequest(to_type="Concept"),
        iso_user,
        db_session,
    )

    assert patch_fixup["relations_fixed"] == reclassify_result["relations_fixed"] == 1
    patch_rels = [r for _, r, _ in await _relations(db_session, patched.id)]
    reclassify_rels = [r for _, r, _ in await _relations(db_session, reclassified.id)]
    assert patch_rels == reclassify_rels == ["CONTEXT"]

    await db_session.refresh(patched)
    await db_session.refresh(reclassified)
    assert patched.type == reclassified.type == "Concept"


@pytest.mark.asyncio
async def test_reclassify_accepts_legacy_person_and_stores_identity(
    db_session, iso_user
):
    """Older clients still send toType: 'Person'."""
    node = await _node(db_session, iso_user.id, "제니", "Concept")
    await db_session.commit()

    result = await kg_reclassify_node(
        node.id, ReclassifyNodeRequest(to_type="Person"), iso_user, db_session
    )

    assert result["type"] == "Identity"
    await db_session.refresh(node)
    assert node.type == "Identity"
