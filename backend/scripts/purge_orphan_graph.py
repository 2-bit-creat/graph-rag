"""Delete graph rows belonging to accounts that no longer exist, then install
the foreign key that should have prevented them.

WHY THESE ROWS EXIST
--------------------
``nodes`` and ``edges`` predate multi-user support. ``user_id`` was added to them
by a bare ``ALTER TABLE ... ADD COLUMN`` with no ``REFERENCES`` clause, so neither
table ever got a foreign key to ``users``. Every other user-scoped table has one,
because they were created later by ``Base.metadata.create_all`` — which declares
the FK but will not add it to a table that already exists.

``DELETE /auth/me`` and the admin handle-delete both just ``session.delete(user)``
and rely on "FK cascade clears the rows". For nodes and edges that cascade never
existed, so **deleting an account left its entire knowledge graph behind** —
diary statements, the names of everyone mentioned, and their relations. That is a
완전파기 (complete-destruction) failure, not merely wasted space.

The test suite cannot catch this: tests run against a freshly created database,
which gets the FK from ``create_all`` and behaves correctly. Only long-lived
databases (dev, production) carry the drift.

SAFETY
------
* Rows with ``user_id IS NULL`` are pre-multi-user legacy data and are never
  touched.
* Only rows whose ``user_id`` has no matching ``users`` row are deleted. Those
  are unreachable by definition — every application query filters by user.
* Dry run by default. Pass ``--apply`` to actually delete.
* Deleting a node cascades to its edges (edges→nodes FKs already have
  ON DELETE CASCADE), so edges are cleaned up in the same transaction.

Run once per environment:

    python -m scripts.purge_orphan_graph            # report only
    python -m scripts.purge_orphan_graph --apply    # delete + add the constraint
"""

from __future__ import annotations

import argparse
import asyncio

from sqlalchemy import text

from app.db import engine

_ORPHAN_NODES = """
SELECT count(*) FROM nodes n
 WHERE n.user_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = n.user_id)
"""

_ORPHAN_EDGES = """
SELECT count(*) FROM edges e
 WHERE e.user_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = e.user_id)
"""

_ORPHAN_ACCOUNTS = """
SELECT count(DISTINCT n.user_id) FROM nodes n
 WHERE n.user_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = n.user_id)
"""

_DELETE_EDGES = """
DELETE FROM edges e
 WHERE e.user_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = e.user_id)
"""

_DELETE_NODES = """
DELETE FROM nodes n
 WHERE n.user_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = n.user_id)
"""

# Idempotent: skips whatever is already in place, so re-running is harmless.
_ADD_CONSTRAINTS = """
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'nodes'::regclass
           AND contype = 'f' AND confrelid = 'users'::regclass
    ) THEN
        ALTER TABLE nodes
            ADD CONSTRAINT nodes_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'edges'::regclass
           AND contype = 'f' AND confrelid = 'users'::regclass
    ) THEN
        ALTER TABLE edges
            ADD CONSTRAINT edges_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
    END IF;
END $$;
"""

_HAS_FK = """
SELECT count(*) FROM pg_constraint
 WHERE conrelid = :table ::regclass
   AND contype = 'f' AND confrelid = 'users'::regclass
"""


async def main(apply: bool) -> None:
    async with engine.begin() as conn:
        nodes = await conn.scalar(text(_ORPHAN_NODES))
        edges = await conn.scalar(text(_ORPHAN_EDGES))
        accounts = await conn.scalar(text(_ORPHAN_ACCOUNTS))
        node_fk = await conn.scalar(text(_HAS_FK), {"table": "nodes"})
        edge_fk = await conn.scalar(text(_HAS_FK), {"table": "edges"})
        total_nodes = await conn.scalar(text("SELECT count(*) FROM nodes"))

        share = f" ({nodes / total_nodes:.0%} of the table)" if total_nodes else ""
        print(f"orphan nodes    : {nodes}{share}")
        print(f"orphan edges    : {edges}")
        print(f"deleted accounts: {accounts}")
        print(f"nodes.user_id FK: {'present' if node_fk else 'MISSING'}")
        print(f"edges.user_id FK: {'present' if edge_fk else 'MISSING'}")

        if not apply:
            print("\ndry run - pass --apply to delete these rows and add the constraints")
            return

        if nodes or edges:
            # Edges first: deleting nodes would cascade them anyway, but doing it
            # explicitly also catches edges whose endpoints were already removed.
            deleted_edges = (await conn.execute(text(_DELETE_EDGES))).rowcount
            deleted_nodes = (await conn.execute(text(_DELETE_NODES))).rowcount
            print(f"\ndeleted {deleted_nodes} nodes, {deleted_edges} edges")

        await conn.execute(text(_ADD_CONSTRAINTS))
        node_fk = await conn.scalar(text(_HAS_FK), {"table": "nodes"})
        edge_fk = await conn.scalar(text(_HAS_FK), {"table": "edges"})
        print(f"nodes.user_id FK: {'present' if node_fk else 'STILL MISSING'}")
        print(f"edges.user_id FK: {'present' if edge_fk else 'STILL MISSING'}")
        print("\naccount deletion now cascades to the graph")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually delete the orphan rows (default: report only)",
    )
    asyncio.run(main(parser.parse_args().apply))
