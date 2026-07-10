"""Batch quiz refill — keeps per-type new queues near the configured target."""

from __future__ import annotations

import uuid

from .. import crud
from ..composition_quiz import generate_composition_quiz
from ..config import get_settings
from ..db import async_session_factory
from ..models import User
from ..quiz_pipeline import run_quiz_generate_pipeline
from ..quiz_queue import count_queues
from ..quiz_types import ENABLED_QUIZ_TYPES
from ..tutor import DrillSeedError


async def refill_user_quizzes(user_id: uuid.UUID) -> dict:
    """Top up new quiz queues for each enabled type, up to per-run cap."""
    settings = get_settings()
    if not settings.quiz_auto_enabled:
        return {"status": "skipped", "reason": "quiz_auto_enabled=False"}

    target = settings.quiz_queue_target_per_type
    max_per_run = settings.quiz_refill_max_per_run
    generated = 0
    by_type: dict[str, int] = {t: 0 for t in ENABLED_QUIZ_TYPES}
    skipped_types: list[str] = []

    async with async_session_factory() as session:
        user = await session.get(User, user_id)
        if user is None:
            return {"status": "error", "reason": "user not found"}

        counts = await count_queues(session, user_id)
        from ..crud import get_effective_target_languages

        target_langs = get_effective_target_languages(user)

        for quiz_type in sorted(ENABLED_QUIZ_TYPES):
            if generated >= max_per_run:
                break

            new_count = counts.get(quiz_type, {}).get("new", 0)
            deficit = max(0, target - new_count)
            if deficit <= 0:
                continue

            exclude_ids: set[str] | None = None
            if quiz_type == "composition":
                exclude_ids = await crud.get_recent_quiz_seed_node_ids(
                    session, user_id, quiz_type="composition", limit=20
                )

            for lang in target_langs:
                for _ in range(deficit):
                    if generated >= max_per_run:
                        break
                    try:
                        if quiz_type == "composition":
                            quiz, _ = await generate_composition_quiz(
                                session,
                                user,
                                language=lang.strip().lower(),
                                source_mode="journal",
                                exclude_node_ids=exclude_ids,
                            )
                            if exclude_ids is not None:
                                for nid in quiz.source_nodes or []:
                                    exclude_ids.add(str(nid))
                        else:
                            await run_quiz_generate_pipeline(
                                session,
                                user_id,
                                quiz_type,
                                target_language=lang,
                            )
                        generated += 1
                        by_type[quiz_type] += 1
                    except DrillSeedError:
                        skipped_types.append(quiz_type)
                        break

    return {
        "status": "ok",
        "generated": generated,
        "by_type": by_type,
        "skipped_types": skipped_types,
    }
