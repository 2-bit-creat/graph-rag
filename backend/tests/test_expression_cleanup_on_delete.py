"""Extracted expressions are keyed by Statement node id in a JSON file store.

They must not outlive their source node: deleting the journal entry, clearing the
whole graph, or any path that removes the node should drop its expressions. A
reconcile pass (prune_orphaned_node_expressions) also cleans up orphans that earlier
bulk-delete paths left behind.
"""

from __future__ import annotations

import pytest

from app import crud
from app.models import JournalEntry
from app.node_expression_store import (
    get_node_expressions_all_languages,
    save_node_expressions,
)


async def _entry_with_statement_and_expr(db_session, user_id):
    """Create an entry + a Statement node, and save an English expression for it."""
    entry = JournalEntry(user_id=user_id, status="ready")
    db_session.add(entry)
    await db_session.flush()

    speaker = await crud._get_or_create_node(db_session, name="나", type_="Speaker", user_id=user_id)
    stmt = await crud._get_or_create_node(db_session, name="마차를 만들었다고 말함", type_="Statement", user_id=user_id)
    concept = await crud._get_or_create_node(db_session, name="마차", type_="Concept", user_id=user_id)
    await crud.create_edge(db_session, source_id=speaker.id, target_id=stmt.id, relation="SPOKE_OR_PUBLISHED", user_id=user_id)
    await crud.create_edge(db_session, source_id=stmt.id, target_id=concept.id, relation="CONTEXT", user_id=user_id)
    await crud.record_journal_graph_links(db_session, entry.id, [speaker.id, stmt.id, concept.id], [])
    await db_session.commit()

    await save_node_expressions(
        user_id, str(stmt.id), "english",
        [{"expression": "build a cart", "meaning_ko": "마차를 만들다", "cefr": "B1"}],
        node_name=stmt.name,
    )
    return entry, stmt


async def _expr_count(user_id, node_id) -> int:
    exprs = await get_node_expressions_all_languages(user_id, str(node_id))
    return sum(len(v) for v in exprs.values())


@pytest.mark.asyncio
async def test_deleting_entry_removes_its_expressions(db_session, iso_user):
    user_id = iso_user.id
    entry, stmt = await _entry_with_statement_and_expr(db_session, user_id)
    assert await _expr_count(user_id, stmt.id) == 1

    await crud.delete_journal_entry(db_session, entry)

    assert await _expr_count(user_id, stmt.id) == 0


@pytest.mark.asyncio
async def test_clearing_graph_removes_all_expressions(db_session, iso_user):
    user_id = iso_user.id
    _, stmt = await _entry_with_statement_and_expr(db_session, user_id)
    assert await _expr_count(user_id, stmt.id) == 1

    await crud.clear_user_knowledge_graph(db_session, user_id)

    # Graph wiped → no live node → expressions gone.
    assert await _expr_count(user_id, stmt.id) == 0


@pytest.mark.asyncio
async def test_reconcile_prunes_orphan_left_by_earlier_bulk_delete(db_session, iso_user):
    """An expression saved under a node id that no longer exists must be pruned by the
    reconcile pass — covers orphans accumulated before the safety net existed."""
    import uuid

    user_id = iso_user.id
    ghost_node_id = uuid.uuid4()  # never inserted as a Node row
    await save_node_expressions(
        user_id, str(ghost_node_id), "english",
        [{"expression": "ghost", "meaning_ko": "유령", "cefr": "A1"}],
    )
    assert await _expr_count(user_id, ghost_node_id) == 1

    removed = await crud.prune_orphaned_node_expressions(db_session, user_id)

    assert removed == 1
    assert await _expr_count(user_id, ghost_node_id) == 0


@pytest.mark.asyncio
async def test_reconcile_keeps_live_node_expressions(db_session, iso_user):
    """Reconcile must not touch expressions whose Statement node still exists."""
    user_id = iso_user.id
    _, stmt = await _entry_with_statement_and_expr(db_session, user_id)

    removed = await crud.prune_orphaned_node_expressions(db_session, user_id)

    assert removed == 0
    assert await _expr_count(user_id, stmt.id) == 1
