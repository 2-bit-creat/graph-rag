"""One-off cleanup: archive queued cloze quizzes whose context_ko wraps the
entire Korean sentence with no target_ko to rebuild a partial highlight from
(see the >=80% target_ko/sentence_ko guard added to _normalize_bundle_cloze).
These are pre-fix rows the client can never render a useful hint for.

Run once: python -m scripts.archive_bad_context_ko_clozes
"""

from __future__ import annotations

import asyncio
import uuid

from sqlalchemy import or_, select

from app import crud
from app.db import async_session_factory
from app.models import Quiz


async def main() -> None:
    async with async_session_factory() as session:
        rows = (
            await session.execute(
                select(Quiz.id, Quiz.user_id).where(
                    Quiz.quiz_type == "cloze",
                    Quiz.queue_kind == "new",
                    or_(
                        Quiz.quiz_data["target_ko"].astext.is_(None),
                        Quiz.quiz_data["target_ko"].astext == "",
                    ),
                    Quiz.quiz_data["context_ko"].astext.like("<span%</span>"),
                )
            )
        ).all()
        print(f"Found {len(rows)} affected quiz(zes)")
        for quiz_id, user_id in rows:
            archived = await crud.archive_quiz(session, uuid.UUID(str(quiz_id)), uuid.UUID(str(user_id)))
            print(f"  archived {quiz_id}: {'ok' if archived else 'not found'}")


if __name__ == "__main__":
    asyncio.run(main())
