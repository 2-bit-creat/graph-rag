"""Two diarized speakers must never both be suggested the same Person.

Regression: a multi-speaker entry where both voices matched the linked '나'
profile previously suggested '나' for both. The 1:1 assignment must give the
contested Person to the more similar voice and leave the other unsuggested.
"""

from __future__ import annotations

import pytest

from app import crud
from app.models import JournalEntry, Node, SpeakerEntryAppearance, SpeakerProfile
from app.speaker_confirmation import build_speaker_summaries_for_entry

_DIM = 256


def _emb(*pairs: tuple[int, float]) -> list[float]:
    """Build a 256-d embedding with the given (index, value) overrides."""
    vec = [0.0] * _DIM
    for idx, val in pairs:
        vec[idx] = val
    return vec


@pytest.mark.asyncio
async def test_two_speakers_not_both_suggested_same_person(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    # Linked Person '나' with a confirmed voice profile.
    me_node = Node(user_id=user_id, name="나", type="Speaker")
    db_session.add(me_node)
    await db_session.flush()

    me_profile = SpeakerProfile(
        user_id=user_id,
        label="나",
        display_name="나",
        embedding=_emb((0, 1.0)),
        node_id=me_node.id,
        sample_count=3,
        total_duration_sec=30.0,
    )
    db_session.add(me_profile)
    await db_session.flush()
    me_node.speaker_profile_id = me_profile.id
    await db_session.flush()

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

    # Speaker_1: identical to '나' (cosine sim 1.0).
    p1 = SpeakerProfile(
        user_id=user_id,
        label="Speaker_1",
        embedding=_emb((0, 1.0)),
        sample_count=1,
        total_duration_sec=2.0,
    )
    # Speaker_2: similar but less so (sim ~0.95, still above the 0.85 threshold).
    p2 = SpeakerProfile(
        user_id=user_id,
        label="Speaker_2",
        embedding=_emb((0, 1.0), (1, 0.33)),
        sample_count=1,
        total_duration_sec=2.0,
    )
    db_session.add_all([p1, p2])
    await db_session.flush()

    for prof, label in ((p1, "Speaker_1"), (p2, "Speaker_2")):
        db_session.add(
            SpeakerEntryAppearance(
                journal_entry_id=entry.id,
                speaker_profile_id=prof.id,
                session_label=label,
                match_score=0.0,
                duration_sec=2.0,
            )
        )
    await db_session.commit()

    summaries = await build_speaker_summaries_for_entry(db_session, user_id, entry.id)
    by_label = {s.session_label: s for s in summaries}

    assert set(by_label) == {"Speaker_1", "Speaker_2"}

    # The more similar voice (Speaker_1) wins '나'.
    assert by_label["Speaker_1"].suggested_node is not None
    assert by_label["Speaker_1"].suggested_node.name == "나"

    # The other speaker must NOT also be suggested '나'.
    s2_suggested = by_label["Speaker_2"].suggested_node
    assert s2_suggested is None or s2_suggested.name != "나"

    # At most one speaker is ever suggested the same Person.
    suggested_node_ids = [
        s.suggested_node.id for s in summaries if s.suggested_node is not None
    ]
    assert len(suggested_node_ids) == len(set(suggested_node_ids))
