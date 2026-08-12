"""Collapse the retired ``Person`` node type into ``Identity``, graph-wide.

WHY
---
``Person`` and ``Identity`` were two names for one thing. The only behavioural
differences were two auto-promotion paths (a generic Identity became a Person
the moment it headed a statement, or got a confirmed voice), the self node's
type, and a canvas tier — everything else already ran off
``entity_types.is_identity_type``. "This identity is a real person" is recorded
by a bound ``speaker_profiles`` row, not by a type string, so the type carried
no information the graph didn't already have.

This script applies ``crud.repair_identity_types`` to every account:

1. merges same-name duplicates inside the identity merge group (a user with both
   a ``Person 마야`` and an ``Identity 마야`` ends up with one node, keeping
   aliases, importance score, edges and journal provenance) — this must happen
   before the retype, or ``uq_node_user_name_type`` would reject it;
2. retypes every legacy identity string (person / speaker / 화자 / …) to
   ``Identity``;
3. realigns every Statement relation to match its endpoints
   (``MENTIONS`` ↔ ``CONTEXT``, and a demoted head's ``SPOKE_OR_PUBLISHED`` is
   reversed into ``Statement --CONTEXT--> node``);
4. drops alias embeddings from non-identity nodes and backfills missing ones.

IRREVERSIBILITY — read before ``--apply``
-----------------------------------------
For an identity WITHOUT a voice profile, "it used to be typed Person" is not
recoverable from the database afterwards: a voiceless Person and a pet both end
up as plain ``Identity``. So the script writes a JSON report of every row it is
about to retype (user_id, node_id, name, old_type, has_voice) BEFORE touching
anything. Keep that file — it is the only way to reverse the decision.

The run is idempotent: a second pass reports all zeros.

    python -m scripts.collapse_person_into_identity                  # report only
    python -m scripts.collapse_person_into_identity --apply
    python -m scripts.collapse_person_into_identity --apply --report out.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import select

from app import crud
from app.db import async_session_factory
from app.models import User

_DEFAULT_REPORT = "person_to_identity_report.json"


async def main(apply: bool, report_path: str) -> None:
    totals: dict[str, int] = {}
    all_rows: list[dict] = []

    async with async_session_factory() as session:
        user_ids = list((await session.execute(select(User.id))).scalars().all())
        print(f"accounts: {len(user_ids)}")

        for user_id in user_ids:
            preview = await crud.identity_type_repair_preview(session, user_id)
            all_rows.extend(preview)
            if not apply:
                continue

            counts = await crud.repair_identity_types(session, user_id)
            await session.commit()
            for key, value in counts.items():
                totals[key] = totals.get(key, 0) + value

    voiceless = sum(1 for r in all_rows if not r["has_voice"])
    print(f"legacy-typed nodes  : {len(all_rows)}")
    print(f"  ...without a voice: {voiceless}  (type origin unrecoverable after apply)")

    if not all_rows:
        print("\nnothing to do")
        return

    if not apply:
        print("\ndry run - pass --apply to retype these rows")
        for row in all_rows[:20]:
            print(f"  {row['old_type']:<10} {row['name']}")
        if len(all_rows) > 20:
            print(f"  ... and {len(all_rows) - 20} more")
        return

    # Written after the run so the file also records that it completed; the rows
    # themselves were captured from the pre-retype state.
    path = Path(report_path)
    path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "rows": all_rows,
                "totals": totals,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    print(f"\nreport: {path.resolve()}")
    for key in sorted(totals):
        print(f"  {key}: {totals[key]}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually retype and repair (default: report only)",
    )
    parser.add_argument(
        "--report",
        default=_DEFAULT_REPORT,
        help=f"where to write the pre-apply JSON report (default: {_DEFAULT_REPORT})",
    )
    args = parser.parse_args()
    asyncio.run(main(args.apply, args.report))
