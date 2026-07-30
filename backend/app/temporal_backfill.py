"""Deterministic, auditable backfill of event-time metadata for Statements."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .graph_retrieval import statement_content
from .models import JournalEntry, JournalGraphLink, Node, TemporalBackfillAudit
from .temporal import resolve_event_temporal


def _snapshot(node: Node) -> dict:
    return {
        "occurred_at": node.occurred_at.isoformat() if node.occurred_at else None,
        "event_start_at": node.event_start_at.isoformat() if node.event_start_at else None,
        "event_end_at": node.event_end_at.isoformat() if node.event_end_at else None,
        "temporal_precision": node.temporal_precision,
        "temporal_confidence": node.temporal_confidence,
        "temporal_source_text": node.temporal_source_text,
        "event_status": node.event_status,
    }


async def backfill_statement_event_times(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    timezone_name: str,
    run_key: str | None = None,
    dry_run: bool = False,
) -> dict:
    """Recompute Statements from linked source entries and retain every change.

    It deliberately does not invoke an LLM. Explicit dates and relative phrases
    are safe to repair automatically; claims with no explicit phrase are returned
    as a low-confidence review queue rather than being presented as extracted fact.
    """
    run_key = run_key or str(uuid.uuid4())
    rows = await session.execute(
        select(Node, JournalEntry)
        .join(JournalGraphLink, JournalGraphLink.node_id == Node.id)
        .join(JournalEntry, JournalEntry.id == JournalGraphLink.journal_entry_id)
        .where(Node.user_id == user_id, Node.type == "Statement", Node.deleted_at.is_(None))
        .order_by(Node.created_at)
    )
    changed = 0
    reviewed: list[str] = []
    seen: set[uuid.UUID] = set()
    for node, entry in rows.all():
        if node.id in seen:
            continue
        seen.add(node.id)
        value = resolve_event_temporal(
            statement=statement_content(node),
            entry_at=entry.created_at,
            tz_name=timezone_name,
            event_time_text=node.temporal_source_text,
            event_status=node.event_status,
            claimed_precision=node.temporal_precision,
            claimed_confidence=node.temporal_confidence,
        )
        before = _snapshot(node)
        after = {
            "occurred_at": value.occurred_at.isoformat() if value.occurred_at else None,
            "event_start_at": value.start_at.isoformat() if value.start_at else None,
            "event_end_at": value.end_at.isoformat() if value.end_at else None,
            "temporal_precision": value.precision,
            "temporal_confidence": value.confidence,
            "temporal_source_text": value.source_text,
            "event_status": value.status,
        }
        if before == after:
            continue
        changed += 1
        if value.confidence < 0.8:
            reviewed.append(str(node.id))
        if dry_run:
            continue
        node.occurred_at = value.occurred_at
        node.recorded_at = entry.created_at
        node.event_start_at = value.start_at
        node.event_end_at = value.end_at
        node.temporal_precision = value.precision
        node.temporal_confidence = value.confidence
        node.temporal_source_text = value.source_text
        node.temporal_anchor_at = value.anchor_at
        node.event_status = value.status
        node.event_timezone = value.timezone
        session.add(TemporalBackfillAudit(
            user_id=user_id, node_id=node.id, before=before, after=after, run_key=run_key
        ))
    if not dry_run:
        await session.commit()
    return {"run_key": run_key, "scanned": len(seen), "changed": changed, "review_node_ids": reviewed}
