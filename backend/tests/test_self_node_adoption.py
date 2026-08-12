"""The self node must not fork on a graph that predates the Person collapse.

get_or_create_self_node used to look for a node whose type was literally
'Person'. Once new self nodes are created as 'Identity', that narrow lookup
would miss the owner's existing '나' and silently create a second one — two
nodes for the diary owner, splitting every statement they ever made.
"""

from __future__ import annotations

import pytest

from app import crud


@pytest.mark.asyncio
@pytest.mark.parametrize("legacy_type", ["Person", "Speaker", "Identity"])
async def test_existing_na_node_is_adopted_not_forked(
    db_session, iso_user, legacy_type
):
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    legacy = await crud._get_or_create_node(
        db_session, name="나", type_=legacy_type, user_id=user_id
    )
    await db_session.commit()

    self_node = await crud.get_or_create_self_node(db_session, user_id)
    await db_session.commit()

    assert self_node.id == legacy.id
    assert self_node.is_self is True

    na_nodes = [
        n
        for n in await crud.get_all_nodes(db_session, user_id)
        if n.name == "나" and n.deleted_at is None
    ]
    assert len(na_nodes) == 1


@pytest.mark.asyncio
async def test_a_concept_named_na_is_not_adopted(db_session, iso_user):
    """Only identity-category nodes qualify — a Concept '나' is something else."""
    user_id = iso_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    concept = await crud._get_or_create_node(
        db_session, name="나", type_="Concept", user_id=user_id
    )
    await db_session.commit()

    self_node = await crud.get_or_create_self_node(db_session, user_id)
    await db_session.commit()

    assert self_node.id != concept.id
    assert self_node.type == "Identity"
    assert self_node.is_self is True
