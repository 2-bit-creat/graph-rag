"""Reversible speaker remap: merge / collapse-to-self / reset, with the original
diarization preserved on each segment (speaker_original)."""

from __future__ import annotations

import pytest

from app import crud
from app.models import JournalEntry, SpeakerEntryAppearance, SpeakerProfile


async def _two_speaker_entry(db_session, user_id):
    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_segments=[
            {"speaker": "Speaker_1", "text": "저는 말차를 만들었어요.", "start_sec": 0.0, "end_sec": 2.0},
            {"speaker": "Speaker_2", "text": "저는 말차를 마실 거예요.", "start_sec": 2.0, "end_sec": 4.0},
        ],
    )
    db_session.add(entry)
    await db_session.flush()
    for label in ("Speaker_1", "Speaker_2"):
        prof = SpeakerProfile(user_id=user_id, label=label, embedding=[0.1] * 256,
                              sample_count=1, total_duration_sec=2.0)
        db_session.add(prof)
        await db_session.flush()
        db_session.add(SpeakerEntryAppearance(
            journal_entry_id=entry.id, speaker_profile_id=prof.id,
            session_label=label, match_score=0.0, duration_sec=2.0))
    await db_session.commit()
    await db_session.refresh(entry)
    return entry


def _speakers(entry):
    return [s["speaker"] for s in entry.transcript_segments if isinstance(s, dict)]


def _originals(entry):
    return [s.get("speaker_original") for s in entry.transcript_segments if isinstance(s, dict)]


@pytest.mark.asyncio
async def test_to_self_collapses_all_and_is_reversible(db_session, iso_user):
    user_id = iso_user.id
    entry = await _two_speaker_entry(db_session, user_id)

    res = await crud.remap_entry_speakers(db_session, user_id, entry, to_self=True)
    assert res["labels"] == ["나"]
    assert _speakers(entry) == ["나", "나"]
    # Original diarization preserved for reset.
    assert _originals(entry) == ["Speaker_1", "Speaker_2"]
    # One appearance now (the vanished labels' appearances were dropped).
    apps = await crud.list_speaker_appearances_for_entry(db_session, entry.id)
    assert {a.session_label for a in apps} == {"나"}

    # Reset restores the original two speakers.
    res2 = await crud.remap_entry_speakers(db_session, user_id, entry, reset=True)
    assert set(res2["labels"]) == {"Speaker_1", "Speaker_2"}
    assert _speakers(entry) == ["Speaker_1", "Speaker_2"]
    apps2 = await crud.list_speaker_appearances_for_entry(db_session, entry.id)
    assert {a.session_label for a in apps2} == {"Speaker_1", "Speaker_2"}


@pytest.mark.asyncio
async def test_merge_all_collapses_to_dominant_and_needs_confirmation(db_session, iso_user):
    user_id = iso_user.id
    entry = await _two_speaker_entry(db_session, user_id)
    # Make Speaker_1 the dominant (longer) speaker.
    segs = [dict(s) for s in entry.transcript_segments]
    segs[0]["end_sec"] = 10.0  # Speaker_1 longer
    entry.transcript_segments = segs
    await db_session.commit()

    res = await crud.remap_entry_speakers(db_session, user_id, entry, merge_all=True)
    # Collapsed into the dominant label — NOT forced to '나'.
    assert res["labels"] == ["Speaker_1"]
    assert _speakers(entry) == ["Speaker_1", "Speaker_1"]
    assert _originals(entry) == ["Speaker_1", "Speaker_2"]

    apps = await crud.list_speaker_appearances_for_entry(db_session, entry.id)
    assert {a.session_label for a in apps} == {"Speaker_1"}
    # Identity left unconfirmed for the user to assign.
    assert all(a.match_score < 0.999 for a in apps)

    # Still reversible.
    await crud.remap_entry_speakers(db_session, user_id, entry, reset=True)
    assert set(_speakers(entry)) == {"Speaker_1", "Speaker_2"}


@pytest.mark.asyncio
async def test_pairwise_merge(db_session, iso_user):
    user_id = iso_user.id
    entry = await _two_speaker_entry(db_session, user_id)

    res = await crud.remap_entry_speakers(
        db_session, user_id, entry, merges={"Speaker_2": "Speaker_1"})
    assert res["labels"] == ["Speaker_1"]
    assert _speakers(entry) == ["Speaker_1", "Speaker_1"]
    apps = await crud.list_speaker_appearances_for_entry(db_session, entry.id)
    assert {a.session_label for a in apps} == {"Speaker_1"}
    # Merged segment's profile id points at the surviving label's profile.
    pids = {s.get("speaker_profile_id") for s in entry.transcript_segments}
    assert len(pids) == 1


@pytest.mark.asyncio
async def test_group_map_partial_merge_keeps_third_separate(db_session, iso_user):
    """Merge Speaker_1+Speaker_2 but keep Speaker_3 — the drag-merge case."""
    user_id = iso_user.id
    entry = JournalEntry(
        user_id=user_id, status="ready",
        transcript_segments=[
            {"speaker": "Speaker_1", "text": "a", "start_sec": 0.0, "end_sec": 1.0},
            {"speaker": "Speaker_2", "text": "b", "start_sec": 1.0, "end_sec": 2.0},
            {"speaker": "Speaker_3", "text": "c", "start_sec": 2.0, "end_sec": 3.0},
        ],
    )
    db_session.add(entry)
    await db_session.commit()

    res = await crud.remap_entry_speakers(
        db_session, user_id, entry,
        group_map={"Speaker_1": "Speaker_1", "Speaker_2": "Speaker_1", "Speaker_3": "Speaker_3"},
    )
    assert set(res["labels"]) == {"Speaker_1", "Speaker_3"}
    assert _speakers(entry) == ["Speaker_1", "Speaker_1", "Speaker_3"]
    assert _originals(entry) == ["Speaker_1", "Speaker_2", "Speaker_3"]
    apps = await crud.list_speaker_appearances_for_entry(db_session, entry.id)
    assert {a.session_label for a in apps} == {"Speaker_1", "Speaker_3"}

    # Splitting back via group_map (each original to itself) restores all three.
    await crud.remap_entry_speakers(
        db_session, user_id, entry,
        group_map={"Speaker_1": "Speaker_1", "Speaker_2": "Speaker_2", "Speaker_3": "Speaker_3"},
    )
    assert _speakers(entry) == ["Speaker_1", "Speaker_2", "Speaker_3"]


@pytest.mark.asyncio
async def test_remap_noop_on_empty_segments(db_session, iso_user):
    user_id = iso_user.id
    entry = JournalEntry(user_id=user_id, status="ready", transcript_segments=[])
    db_session.add(entry)
    await db_session.commit()
    res = await crud.remap_entry_speakers(db_session, user_id, entry, to_self=True)
    assert res["changed"] is False
