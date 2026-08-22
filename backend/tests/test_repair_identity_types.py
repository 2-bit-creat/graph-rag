"""The Person → Identity backfill (crud.repair_identity_types).

Collapsing the type is a bulk UPDATE that would violate uq_node_user_name_type
whenever a user has both a legacy 'Person 마야' and an 'Identity 마야', so the
duplicates must be merged FIRST — carrying aliases, importance score, edges and
journal provenance onto the survivor rather than losing them to the cascade.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app import crud
from app.models import Edge, JournalEntry, JournalGraphLink, Node


async def _node(db_session, user_id, name, type_, **kw) -> Node:
    node = Node(user_id=user_id, name=name, type=type_, **kw)
    db_session.add(node)
    await db_session.flush()
    return node


@pytest.mark.asyncio
async def test_legacy_types_are_retyped(db_session, iso_user):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    for name, type_ in (("제니", "Person"), ("마야", "Speaker"), ("뉴스", "Source")):
        await _node(db_session, iso_user.id, name, type_)
    concept = await _node(db_session, iso_user.id, "커피", "Concept")
    await db_session.commit()

    counts = await crud.repair_identity_types(db_session, iso_user.id)
    await db_session.commit()

    assert counts["retyped"] == 3  # 제니, 마야, 뉴스 — Source retypes too now
    nodes_by_name = {
        n.name: n
        for n in await crud.get_all_nodes(db_session, iso_user.id)
        if n.deleted_at is None
    }
    assert nodes_by_name["제니"].type == "Identity"
    assert nodes_by_name["마야"].type == "Identity"
    # Source is a flag now, not a distinct type — it also collapses to Identity.
    assert nodes_by_name["뉴스"].type == "Identity"
    assert nodes_by_name["뉴스"].is_source is True
    assert nodes_by_name["커피"].type == "Concept"
    await db_session.refresh(concept)


@pytest.mark.asyncio
async def test_same_name_duplicates_merge_keeping_everything(db_session, iso_user):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)

    old = await _node(db_session, iso_user.id, "마야", "Person", importance_score=4)
    crud.add_node_alias(old, "먀야")
    new = await _node(db_session, iso_user.id, "마야", "Identity", importance_score=7)
    stmt = await _node(db_session, iso_user.id, "마야 이야기", "Statement")

    db_session.add(
        Edge(
            user_id=iso_user.id,
            source_id=stmt.id,
            target_id=old.id,
            relation="MENTIONS",
        )
    )
    entry = JournalEntry(user_id=iso_user.id, status="ready")
    db_session.add(entry)
    await db_session.flush()
    db_session.add(JournalGraphLink(journal_entry_id=entry.id, node_id=old.id))
    await db_session.commit()

    counts = await crud.repair_identity_types(db_session, iso_user.id)
    await db_session.commit()

    assert counts["merged"] == 1
    mayas = [
        n
        for n in await crud.get_all_nodes(db_session, iso_user.id)
        if n.name == "마야" and n.deleted_at is None
    ]
    assert len(mayas) == 1
    survivor = mayas[0]
    # Neither node has a voice, so the tie-break is age: the oldest row survives,
    # keeping its id and created_at, and step 2 retypes it.
    assert survivor.id == old.id
    assert survivor.type == "Identity"
    assert new.id != survivor.id
    assert survivor.importance_score == 11  # 7 + 4, not reset
    assert "먀야" in (survivor.aliases or [])

    # The edge and the journal trace followed the merge.
    edge = (
        await db_session.execute(select(Edge).where(Edge.source_id == stmt.id))
    ).scalar_one()
    assert edge.target_id == survivor.id
    link = (
        await db_session.execute(
            select(JournalGraphLink).where(
                JournalGraphLink.journal_entry_id == entry.id
            )
        )
    ).scalar_one()
    assert link.node_id == survivor.id


@pytest.mark.asyncio
async def test_a_voiced_duplicate_wins_over_an_older_one(db_session, iso_user):
    """A bound voice profile is what marks an identity as a real person now, so
    the node carrying one must be the survivor."""
    from app.models import SpeakerProfile

    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    plain = await _node(db_session, iso_user.id, "제니", "Person")
    voiced = await _node(db_session, iso_user.id, "제니", "Identity")
    profile = SpeakerProfile(
        user_id=iso_user.id, label="제니", embedding=[0.3] * 256, sample_count=1
    )
    db_session.add(profile)
    await db_session.flush()
    await crud.assign_exclusive_voice_profile_to_node(
        db_session, iso_user.id, profile, voiced, display_name="제니"
    )
    await db_session.commit()

    await crud.repair_identity_types(db_session, iso_user.id)
    await db_session.commit()

    survivors = [
        n
        for n in await crud.get_all_nodes(db_session, iso_user.id)
        if n.name == "제니" and n.deleted_at is None
    ]
    assert len(survivors) == 1
    assert survivors[0].id == voiced.id
    assert survivors[0].speaker_profile_id == profile.id
    assert plain.id != survivors[0].id


@pytest.mark.asyncio
async def test_same_name_identity_and_source_both_survive(db_session, iso_user):
    """Different merge groups — the whole reason is_source stays a separate bucket."""
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    await _node(db_session, iso_user.id, "기업은행", "Person")
    await _node(db_session, iso_user.id, "기업은행", "Source")
    await db_session.commit()

    counts = await crud.repair_identity_types(db_session, iso_user.id)
    await db_session.commit()

    assert counts["merged"] == 0
    survivors = [
        n
        for n in await crud.get_all_nodes(db_session, iso_user.id)
        if n.name == "기업은행" and n.deleted_at is None
    ]
    # Both store type="Identity" now — is_source is what used to be the
    # distinct "Source" type string.
    assert {n.type for n in survivors} == {"Identity"}
    assert sorted(n.is_source for n in survivors) == [False, True]


@pytest.mark.asyncio
async def test_repair_fixes_stale_relations_graph_wide(db_session, iso_user):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    concept = await _node(db_session, iso_user.id, "투자자", "Concept")
    stmt = await _node(db_session, iso_user.id, "진술", "Statement")
    db_session.add(
        Edge(
            user_id=iso_user.id,
            source_id=stmt.id,
            target_id=concept.id,
            relation="MENTIONS",  # stale: a Concept can't be MENTIONS'd
        )
    )
    await db_session.commit()

    counts = await crud.repair_identity_types(db_session, iso_user.id)
    await db_session.commit()

    assert counts["relations_fixed"] == 1
    edge = (
        await db_session.execute(select(Edge).where(Edge.target_id == concept.id))
    ).scalar_one()
    assert edge.relation == "CONTEXT"


@pytest.mark.asyncio
async def test_repair_is_idempotent(db_session, iso_user):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    await _node(db_session, iso_user.id, "제니", "Person")
    await _node(db_session, iso_user.id, "제니", "Identity")
    await db_session.commit()

    first = await crud.repair_identity_types(db_session, iso_user.id)
    await db_session.commit()
    assert first["merged"] == 1

    second = await crud.repair_identity_types(db_session, iso_user.id)
    await db_session.commit()
    assert second["merged"] == 0
    assert second["retyped"] == 0
    assert second["relations_fixed"] == 0


@pytest.mark.asyncio
async def test_preview_reports_what_would_be_lost(db_session, iso_user):
    """Which identities used to be 'Person' is unrecoverable after the UPDATE."""
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    await _node(db_session, iso_user.id, "제니", "Person")
    await _node(db_session, iso_user.id, "커피", "Concept")
    await db_session.commit()

    preview = await crud.identity_type_repair_preview(db_session, iso_user.id)

    assert [r["name"] for r in preview] == ["제니"]
    assert preview[0]["old_type"] == "Person"
    assert preview[0]["has_voice"] is False
