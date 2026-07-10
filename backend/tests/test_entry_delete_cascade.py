"""Deleting a journal entry is statement-centric: its Statement nodes go, and
orphan Concept/Speaker neighbours (incl. self) follow; a voice embedding survives
only while some entry still references it; shared nodes are kept.
"""

from __future__ import annotations

import pytest

from app import crud
from app.models import Edge, JournalEntry, Node, SpeakerEntryAppearance, SpeakerProfile


async def _entry_with_statement(
    db_session, user_id, *, speaker_name: str, concept: str, statement: str,
    speaker_profile: SpeakerProfile | None = None,
):
    """Create an entry + (Speaker)-SPOKE_OR_PUBLISHED->(Statement)-CONTEXT->(Concept)."""
    entry = JournalEntry(user_id=user_id, status="ready")
    db_session.add(entry)
    await db_session.flush()

    speaker = await crud._get_or_create_node(db_session, name=speaker_name, type_="Person", user_id=user_id)
    stmt = await crud._get_or_create_node(db_session, name=statement, type_="Statement", user_id=user_id)
    concept_node = await crud._get_or_create_node(db_session, name=concept, type_="Concept", user_id=user_id)
    await crud.create_edge(db_session, source_id=speaker.id, target_id=stmt.id, relation="SPOKE_OR_PUBLISHED", user_id=user_id)
    await crud.create_edge(db_session, source_id=stmt.id, target_id=concept_node.id, relation="CONTEXT", user_id=user_id)
    await crud.record_journal_graph_links(db_session, entry.id, [speaker.id, stmt.id, concept_node.id], [])

    if speaker_profile is not None:
        speaker_profile.node_id = speaker.id
        speaker.speaker_profile_id = speaker_profile.id
        db_session.add(SpeakerEntryAppearance(
            journal_entry_id=entry.id, speaker_profile_id=speaker_profile.id,
            session_label="Speaker_1", match_score=1.0, duration_sec=2.0))
    await db_session.commit()
    return entry, speaker, stmt, concept_node


async def _node_names(db_session, user_id) -> set[str]:
    return {n.name for n in await crud.get_all_nodes(db_session, user_id)}


@pytest.mark.asyncio
async def test_delete_entry_removes_statement_and_orphan_neighbours(db_session, iso_user):
    user_id = iso_user.id
    entry, speaker, stmt, concept = await _entry_with_statement(
        db_session, user_id, speaker_name="제니", concept="마차", statement="마차를 만들었다고 말함")

    await crud.delete_journal_entry(db_session, entry)
    await crud.sanitize_stale_voice_links(db_session, user_id)

    names = await _node_names(db_session, user_id)
    assert "마차를 만들었다고 말함" not in names  # statement gone
    assert "마차" not in names                    # orphan concept GC'd
    assert "제니" not in names                     # orphan speaker GC'd


@pytest.mark.asyncio
async def test_self_node_gcd_when_orphaned(db_session, iso_user):
    user_id = iso_user.id
    self_node = await crud.get_or_create_self_node(db_session, user_id)
    entry = JournalEntry(user_id=user_id, status="ready")
    db_session.add(entry)
    await db_session.flush()
    stmt = await crud._get_or_create_node(db_session, name="오늘 한 일", type_="Statement", user_id=user_id)
    await crud.create_edge(db_session, source_id=self_node.id, target_id=stmt.id, relation="SPOKE_OR_PUBLISHED", user_id=user_id)
    await crud.record_journal_graph_links(db_session, entry.id, [self_node.id, stmt.id], [])
    await db_session.commit()

    await crud.delete_journal_entry(db_session, entry)

    # Statement-centric: orphaned self node is GC'd too (no exception).
    assert await crud.get_self_node(db_session, user_id) is None


