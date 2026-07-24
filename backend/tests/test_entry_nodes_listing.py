"""GET /journal/entries/{id}/nodes — the diary detail's "이 일기의 노드 보기".

The diary screen focuses the graph on the first node this returns, so the
Statement-first ordering and the soft-delete/ownership filtering are the
behaviour that matters here, not just the row count.
"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from app.models import JournalEntry, JournalGraphLink, Node
from app.routers.journal import list_entry_nodes


async def _entry_with_nodes(db_session, user_id):
    entry = JournalEntry(user_id=user_id, status="graph_ready")
    db_session.add(entry)
    await db_session.flush()

    # Added concept-first so a passing Statement-first assertion can't be an
    # accident of insertion order.
    concept = Node(user_id=user_id, name="말차", type="Concept")
    statement = Node(user_id=user_id, name="나는 말차를 좋아한다", type="Statement")
    db_session.add_all([concept, statement])
    await db_session.flush()
    db_session.add_all([
        JournalGraphLink(journal_entry_id=entry.id, node_id=concept.id),
        JournalGraphLink(journal_entry_id=entry.id, node_id=statement.id),
    ])
    await db_session.commit()
    return entry, statement, concept


@pytest.mark.asyncio
async def test_returns_entry_nodes_statement_first(db_session, iso_user):
    entry, statement, concept = await _entry_with_nodes(db_session, iso_user.id)

    nodes = await list_entry_nodes(entry.id, iso_user, db_session)

    assert [n["id"] for n in nodes] == [str(statement.id), str(concept.id)]
    assert nodes[0]["type"] == "Statement"
    assert nodes[1]["name"] == "말차"


@pytest.mark.asyncio
async def test_soft_deleted_nodes_are_excluded(db_session, iso_user):
    entry, statement, concept = await _entry_with_nodes(db_session, iso_user.id)
    concept.deleted_at = datetime.now(UTC)
    await db_session.commit()

    nodes = await list_entry_nodes(entry.id, iso_user, db_session)

    assert [n["id"] for n in nodes] == [str(statement.id)]


@pytest.mark.asyncio
async def test_unknown_entry_is_404(db_session, iso_user):
    import uuid

    from fastapi import HTTPException

    with pytest.raises(HTTPException) as exc:
        await list_entry_nodes(uuid.uuid4(), iso_user, db_session)
    assert exc.value.status_code == 404
