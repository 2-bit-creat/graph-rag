"""Two-phase journal graph build: a draft is staged for review, then apply commits
it into immutable nodes and clears the staging. Re-applying (or rebuilding) once
committed is rejected with 409 (code: graph_locked).

The draft step itself calls the LLM, so these tests exercise the commit half
(apply_entry_graph) with a hand-built staging draft — no network.
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from app import crud
from app.models import JournalEntry
from app.routers.journal import apply_entry_graph
from app.schemas import GraphApplyRequest


async def _staged_entry(db_session, user_id) -> JournalEntry:
    entry = JournalEntry(
        user_id=user_id,
        status="graph_staging_ready",
        source_type="개인일기",
        transcript_clean_ko="나는 말차를 만들었다.",
        translation_en="I made matcha.",
        graph_staging={
            "claims": [{
                "speaker": "나",
                "title": "말차",
                "statement": "나는 말차를 만들었다",
                "concepts": ["말차"],
            }],
            "context_type": "개인일기",
            "speaker_count": 1,
        },
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)
    return entry


@pytest.mark.asyncio
async def test_apply_commits_and_locks(db_session, iso_user):
    entry = await _staged_entry(db_session, iso_user.id)

    out = await apply_entry_graph(entry.id, None, iso_user, db_session)
    assert out.status == "graph_ready"

    # Graph nodes committed and provenance-linked to the entry.
    assert await crud.entry_has_graph_nodes(db_session, entry.id)
    await db_session.refresh(entry)
    assert entry.graph_staging is None
    assert entry.status == "graph_ready"

    # Re-apply blocked — graph is now immutable.
    with pytest.raises(HTTPException) as exc:
        await apply_entry_graph(entry.id, None, iso_user, db_session)
    assert exc.value.status_code == 409
    assert exc.value.detail["code"] == "graph_locked"


@pytest.mark.asyncio
async def test_apply_uses_edited_claims_from_payload(db_session, iso_user):
    entry = await _staged_entry(db_session, iso_user.id)
    payload = GraphApplyRequest(
        claims=[{
            "speaker": "나",
            "title": "커피",
            "statement": "나는 커피를 마셨다",
            "concepts": ["커피"],
        }],
        context_type="개인일기",
    )
    out = await apply_entry_graph(entry.id, payload, iso_user, db_session)
    assert out.status == "graph_ready"

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    names = {n.name for n in nodes}
    assert "커피" in names
    assert "말차" not in names  # the original draft concept was replaced by the edit


@pytest.mark.asyncio
async def test_apply_without_draft_is_400(db_session, iso_user):
    entry = JournalEntry(user_id=iso_user.id, status="ready")
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)
    with pytest.raises(HTTPException) as exc:
        await apply_entry_graph(entry.id, None, iso_user, db_session)
    assert exc.value.status_code == 400
