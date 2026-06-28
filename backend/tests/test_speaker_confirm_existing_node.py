"""Confirming an existing Speaker graph node must use node.name, not stale profile labels."""

from __future__ import annotations

import uuid

import pytest

from app import crud
from app.models import JournalEntry, Node, SpeakerProfile, SpeakerEntryAppearance, SpeakerProfile
from app.speaker_confirmation import build_speaker_summaries_for_entry, confirm_speaker_identity
from app.speaker_profiles import repair_entry_speaker_bindings


@pytest.mark.asyncio
async def test_confirm_existing_speaker_node_uses_node_name(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_ko="[Speaker_1] 안녕",
        transcript_segments=[{"speaker": "Speaker_1", "text": "안녕"}],
    )
    db_session.add(entry)
    await db_session.flush()

    speaker_node = Node(user_id=user_id, name="장세영", type="Speaker")
    db_session.add(speaker_node)
    await db_session.flush()

    profile = SpeakerProfile(
        user_id=user_id,
        label="Speaker_1",
        display_name="장덕환",
        embedding=[0.0] * 256,
        sample_count=1,
        total_duration_sec=1.0,
    )
    db_session.add(profile)
    await db_session.flush()

    db_session.add(
        SpeakerEntryAppearance(
            journal_entry_id=entry.id,
            speaker_profile_id=profile.id,
            session_label="Speaker_1",
            match_score=0.0,
            duration_sec=1.0,
        )
    )
    entry.transcript_segments = [
        {"speaker": "Speaker_1", "text": "안녕", "speaker_profile_id": str(profile.id)}
    ]
    await db_session.commit()
    await db_session.refresh(entry)
    await db_session.refresh(speaker_node)
    await db_session.refresh(profile)

    result = await confirm_speaker_identity(
        db_session,
        user_id,
        entry.id,
        profile.id,
        node_id=speaker_node.id,
    )

    await db_session.refresh(speaker_node)
    await db_session.refresh(profile)
    await db_session.refresh(entry)

    assert result.confirmed_node.name == "장세영"
    assert profile.display_name == "장세영"
    assert profile.label == "장세영"
    assert profile.node_id == speaker_node.id
    assert speaker_node.speaker_profile_id == profile.id
    assert "[장세영]" in (entry.transcript_ko or "")
    assert "[Speaker_1]" not in (entry.transcript_ko or "")


@pytest.mark.asyncio
async def test_speaker_picker_includes_graph_speaker_even_with_voice(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    node = Node(user_id=user_id, name="장세영", type="Speaker")
    db_session.add(node)
    await db_session.flush()

    profile = SpeakerProfile(
        user_id=user_id,
        label="장덕환",
        display_name="장덕환",
        embedding=[0.1] * 256,
        node_id=node.id,
        sample_count=1,
        total_duration_sec=10.0,
    )
    node.speaker_profile_id = profile.id
    db_session.add(profile)
    await db_session.commit()

    picked = await crud.list_person_nodes_for_speaker_picker(db_session, user_id)
    names = {n.name for n in picked}
    assert "장세영" in names


@pytest.mark.asyncio
async def test_repair_fixes_stale_segment_profile_id(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_segments=[{"speaker": "Speaker_1", "text": "hello"}],
    )
    db_session.add(entry)
    await db_session.flush()

    good = await crud.create_speaker_profile(
        db_session, user_id, label="Speaker_1", embedding=None, last_entry_id=entry.id
    )
    await crud.record_speaker_entry_appearance(
        db_session,
        entry.id,
        good.id,
        "Speaker_1",
        match_score=0.0,
        duration_sec=1.0,
    )
    stale_id = uuid.uuid4()
    entry.transcript_segments = [
        {"speaker": "Speaker_1", "text": "hello", "speaker_profile_id": str(stale_id)}
    ]
    await db_session.commit()
    await db_session.refresh(entry)

    changed = await repair_entry_speaker_bindings(db_session, user_id, entry)
    assert changed is True
    await db_session.refresh(entry)
    assert entry.transcript_segments[0]["speaker_profile_id"] == str(good.id)


@pytest.mark.asyncio
async def test_confirm_uses_session_label_when_segment_profile_stale(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_ko="[Speaker_1] 안녕",
        transcript_segments=[{"speaker": "Speaker_1", "text": "안녕"}],
    )
    db_session.add(entry)
    await db_session.flush()

    speaker_node = Node(user_id=user_id, name="장세영", type="Speaker")
    db_session.add(speaker_node)
    await db_session.flush()

    good = await crud.create_speaker_profile(
        db_session, user_id, label="Speaker_1", embedding=None, last_entry_id=entry.id
    )
    await crud.record_speaker_entry_appearance(
        db_session,
        entry.id,
        good.id,
        "Speaker_1",
        match_score=0.0,
        duration_sec=1.0,
    )
    stale_id = uuid.uuid4()
    entry.transcript_segments = [
        {
            "speaker": "Speaker_1",
            "text": "안녕",
            "speaker_profile_id": str(stale_id),
        }
    ]
    await db_session.commit()

    result = await confirm_speaker_identity(
        db_session,
        user_id,
        entry.id,
        stale_id,
        node_id=speaker_node.id,
        session_label="Speaker_1",
    )

    apps = await crud.list_speaker_appearances_for_entry(db_session, entry.id)
    prof = await db_session.get(SpeakerProfile, result.speaker_profile_id)
    linked_node = await db_session.get(Node, speaker_node.id)

    assert result.confirmed_node.name == "장세영"
    assert len(apps) == 1
    assert apps[0].match_score >= 0.999
    assert prof is not None and prof.node_id == speaker_node.id
    assert linked_node is not None and linked_node.speaker_profile_id == prof.id
    assert crud.is_bidirectional_voice_link(prof, linked_node)

    summaries = await build_speaker_summaries_for_entry(db_session, user_id, entry.id)
    assert summaries[0].needs_confirmation is False
    assert summaries[0].confirmed_node is not None
    assert summaries[0].confirmed_node.name == "장세영"
