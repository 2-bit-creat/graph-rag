"""The diary '나' and any conversation speaker confirmed as self share ONE node.

Regression: registering a conversation speaker under a real name used to fork a
second Person node, splitting the user's identity from the diary '나'. The
canonical self node (is_self) must unify them, survive renames, and never duplicate.
"""

from __future__ import annotations

import pytest

from app import crud
from app.models import JournalEntry, Node, SpeakerEntryAppearance, SpeakerProfile
from app.routers.kg_build import _confirmed_speaker_name
from app.speaker_confirmation import (
    build_speaker_summaries_for_entry,
    confirm_speaker_identity,
)


async def _conversation_entry_with_speaker(db_session, user_id, label="Speaker_2"):
    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_segments=[{"speaker": label, "text": "저는 마차를 마실 거예요."}],
    )
    db_session.add(entry)
    await db_session.flush()

    profile = SpeakerProfile(
        user_id=user_id,
        label=label,
        embedding=[0.1] * 256,
        sample_count=1,
        total_duration_sec=2.0,
    )
    db_session.add(profile)
    await db_session.flush()

    db_session.add(
        SpeakerEntryAppearance(
            journal_entry_id=entry.id,
            speaker_profile_id=profile.id,
            session_label=label,
            match_score=0.0,
            duration_sec=2.0,
        )
    )
    entry.transcript_segments = [
        {"speaker": label, "text": "저는 마차를 마실 거예요.", "speaker_profile_id": str(profile.id)}
    ]
    await db_session.commit()
    return entry, profile


@pytest.mark.asyncio
async def test_get_or_create_self_node_is_idempotent(db_session, iso_user):
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    first = await crud.get_or_create_self_node(db_session, user_id)
    second = await crud.get_or_create_self_node(db_session, user_id)

    assert first.id == second.id
    assert first.is_self is True
    assert crud.is_person_like_type(first.type)
    assert first.name == "나"


@pytest.mark.asyncio
async def test_get_or_create_self_node_adopts_existing_na_person(db_session, iso_user):
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    # An older diary already produced a plain Person '나' node.
    legacy = await crud._get_or_create_node(
        db_session, name="나", type_="Person", user_id=user_id
    )
    await db_session.commit()

    self_node = await crud.get_or_create_self_node(db_session, user_id)

    assert self_node.id == legacy.id  # adopted, not duplicated
    assert self_node.is_self is True


@pytest.mark.asyncio
async def test_confirm_as_self_links_to_self_node(db_session, iso_user):
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry, profile = await _conversation_entry_with_speaker(db_session, user_id)

    result = await confirm_speaker_identity(
        db_session,
        user_id,
        entry.id,
        profile.id,
        as_self=True,
        session_label="Speaker_2",
    )

    self_node = await crud.get_self_node(db_session, user_id)
    await db_session.refresh(profile)

    assert self_node is not None
    assert result.confirmed_node.id == self_node.id
    assert profile.node_id == self_node.id
    assert crud.is_bidirectional_voice_link(profile, self_node)


@pytest.mark.asyncio
async def test_confirm_speaker_as_na_name_routes_to_self_node(db_session, iso_user):
    """Confirming a Speaker_N as the literal name '나' must link to the self node,
    not leave a dangling display_name='나' with no node (which reads as unconfirmed).
    """
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry, profile = await _conversation_entry_with_speaker(db_session, user_id)

    # Legacy path: user types/pick '나' as a new name instead of the self button.
    result = await confirm_speaker_identity(
        db_session,
        user_id,
        entry.id,
        profile.id,
        new_node_name="나",
        session_label="Speaker_2",
    )

    self_node = await crud.get_self_node(db_session, user_id)
    await db_session.refresh(profile)

    assert self_node is not None
    assert result.confirmed_node.id == self_node.id
    assert profile.node_id == self_node.id
    assert crud.is_bidirectional_voice_link(profile, self_node)

    # And it surfaces as confirmed '나' in the summary — no '화자 확인 필요'.
    summaries = await build_speaker_summaries_for_entry(db_session, user_id, entry.id)
    sp2 = next(s for s in summaries if s.session_label == "Speaker_2")
    assert sp2.needs_confirmation is False
    assert sp2.confirmed_node is not None and sp2.confirmed_node.id == self_node.id


@pytest.mark.asyncio
async def test_summary_self_heals_confirmed_na_without_node(db_session, iso_user):
    """A pre-existing appearance confirmed as '나' but never node-linked (locked
    behind a built graph) must still read as confirmed, resolving to the self node.
    """
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    # Self node exists (from earlier diary '나' or another entry).
    self_node = await crud.get_or_create_self_node(db_session, user_id)
    await db_session.commit()

    entry, profile = await _conversation_entry_with_speaker(db_session, user_id)
    # Simulate the legacy stuck state directly: human-confirmed, display '나', no node.
    profile.display_name = "나"
    profile.label = "나"
    profile.node_id = None
    appearance = await crud.get_speaker_appearance_for_label(
        db_session, entry.id, "Speaker_2"
    )
    appearance.match_score = 1.0
    await db_session.commit()

    summaries = await build_speaker_summaries_for_entry(db_session, user_id, entry.id)
    sp2 = next(s for s in summaries if s.session_label == "Speaker_2")

    assert sp2.needs_confirmation is False
    assert sp2.confirmed_node is not None
    assert sp2.confirmed_node.id == self_node.id


