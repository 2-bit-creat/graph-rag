"""A finished generation run stays visible on the Statement it ran for.

The graph card starts a run and then watches this payload for the outcome.  It
only ever saw *active* runs, so a run that failed disappeared the moment it
stopped being active: `generation.status` fell back to "idle", no new quizzes
appeared, and the client polled a run that would never move until its own
three-minute clock expired and announced "문제를 만들지 못했어요" — a client timeout
wearing the costume of a server error, with the worker's actual error message
nowhere on screen.

Reporting the latest run regardless of status is what lets the card tell those
apart.  The terminal statuses are outside {queued, running}, so the three places
that read this field to mean "still preparing" are unaffected.
"""

from __future__ import annotations

import json
import uuid

import pytest
from fastapi import BackgroundTasks

from app.models import Node, QuizGenerationRun
from app.routers.graph import read_node_study_quizzes


async def _statement(db_session, user) -> Node:
    node = Node(
        user_id=user.id,
        name=f"stmt-{uuid.uuid4()}",
        type="Statement",
        description=json.dumps({"content": "a claim worth studying"}),
    )
    db_session.add(node)
    await db_session.flush()
    return node


async def _run(db_session, user, node, *, status, items) -> QuizGenerationRun:
    run = QuizGenerationRun(
        user_id=user.id,
        idempotency_key=f"test:{uuid.uuid4()}",
        source="node_selected",
        status=status,
        node_ids=[str(node.id)],
        languages=["english"],
        items=items,
        total_count=len(items),
        completed_count=sum(i.get("status") == "completed" for i in items),
        failed_count=sum(i.get("status") == "failed" for i in items),
    )
    db_session.add(run)
    await db_session.flush()
    return run


@pytest.mark.asyncio
async def test_failed_run_reports_its_status_and_error(
    db_session, iso_user
) -> None:
    node = await _statement(db_session, iso_user)
    await _run(
        db_session,
        iso_user,
        node,
        status="failed",
        items=[
            {
                "node_id": str(node.id),
                "language": "english",
                "status": "failed",
                "error": "quiz bundle seed mismatch",
            }
        ],
    )

    result = await read_node_study_quizzes(
        node.id, BackgroundTasks(), iso_user, db_session
    )

    assert result["generation"]["status"] == "failed"
    assert result["generation"]["error"] == "quiz bundle seed mismatch"


@pytest.mark.asyncio
async def test_running_run_still_wins_over_an_older_finished_one(
    db_session, iso_user
) -> None:
    node = await _statement(db_session, iso_user)
    await _run(
        db_session,
        iso_user,
        node,
        status="failed",
        items=[{"status": "failed", "error": "old news"}],
    )
    await _run(db_session, iso_user, node, status="running", items=[])

    result = await read_node_study_quizzes(
        node.id, BackgroundTasks(), iso_user, db_session
    )

    # The card must keep showing the spinner while work is in flight, whatever
    # happened on an earlier attempt.
    assert result["generation"]["status"] == "running"
    assert result["generation"]["error"] is None


@pytest.mark.asyncio
async def test_a_statement_never_generated_reads_idle(db_session, iso_user) -> None:
    node = await _statement(db_session, iso_user)

    result = await read_node_study_quizzes(
        node.id, BackgroundTasks(), iso_user, db_session
    )

    assert result["generation"] == {"run_id": None, "status": "idle", "error": None}


@pytest.mark.asyncio
async def test_another_statements_run_is_not_reported_here(
    db_session, iso_user
) -> None:
    mine = await _statement(db_session, iso_user)
    other = await _statement(db_session, iso_user)
    await _run(
        db_session,
        iso_user,
        other,
        status="failed",
        items=[{"status": "failed", "error": "not about this node"}],
    )

    result = await read_node_study_quizzes(
        mine.id, BackgroundTasks(), iso_user, db_session
    )

    assert result["generation"]["status"] == "idle"
