"""Background extraction queue: one job per node covers ALL pending languages.

One LLM call per node → all target languages extracted simultaneously.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass

logger = logging.getLogger(__name__)

_CONCURRENCY = 2


@dataclass
class ExtractionJob:
    user_id: uuid.UUID
    node_id: str
    languages: list[str]          # ALL pending languages for this node
    node_name: str
    content_ko: str
    translation_en: str = ""


_queue: asyncio.Queue[ExtractionJob | None] = asyncio.Queue()
_worker_tasks: list[asyncio.Task] = []


async def enqueue(
    user_id: uuid.UUID,
    node_id: str,
    language: str,
    *,
    node_name: str,
    content_ko: str = "",
    translation_en: str = "",
) -> None:
    """Add a single (node, language) extraction job."""
    from .node_expression_store import is_extracted

    if await is_extracted(user_id, node_id, language):
        return
    await _queue.put(ExtractionJob(
        user_id=user_id,
        node_id=node_id,
        languages=[language],
        node_name=node_name,
        content_ko=content_ko,
        translation_en=translation_en,
    ))


async def enqueue_bulk(
    user_id: uuid.UUID,
    node_info_list: list[dict],
    languages: list[str],
) -> int:
    """Enqueue pending (node × language) pairs, grouped per node for efficiency.

    node_info_list: [{node_id, node_name, content_ko, translation_en}]
    Returns number of jobs enqueued (one job = one node with ≥1 pending languages).
    """
    from .node_expression_store import get_pending_node_language_pairs

    if not node_info_list or not languages:
        return 0

    node_ids = [n["node_id"] for n in node_info_list]
    pending_pairs = await get_pending_node_language_pairs(user_id, node_ids, languages)

    # Group pending languages by node_id → one job per node
    node_langs: dict[str, list[str]] = {}
    for node_id, lang in pending_pairs:
        node_langs.setdefault(node_id, []).append(lang)

    node_map = {n["node_id"]: n for n in node_info_list}
    count = 0
    for node_id, langs in node_langs.items():
        info = node_map.get(node_id, {})
        await _queue.put(ExtractionJob(
            user_id=user_id,
            node_id=node_id,
            languages=langs,
            node_name=info.get("node_name", ""),
            content_ko=info.get("content_ko", ""),
            translation_en=info.get("translation_en", ""),
        ))
        count += 1

    if count:
        logger.info(
            "Enqueued %d node extraction jobs for user %s (%s)",
            count, user_id, languages,
        )
    return count


async def _process_one(job: ExtractionJob) -> None:
    from .node_expression_store import is_extracted, save_node_expressions
    from .statement_vocab_extractor import extract_multilang

    # Filter out already-done languages
    pending_langs = [
        lang for lang in job.languages
        if not await is_extracted(job.user_id, job.node_id, lang)
    ]
    if not pending_langs:
        return

    try:
        results = await extract_multilang(
            node_name=job.node_name,
            content_ko=job.content_ko,
            translation_en=job.translation_en,
            languages=pending_langs,
        )
        for lang, expressions in results.items():
            await save_node_expressions(job.user_id, job.node_id, lang, expressions, node_name=job.node_name)
            logger.info(
                "Saved %d %s expressions for node %s (user %s)",
                len(expressions), lang, job.node_id, job.user_id,
            )
        # Mark any language that returned nothing as done too (avoid infinite retry)
        for lang in pending_langs:
            if lang not in results:
                await save_node_expressions(job.user_id, job.node_id, lang, [])
    except Exception as exc:
        logger.warning("Extraction failed node=%s langs=%s: %s", job.node_id, pending_langs, exc)


async def _worker() -> None:
    while True:
        job = await _queue.get()
        if job is None:
            _queue.task_done()
            break
        try:
            await _process_one(job)
        finally:
            _queue.task_done()


def start_worker() -> None:
    global _worker_tasks
    for _ in range(_CONCURRENCY):
        task = asyncio.create_task(_worker())
        _worker_tasks.append(task)
    logger.info("Extraction queue started (%d workers)", _CONCURRENCY)


async def stop_worker() -> None:
    for _ in _worker_tasks:
        await _queue.put(None)
    await asyncio.gather(*_worker_tasks, return_exceptions=True)
    _worker_tasks.clear()


def queue_size() -> int:
    return _queue.qsize()
