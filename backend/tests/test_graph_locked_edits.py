"""Once a knowledge graph is committed for an entry, its structural inputs —
content type and speaker grouping/identity — are locked. Editing them would
silently desync the already-built graph, so the router rejects with 409
(code: graph_locked). The user must delete the graph and rebuild to change them.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi import HTTPException

from app.models import JournalEntry, JournalGraphLink, Node
from app.routers.journal import remap_speakers, set_source_type
from app.schemas import SourceTypeUpdate, SpeakerRemapRequest


async def _entry(db_session, user_id, *, with_graph: bool) -> JournalEntry:
    entry = JournalEntry(
        user_id=user_id,
        status="graph_ready" if with_graph else "ready",
        source_type="대화",
        transcript_segments=[
            {"speaker": "Speaker_1", "text": "a", "start_sec": 0.0, "end_sec": 1.0},
            {"speaker": "Speaker_2", "text": "b", "start_sec": 1.0, "end_sec": 2.0},
        ],
    )
    db_session.add(entry)
    await db_session.flush()
    if with_graph:
        node = Node(user_id=user_id, name="말차", type="Concept")
        db_session.add(node)
        await db_session.flush()
        db_session.add(JournalGraphLink(journal_entry_id=entry.id, node_id=node.id))
    await db_session.commit()
    await db_session.refresh(entry)
    return entry


@pytest.mark.asyncio
async def test_set_source_type_blocked_once_graph_built(db_session, iso_user):
    entry = await _entry(db_session, iso_user.id, with_graph=True)
    with pytest.raises(HTTPException) as exc:
        await set_source_type(
            entry.id, SourceTypeUpdate(source_type="회의록"), iso_user, db_session
        )
    assert exc.value.status_code == 409
    assert exc.value.detail["code"] == "graph_locked"
    # Source type unchanged.
    await db_session.refresh(entry)
    assert entry.source_type == "대화"


@pytest.mark.asyncio
async def test_remap_speakers_blocked_once_graph_built(db_session, iso_user):
    entry = await _entry(db_session, iso_user.id, with_graph=True)
    with pytest.raises(HTTPException) as exc:
        await remap_speakers(
            entry.id, SpeakerRemapRequest(to_self=True), iso_user, db_session
        )
    assert exc.value.status_code == 409
    assert exc.value.detail["code"] == "graph_locked"


@pytest.mark.asyncio
async def test_edits_allowed_before_graph_built(db_session, iso_user):
    entry = await _entry(db_session, iso_user.id, with_graph=False)
    out = await set_source_type(
        entry.id, SourceTypeUpdate(source_type="회의록"), iso_user, db_session
    )
    assert out.source_type == "회의록"


@pytest.mark.asyncio
async def test_lock_is_404_for_missing_entry(db_session, iso_user):
    with pytest.raises(HTTPException) as exc:
        await set_source_type(
            uuid.uuid4(), SourceTypeUpdate(source_type="회의록"), iso_user, db_session
        )
    assert exc.value.status_code == 404
