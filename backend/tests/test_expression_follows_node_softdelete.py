"""Q1 decision: extracted expressions are children of their Statement node.

Soft-deleting a Statement moves its expressions into the node's deleted_context
snapshot (gone from the active store / 단어장); restoring the node brings them back.
Purging removes them for good.
"""

from __future__ import annotations

import pytest

from app.crud import (
    purge_trash_node,
    restore_statement_from_trash,
    soft_delete_statement_cascade,
)
from app.models import Node
from app.node_expression_store import (
    get_node_expressions_all_languages,
    save_node_expressions,
)


async def _statement_with_expression(db_session, user_id) -> Node:
    node = Node(
        user_id=user_id,
        name="말차를 만들었다",
        type="Statement",
        description='{"context_type":"개인일기","content":"나는 말차를 만들었다"}',
    )
    db_session.add(node)
    await db_session.commit()
    await db_session.refresh(node)
    await save_node_expressions(
        user_id,
        str(node.id),
        "english",
        [{
            "expression": "make matcha",
            "meaning_ko": "말차를 만들다",
            "example_en": "I make matcha every morning.",
            "cefr": "B1",
        }],
        node_name=node.name,
    )
    return node


@pytest.mark.asyncio
async def test_expression_follows_softdelete_and_restore(db_session, iso_user):
    node = await _statement_with_expression(db_session, iso_user.id)
    before = await get_node_expressions_all_languages(iso_user.id, str(node.id))
    assert before.get("english")

    # Soft-delete → expressions leave the active store, snapshot stored on the node.
    res = await soft_delete_statement_cascade(db_session, node.id, iso_user.id)
    assert res["deleted_node_id"] == str(node.id)
    mid = await get_node_expressions_all_languages(iso_user.id, str(node.id))
    assert not mid.get("english")
    await db_session.refresh(node)
    assert node.deleted_at is not None
    assert node.deleted_context.get("expressions", {}).get("entry")

    # Restore → expressions come back (Statement id preserved, so the key matches).
    ok = await restore_statement_from_trash(db_session, node.id, iso_user.id)
    assert ok
    after = await get_node_expressions_all_languages(iso_user.id, str(node.id))
    assert after.get("english")
    assert after["english"][0]["expression"] == "make matcha"


@pytest.mark.asyncio
async def test_expression_purged_with_node(db_session, iso_user):
    node = await _statement_with_expression(db_session, iso_user.id)
    await soft_delete_statement_cascade(db_session, node.id, iso_user.id)
    ok = await purge_trash_node(db_session, node.id, iso_user.id)
    assert ok
    gone = await get_node_expressions_all_languages(iso_user.id, str(node.id))
    assert not gone.get("english")
