"""Repair speaker_profile_id on journal segments after voice-data wipe."""

from __future__ import annotations

import pytest

from app.models import JournalEntry
from app.speaker_profiles import repair_entry_speaker_bindings


@pytest.mark.asyncio
async def test_repair_entry_speaker_bindings_restores_segment_profile_ids(
    db_session, dev_user
):
    user_id = dev_user.id
    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_segments=[
            {"speaker": "Speaker_1", "text": "hello"},
            {"speaker": "Speaker_2", "text": "world"},
        ],
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)

    changed = await repair_entry_speaker_bindings(db_session, user_id, entry)
    assert changed is True
    await db_session.refresh(entry)

    segs = entry.transcript_segments or []
    assert segs[0].get("speaker_profile_id")
    assert segs[1].get("speaker_profile_id")
    assert segs[0]["speaker_profile_id"] != segs[1]["speaker_profile_id"]
