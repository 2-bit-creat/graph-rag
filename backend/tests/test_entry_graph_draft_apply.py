"""Two-phase journal graph build: a draft is staged for review, then apply commits
it into immutable nodes and clears the staging. Re-applying (or rebuilding) once
committed is rejected with 409 (code: graph_locked).

The draft step itself calls the LLM, so these tests exercise the commit half
(apply_entry_graph) with a hand-built staging draft — no network.

The commit itself runs as a background task (see ``run_entry_graph_commit``), so
these drive the BackgroundTasks the endpoint collected, exactly as Starlette
would after the response is sent.
"""

from __future__ import annotations

import pytest
from fastapi import BackgroundTasks, HTTPException

from app import crud
from app.models import JournalEntry
from app.routers.journal import apply_entry_graph
from app.schemas import GraphApplyRequest


async def _staged_entry(db_session, user_id) -> JournalEntry:
    entry = JournalEntry(
        user_id=user_id,
        status="graph_staging_ready",
        source_type="개인일기",
        transcript_clean_native="나는 말차를 만들었다.",
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


async def _apply(entry_id, payload, user, session) -> tuple:
    """Call the endpoint, then run whatever it handed to the background."""
    tasks = BackgroundTasks()
    out = await apply_entry_graph(entry_id, payload, user, session, background_tasks=tasks)
    await tasks()
    return out


@pytest.mark.asyncio
async def test_apply_commits_and_locks(db_session, iso_user):
    entry = await _staged_entry(db_session, iso_user.id)

    out = await _apply(entry.id, None, iso_user, db_session)
    # The request only accepts the work; the entry's status reports the result.
    assert out.status == "graph_committing"

    # Graph nodes committed and provenance-linked to the entry.
    assert await crud.entry_has_graph_nodes(db_session, entry.id)
    await db_session.refresh(entry)
    assert entry.graph_staging is None
    assert entry.status == "graph_ready"

    # Re-apply blocked — graph is now immutable.
    with pytest.raises(HTTPException) as exc:
        await apply_entry_graph(entry.id, None, iso_user, db_session, background_tasks=BackgroundTasks())
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
    await _apply(entry.id, payload, iso_user, db_session)

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
        await apply_entry_graph(entry.id, None, iso_user, db_session, background_tasks=BackgroundTasks())
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_second_apply_while_committing_does_not_start_a_second_commit(
    db_session, iso_user
):
    """A double tap must not run the commit twice — the second call is a no-op.

    Without this the two runs race and can double-write the same claims, which
    is exactly what the client's retry-after-timeout used to trigger.
    """
    entry = await _staged_entry(db_session, iso_user.id)

    first = BackgroundTasks()
    await apply_entry_graph(entry.id, None, iso_user, db_session, background_tasks=first)
    second = BackgroundTasks()
    out = await apply_entry_graph(entry.id, None, iso_user, db_session, background_tasks=second)

    assert out.status == "graph_committing"
    assert second.tasks == []
    await first()
    await db_session.refresh(entry)
    assert entry.status == "graph_ready"


@pytest.mark.asyncio
async def test_failed_commit_marks_the_entry_and_keeps_the_draft(
    db_session, iso_user, monkeypatch
):
    """A commit that blows up must leave a retryable, explained failure.

    graph_failed is what the client renders as an error; keeping graph_staging
    means the user's reviewed draft is still there to re-commit.
    """
    entry = await _staged_entry(db_session, iso_user.id)

    async def _boom(*args, **kwargs):
        raise RuntimeError("commit exploded")

    monkeypatch.setattr("app.routers.kg_build.persist_entry_claims", _boom)

    tasks = BackgroundTasks()
    await apply_entry_graph(entry.id, None, iso_user, db_session, background_tasks=tasks)
    with pytest.raises(RuntimeError):
        await tasks()

    await db_session.refresh(entry)
    assert entry.status == "graph_failed"
    assert entry.graph_staging is not None
    assert not await crud.entry_has_graph_nodes(db_session, entry.id)
