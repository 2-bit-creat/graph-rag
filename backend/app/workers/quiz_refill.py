"""Background quiz refill — keep every (language × type) queue topped up.

One "bundle" is a single LLM call that yields all four quiz types for one
Statement (see :mod:`app.quiz_bundle`). Refill counts the ``new`` backlog per
active target language and generates bundles until each language's queues reach
``quiz_queue_target_per_type`` or the per-run bundle cap is hit.
"""

from __future__ import annotations

import logging
import uuid

from ..config import get_settings
from ..db import async_session_factory
from ..models import User
from .. import crud
from ..quiz_bundle import BundleSeedError, generate_quiz_bundle

logger = logging.getLogger(__name__)

# Users with a refill already running — prevents a background-commit trigger and
# a queue-empty trigger from generating duplicate bundles at the same time.
_IN_FLIGHT: set[uuid.UUID] = set()


async def _min_new_count(session, user_id: uuid.UUID, language: str) -> int:
    """Smallest ``new`` backlog across the four quiz types for one language.

    A language needs a bundle when ANY of its type queues is short, and a bundle
    fills all four at once, so the minimum drives the decision.
    """
    from sqlalchemy import func, select
    from ..models import Quiz

    counts: dict[str, int] = {t: 0 for t in ("cloze", "scramble", "mcq_nuance", "composition")}
    rows = await session.execute(
        select(Quiz.quiz_type, func.count())
        .where(
            Quiz.user_id == user_id,
            Quiz.language == language,
            Quiz.queue_kind == "new",
            Quiz.repetitions == 0,
        )
        .group_by(Quiz.quiz_type)
    )
    for qtype, n in rows.all():
        if qtype in counts:
            counts[qtype] = int(n)
    return min(counts.values())


async def refill_user_quizzes(user_id: uuid.UUID) -> dict:
    """Top up quiz queues for all of a user's active target languages."""
    settings = get_settings()
    if not settings.quiz_auto_enabled:
        return {"status": "skipped", "reason": "quiz_auto_enabled=False"}
    if user_id in _IN_FLIGHT:
        return {"status": "skipped", "reason": "already running"}

    _IN_FLIGHT.add(user_id)
    generated: dict[str, int] = {}
    try:
        async with async_session_factory() as session:
            user = await session.get(User, user_id)
            if user is None:
                return {"status": "skipped", "reason": "user not found"}

            languages = crud.get_effective_target_languages(user)
            budget = settings.quiz_refill_max_bundles_per_run
            target = settings.quiz_queue_target_per_type

            for language in languages:
                if budget <= 0:
                    break
                used_nodes: set[str] = await crud.get_recent_quiz_seed_node_ids(
                    session, user_id, quiz_type="composition", limit=40
                )
                lang_count = 0
                while budget > 0:
                    if await _min_new_count(session, user_id, language) >= target:
                        break
                    try:
                        created, _ = await generate_quiz_bundle(
                            session, user, language=language, exclude_node_ids=used_nodes,
                        )
                    except BundleSeedError:
                        break  # no statements for this user yet
                    except Exception:  # noqa: BLE001 — never let refill crash a request
                        logger.exception("quiz refill bundle failed (lang=%s)", language)
                        break
                    if not created:
                        break
                    for q in created:
                        for nid in q.source_nodes or []:
                            used_nodes.add(str(nid))
                    budget -= 1
                    lang_count += 1
                if lang_count:
                    generated[language] = lang_count
    finally:
        _IN_FLIGHT.discard(user_id)

    return {"status": "ok", "bundles_generated": generated}