@pytest.mark.asyncio
async def test_two_conversation_speakers_as_self_share_one_node(db_session, iso_user):
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry1, profile1 = await _conversation_entry_with_speaker(db_session, user_id, "Speaker_1")
    r1 = await confirm_speaker_identity(
        db_session, user_id, entry1.id, profile1.id, as_self=True, session_label="Speaker_1"
    )

    entry2, profile2 = await _conversation_entry_with_speaker(db_session, user_id, "Speaker_3")
    r2 = await confirm_speaker_identity(
        db_session, user_id, entry2.id, profile2.id, as_self=True, session_label="Speaker_3"
    )

    assert r1.confirmed_node.id == r2.confirmed_node.id

    # Exactly one self node exists.
    selves = [n for n in await crud.get_all_nodes(db_session, user_id) if n.is_self]
    assert len(selves) == 1


@pytest.mark.asyncio
async def test_diary_na_summary_resolves_to_self_node(db_session, iso_user):
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    # Establish the self node and rename it to a real name.
    self_node = await crud.get_or_create_self_node(db_session, user_id)
    self_node.name = "장세영"
    await db_session.commit()

    # A diary entry whose sole speaker is '나'.
    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_segments=[{"speaker": "나", "text": "저는 마차를 만들었어요."}],
    )
    db_session.add(entry)
    await db_session.flush()
    na_profile = await crud.create_speaker_profile(
        db_session, user_id, label="나", embedding=None, last_entry_id=entry.id
    )
    await crud.record_speaker_entry_appearance(
        db_session, entry.id, na_profile.id, "나", match_score=0.0, duration_sec=2.0
    )
    await db_session.commit()

    summaries = await build_speaker_summaries_for_entry(db_session, user_id, entry.id)
    na = next(s for s in summaries if s.session_label == "나")

    # Diary '나' now points at the same node — and shows the renamed identity.
    assert na.confirmed_node is not None
    assert na.confirmed_node.id == self_node.id
    assert na.confirmed_node.name == "장세영"
    assert na.needs_confirmation is False


@pytest.mark.asyncio
async def test_single_speaker_attribution_uses_confirmed_identity_not_self(
    db_session, iso_user
):
    """A one-voice clip confirmed as someone else must NOT be attributed to self."""
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry, profile = await _conversation_entry_with_speaker(db_session, user_id, "Speaker_1")

    # Unconfirmed → no resolved identity (graph build would fall back to self).
    assert await _confirmed_speaker_name(db_session, user_id, entry.id, "Speaker_1") is None

    # Confirm the lone speaker as a different person (a lecturer, not the owner).
    prof_node = Node(user_id=user_id, name="교수님", type="Speaker")
    db_session.add(prof_node)
    await db_session.flush()
    await confirm_speaker_identity(
        db_session, user_id, entry.id, profile.id,
        node_id=prof_node.id, session_label="Speaker_1",
    )

    resolved = await _confirmed_speaker_name(db_session, user_id, entry.id, "Speaker_1")
    assert resolved == "교수님"

    # And the user is NOT silently turned into the self node for this entry.
    self_node = await crud.get_self_node(db_session, user_id)
    assert self_node is None or resolved != self_node.name


@pytest.mark.asyncio
async def test_multispeaker_statements_and_voice_converge_on_confirmed_nodes(
    db_session, iso_user
):
    """Speaker_1→제니, Speaker_2→나 must each be ONE node carrying its own voice —
    statements must not split onto raw 'Speaker_N' labels."""
    from app.routers.kg_build import (
        _entry_label_identity_map,
        _link_confirmed_voices_to_nodes,
    )

    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_segments=[
            {"speaker": "Speaker_1", "text": "저는 마차를 만들었어요."},
            {"speaker": "Speaker_2", "text": "저는 마차를 마실 거예요."},
        ],
    )
    db_session.add(entry)
    await db_session.flush()
    p1 = SpeakerProfile(user_id=user_id, label="Speaker_1", embedding=[0.1] * 256,
                        sample_count=1, total_duration_sec=2.0)
    p2 = SpeakerProfile(user_id=user_id, label="Speaker_2", embedding=[0.2] * 256,
                        sample_count=1, total_duration_sec=2.0)
    db_session.add_all([p1, p2])
    await db_session.flush()
    for prof, label in ((p1, "Speaker_1"), (p2, "Speaker_2")):
        db_session.add(SpeakerEntryAppearance(
            journal_entry_id=entry.id, speaker_profile_id=prof.id,
            session_label=label, match_score=0.0, duration_sec=2.0))
    await db_session.commit()

    # Speaker_1 → a new person '제니'; Speaker_2 → the self node.
    await confirm_speaker_identity(db_session, user_id, entry.id, p1.id,
                                   new_node_name="제니", session_label="Speaker_1")
    await confirm_speaker_identity(db_session, user_id, entry.id, p2.id,
                                   as_self=True, session_label="Speaker_2")

    self_node = await crud.get_self_node(db_session, user_id)

    # Claims would attribute to confirmed identities, not raw labels.
    imap = await _entry_label_identity_map(db_session, user_id, entry.id)
    assert imap["Speaker_1"] == "제니"
    assert imap["Speaker_2"] == self_node.name

    # Voice binds to those same nodes — '제니' node carries Speaker_1's voice.
    await _link_confirmed_voices_to_nodes(db_session, user_id, entry.id)
    await db_session.commit()

    jenny = await crud._get_or_create_node(db_session, name="제니", type_="Person", user_id=user_id)
    await db_session.refresh(p1)
    await db_session.refresh(p2)
    assert p1.node_id == jenny.id and crud.is_bidirectional_voice_link(p1, jenny)
    assert p2.node_id == self_node.id and crud.is_bidirectional_voice_link(p2, self_node)

    # No raw-label nodes are used for identity.
    names = {n.name for n in await crud.get_all_nodes(db_session, user_id)}
    assert "Speaker_1" not in names and "Speaker_2" not in names