@pytest.mark.asyncio
async def test_shared_concept_survives_when_one_entry_deleted(db_session, iso_user):
    user_id = iso_user.id
    e1, _, _, _ = await _entry_with_statement(
        db_session, user_id, speaker_name="제니", concept="마차", statement="마차를 만들었다고 말함")
    e2, _, _, _ = await _entry_with_statement(
        db_session, user_id, speaker_name="나", concept="마차", statement="마차를 마실 계획임")

    await crud.delete_journal_entry(db_session, e1)
    await crud.sanitize_stale_voice_links(db_session, user_id)

    names = await _node_names(db_session, user_id)
    assert "마차" in names                          # shared concept kept (e2 still uses it)
    assert "마차를 만들었다고 말함" not in names      # e1's statement gone
    assert "마차를 마실 계획임" in names              # e2's statement kept


@pytest.mark.asyncio
async def test_voice_removed_but_pre_existing_node_kept(db_session, iso_user):
    """Text speaker node + later audio voice → deleting the audio entry drops the
    voice embedding but keeps the (still-referenced) node."""
    user_id = iso_user.id

    # Text entry: '장세영' node referenced by a statement (no voice).
    e_text, speaker, _, _ = await _entry_with_statement(
        db_session, user_id, speaker_name="장세영", concept="회의", statement="회의를 했다고 말함")

    # Audio entry: a voice profile linked to the SAME '장세영' node.
    profile = SpeakerProfile(user_id=user_id, label="장세영", display_name="장세영",
                             embedding=[0.3] * 256, sample_count=1, total_duration_sec=2.0)
    db_session.add(profile)
    await db_session.flush()
    e_audio, _, _, _ = await _entry_with_statement(
        db_session, user_id, speaker_name="장세영", concept="발표", statement="발표를 했다고 말함",
        speaker_profile=profile)

    await crud.delete_journal_entry(db_session, e_audio)
    await crud.sanitize_stale_voice_links(db_session, user_id)

    names = await _node_names(db_session, user_id)
    assert "장세영" in names  # still referenced by the text statement → kept
    # Voice gone: the profile (no remaining appearance) was GC'd.
    remaining = await crud.list_speaker_profiles(db_session, user_id)
    assert all(p.id != profile.id for p in remaining)
    refreshed = await db_session.get(Node, speaker.id)
    assert refreshed is not None and refreshed.speaker_profile_id is None


@pytest.mark.asyncio
async def test_voice_speaker_node_without_statement_gcd_after_entry_delete(
    db_session, iso_user
):
    """A confirmed-speaker node that never anchored a Statement (no edge) must not
    linger after its journal entry is deleted.

    Regression: '장세영' survived forever because statement-centric GC only reaches
    edge-neighbours of a deleted Statement — a voice-confirmed speaker who said
    nothing that became a claim has no such edge, so nothing GC'd the node.
    """
    user_id = iso_user.id

    entry = JournalEntry(user_id=user_id, status="ready")
    db_session.add(entry)
    await db_session.flush()

    # Speaker node with a voice profile but NO statement edge — exactly what
    # _link_confirmed_voices_to_nodes leaves when the speaker produced no claim.
    speaker = await crud._get_or_create_node(
        db_session, name="장세영", type_="Speaker", user_id=user_id)
    profile = SpeakerProfile(
        user_id=user_id, label="장세영", display_name="장세영",
        embedding=[0.4] * 256, sample_count=1, total_duration_sec=2.0,
        node_id=speaker.id)
    db_session.add(profile)
    await db_session.flush()
    speaker.speaker_profile_id = profile.id
    db_session.add(SpeakerEntryAppearance(
        journal_entry_id=entry.id, speaker_profile_id=profile.id,
        session_label="Speaker_1", match_score=1.0, duration_sec=2.0))
    await crud.record_journal_graph_links(db_session, entry.id, [speaker.id], [])
    await db_session.commit()

    # While the entry exists, the node is kept (provenance link + live voice).
    await crud.sanitize_stale_voice_links(db_session, user_id)
    assert "장세영" in await _node_names(db_session, user_id)

    await crud.delete_journal_entry(db_session, entry)
    await crud.sanitize_stale_voice_links(db_session, user_id)

    names = await _node_names(db_session, user_id)
    assert "장세영" not in names  # orphan speaker node GC'd
    remaining = await crud.list_speaker_profiles(db_session, user_id)
    assert all(p.id != profile.id for p in remaining)
