"""Celery application and graph processing tasks."""

from __future__ import annotations

import asyncio
import uuid

from celery import Celery

from ..config import get_settings

settings = get_settings()

celery_app = Celery(
    "graphrag",
    broker=settings.redis_url,
    backend=settings.redis_url,
)
celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
)


def _run_async(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


@celery_app.task(name="ingest_journal_graph", bind=True, max_retries=2)
def ingest_journal_graph_task(self, entry_id: str, user_id: str) -> dict:
    return _run_async(
        _ingest_journal_graph(uuid.UUID(entry_id), uuid.UUID(user_id))
    )


async def _ingest_journal_graph(entry_id: uuid.UUID, user_id: uuid.UUID) -> dict:
    from ..pipeline_runner import run_graph_ingest_pipeline

    try:
        summary = await run_graph_ingest_pipeline(entry_id, user_id)
        return {"status": "completed", "ingest_summary": summary}
    except Exception as exc:
        return {"status": "failed", "detail": str(exc)}


@celery_app.task(name="process_journal_entry", bind=True, max_retries=2)
def process_journal_entry_task(self, entry_id: str, user_id: str) -> dict:
    return _run_async(_process_journal_entry(uuid.UUID(entry_id), uuid.UUID(user_id)))


async def _process_journal_entry(entry_id: uuid.UUID, user_id: uuid.UUID) -> dict:
    """Legacy task name — delegates to semantic chunk ingest."""
    return await _ingest_journal_graph(entry_id, user_id)


def enqueue_graph_ingest(entry_id: uuid.UUID, user_id: uuid.UUID) -> str | None:
    if not settings.graph_processing_async:
        return None
    try:
        result = ingest_journal_graph_task.delay(str(entry_id), str(user_id))
        return result.id
    except Exception:
        return None


def enqueue_journal_processing(entry_id: uuid.UUID, user_id: uuid.UUID) -> str | None:
    return enqueue_graph_ingest(entry_id, user_id)
