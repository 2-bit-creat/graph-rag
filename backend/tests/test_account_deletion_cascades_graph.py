"""Deleting an account must destroy its knowledge graph.

`DELETE /auth/me` and the admin handle-delete both just `session.delete(user)`
and rely on FK cascade. `nodes` and `edges` predate multi-user support and had
`user_id` added by a bare ALTER with no REFERENCES clause, so on any long-lived
database that cascade silently did not exist — every deleted account left its
diary statements, the names of everyone it mentioned, and their relations in the
database forever.

A behavioural test alone cannot catch that regression: tests run against a
freshly created database, which gets the FK from `Base.metadata.create_all` and
passes. So this file asserts the *constraint* as well as the behaviour.
"""

from __future__ import annotations

import pytest
from sqlalchemy import func, select, text

from app import crud
from app.models import Edge, Node, User


@pytest.mark.parametrize("table", ["nodes", "edges"])
@pytest.mark.asyncio
async def test_user_scoped_graph_tables_declare_a_cascading_user_fk(db_session, table):
    """The schema-level guarantee, independent of any one delete going through."""
    row = (
        await db_session.execute(
            text(
                """
                SELECT confdeltype
                  FROM pg_constraint
                 WHERE conrelid = :table ::regclass
                   AND contype = 'f'
                   AND confrelid = 'users'::regclass
                """
            ),
            {"table": table},
        )
    ).first()
    assert row is not None, (
        f"{table}.user_id has no foreign key to users — deleting an account will "
        f"leave its rows behind. Run scripts/purge_orphan_graph.py --apply."
    )
    # 'c' = ON DELETE CASCADE. Anything else (SET NULL, NO ACTION) leaves the
    # graph readable-by-nobody instead of destroying it. Postgres' "char" column
    # arrives as bytes through asyncpg.
    action = row[0].decode() if isinstance(row[0], bytes) else row[0]
    assert action == "c", f"{table}.user_id FK must be ON DELETE CASCADE, got {action!r}"


@pytest.mark.asyncio
async def test_deleting_a_user_removes_their_nodes_and_edges(db_session, iso_user):
    # iso_user, not a hand-rolled User: its teardown is ordered against
    # db_session's own rollback/engine.dispose (see conftest), and deleting the
    # row here just makes that cleanup a no-op.
    user_id = iso_user.id

    statement = await crud._get_or_create_node(
        db_session, name=f"S{user_id.hex[:6]}", type_="Statement", user_id=user_id
    )
    concept = await crud._get_or_create_node(
        db_session, name=f"C{user_id.hex[:6]}", type_="Concept", user_id=user_id
    )
    await db_session.commit()
    db_session.add(
        Edge(
            source_id=statement.id,
            target_id=concept.id,
            relation="CONTEXT",
            user_id=user_id,
        )
    )
    await db_session.commit()

    async def counts() -> tuple[int, int]:
        nodes = await db_session.scalar(
            select(func.count()).select_from(Node).where(Node.user_id == user_id)
        )
        edges = await db_session.scalar(
            select(func.count()).select_from(Edge).where(Edge.user_id == user_id)
        )
        return int(nodes), int(edges)

    assert await counts() == (2, 1)

    user = await db_session.get(User, user_id)
    await db_session.delete(user)  # exactly what the delete-account endpoints do
    await db_session.commit()

    assert await counts() == (0, 0)
