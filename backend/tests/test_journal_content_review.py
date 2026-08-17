from __future__ import annotations

import pytest
from fastapi import HTTPException

from app.models import JournalEntry
from app.routers.journal import update_reviewed_content
from app.schemas import JournalContentReviewUpdate


@pytest.mark.asyncio
async def test_reviewed_content_updates_text_without_changing_speaker_shape(
    db_session, iso_user
):
    entry = JournalEntry(
        user_id=iso_user.id,
        status="ready",
        transcript_native="raw one\nraw two",
        transcript_clean_native="clean one\nclean two",
        transcript_segments=[
            {"speaker": "Speaker_1", "text": "clean one", "start_sec": 0.0},
            {"speaker": "Speaker_2", "text": "clean two", "start_sec": 2.0},
        ],
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)

    out = await update_reviewed_content(
        entry.id,
        JournalContentReviewUpdate(segment_texts=["edited one", "edited two"]),
        iso_user,
        db_session,
    )

    assert [segment["speaker"] for segment in out.transcript_segments] == [
        "Speaker_1",
        "Speaker_2",
    ]
    assert [segment["text"] for segment in out.transcript_segments] == [
        "edited one",
        "edited two",
    ]
    assert out.transcript_segments[0]["text_raw"] == "clean one"


@pytest.mark.asyncio
async def test_reviewed_content_is_locked_after_graph_extraction_starts(
    db_session, iso_user
):
    entry = JournalEntry(
        user_id=iso_user.id,
        status="graph_processing",
        transcript_segments=[{"speaker": "Speaker_1", "text": "clean"}],
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)

    with pytest.raises(HTTPException) as error:
        await update_reviewed_content(
            entry.id,
            JournalContentReviewUpdate(segment_texts=["too late"]),
            iso_user,
            db_session,
        )

    assert error.value.status_code == 409
    assert error.value.detail["code"] == "content_review_closed"
