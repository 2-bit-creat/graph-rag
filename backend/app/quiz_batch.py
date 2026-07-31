"""Configuration-driven quiz batch filling.

Daily batches are immutable containers for the learning track: a batch id makes
a day's progress reproducible and keeps later refills from rewriting history.
"""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, date, datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .composition_quiz import generate_composition_quiz
from .models import Quiz, QuizBatch, QuizGenerationState, QuizSourceExploration, User
from .quiz_bundle import CLOZE_GENERATOR_VERSION, BundleSeedError
from .quiz_materials import ensure_learning_material, materialize_node_expressions
from .tutor import DrillSeedError

_LOCKS: dict[uuid.UUID, asyncio.Lock] = {}


def _lock_for(user_id: uuid.UUID) -> asyncio.Lock:
    return _LOCKS.setdefault(user_id, asyncio.Lock())


async def _get_or_create_batch(
    session: AsyncSession,
    user: User,
    *,
    language: str,
    track: str = "daily",
    sequence: int = 0,
) -> QuizBatch:
    today = date.today()
    result = await session.execute(
        select(QuizBatch).where(
            QuizBatch.user_id == user.id,
            QuizBatch.batch_date == today,
            QuizBatch.track == track,
            QuizBatch.language == language,
            QuizBatch.sequence == sequence,
        )
    )
    batch = result.scalar_one_or_none()
    if batch is not None:
        return batch
    batch = QuizBatch(
        user_id=user.id,
        batch_date=today,
        track=track,
        language=language,
        sequence=sequence,
        cloze_target=user.daily_cloze_target if track == "daily" else 1,
        composition_target=user.daily_composition_target if track == "daily" else 1,
        review_ratio=user.quiz_review_ratio,
    )
    session.add(batch)
    await session.flush()
    return batch


async def _counts(session: AsyncSession, batch_id: uuid.UUID) -> dict[str, int]:
    result = await session.execute(
        select(Quiz.quiz_type, func.count())
        .where(
            Quiz.batch_id == batch_id,
            Quiz.queue_kind != "archived",
            Quiz.quiz_type.in_(("cloze", "composition")),
        )
        .group_by(Quiz.quiz_type)
    )
    return {str(kind): int(n) for kind, n in result.all()}


async def _stamp(session: AsyncSession, quiz: Quiz, batch: QuizBatch, source_kind: str) -> None:
    quiz.batch_id = batch.id
    quiz.track = batch.track
    quiz.source_kind = source_kind
    data = dict(quiz.quiz_data or {})
    data["_batch"] = {
        "id": str(batch.id),
        "track": batch.track,
        "date": batch.batch_date.isoformat(),
        "sequence": batch.sequence,
    }
    quiz.quiz_data = data
    await session.flush()


async def _failed_seed_ids(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    result = await session.execute(
        select(Quiz.source_nodes)
        .where(
            Quiz.user_id == user_id,
            Quiz.quiz_type.in_(("cloze", "composition")),
            Quiz.times_wrong > 0,
            Quiz.next_review_at.is_not(None),
            Quiz.next_review_at <= datetime.now(UTC),
        )
        .order_by(Quiz.next_review_at.asc())
        .limit(50)
    )
    ids: list[uuid.UUID] = []
    for nodes, in result.all():
        for node_id in nodes or []:
            if node_id not in ids:
                ids.append(node_id)
    return ids


async def _source_state(
    session: AsyncSession, user: User, language: str, sources: list[dict]
) -> QuizGenerationState:
    """Return the cached source state, invalidating exhaustion when the graph grows."""
    result = await session.execute(
        select(QuizGenerationState).where(
            QuizGenerationState.user_id == user.id,
            QuizGenerationState.language == language,
        )
    )
    state = result.scalar_one_or_none()
    latest = max(
        (str(s.get("created_at") or "") for s in sources),
        default=None,
    )
    if state is None:
        state = QuizGenerationState(
            user_id=user.id,
            language=language,
            source_count=len(sources),
            latest_source_at=datetime.fromisoformat(latest) if latest else None,
        )
        session.add(state)
        await session.flush()
    elif state.status == "exhausted" and (
        state.source_count != len(sources)
        or (state.latest_source_at and latest and state.latest_source_at.isoformat() != latest)
    ):
        state.status = "available"
        state.source_count = len(sources)
        state.latest_source_at = datetime.fromisoformat(latest) if latest else None
    if state.status == "exhausted":
        # A generator-contract upgrade invalidates prior "unavailable" results.
        # Without reopening this language-level circuit breaker, the newer
        # per-node version check below is never reached.
        stale_contract = await session.execute(
            select(func.count()).select_from(QuizSourceExploration).where(
                QuizSourceExploration.user_id == user.id,
                QuizSourceExploration.language == language,
                QuizSourceExploration.cloze_generator_version.is_not(None),
                QuizSourceExploration.cloze_generator_version != CLOZE_GENERATOR_VERSION,
            )
        )
        if int(stale_contract.scalar_one()) > 0:
            state.status = "available"
    if state.status == "exhausted":
        # A full administrative clear is also a legitimate request to rebuild
        # from the existing graph, even if the clear happened before this
        # generation-state implementation was deployed.
        active = await session.execute(
            select(func.count()).select_from(Quiz).where(
                Quiz.user_id == user.id,
                Quiz.language == language,
                Quiz.track == "daily",
                Quiz.queue_kind != "archived",
                Quiz.quiz_type.in_(("cloze", "composition")),
            )
        )
        if int(active.scalar_one()) == 0:
            state.status = "available"
    return state


async def _covered_node_types(
    session: AsyncSession, user_id: uuid.UUID, language: str
) -> dict[str, set[str]]:
    """Return quiz types that still exist for each Statement source.

    Archived/deleted quizzes are intentionally excluded: an administrator
    deleting a quiz must make that source eligible for regeneration.
    """
    result = await session.execute(
        select(Quiz.source_nodes, Quiz.quiz_type).where(
            Quiz.user_id == user_id,
            Quiz.language == language,
            Quiz.track == "daily",
            Quiz.queue_kind != "archived",
            Quiz.quiz_type.in_(("cloze", "composition")),
        )
    )
    covered: dict[str, set[str]] = {}
    for source_nodes, quiz_type in result.all():
        for node_id in source_nodes or []:
            covered.setdefault(str(node_id), set()).add(str(quiz_type))
    return covered


async def _record_exploration(
    session: AsyncSession,
    user_id: uuid.UUID,
    node_id: str,
    language: str,
    composition_count: int,
    word_count: int,
    expression_count: int,
    cloze_attempted: bool,
) -> None:
    result = await session.execute(
        select(QuizSourceExploration).where(
            QuizSourceExploration.user_id == user_id,
            QuizSourceExploration.node_id == uuid.UUID(str(node_id)),
            QuizSourceExploration.language == language,
        )
    )
    row = result.scalar_one_or_none()
    if row is None:
        row = QuizSourceExploration(
            user_id=user_id,
            node_id=uuid.UUID(str(node_id)),
            language=language,
        )
        session.add(row)
    row.status = "completed"
    row.composition_count = composition_count
    row.expression_count = expression_count
    if cloze_attempted:
        row.word_count = word_count
        row.cloze_status = "generated" if word_count else "no_new_quiz"
        row.cloze_generator_version = CLOZE_GENERATOR_VERSION
    await session.flush()


async def fill_daily_batch(
    session: AsyncSession,
    user: User,
    *,
    language: str,
    sequence: int = 0,
) -> dict[str, int | str]:
    """Top up the active queue from each Statement at most once per language."""
    async with _lock_for(user.id):
        sources = [
            s for s in await crud.get_all_statement_nodes(session, user.id)
            if len((s.get("content_ko") or "").strip()) >= 6
        ]
        state = await _source_state(session, user, language, sources)
        active_counts = await session.execute(
            select(Quiz.quiz_type, func.count())
            .where(
                Quiz.user_id == user.id,
                Quiz.language == language,
                Quiz.queue_kind == "new",
                Quiz.repetitions == 0,
                Quiz.quiz_type.in_(("cloze", "composition")),
            )
            .group_by(Quiz.quiz_type)
        )
        current = {str(kind): int(n) for kind, n in active_counts.all()}
        composition_buffer = max(0, user.daily_composition_target * 2)
        cloze_buffer = max(0, user.daily_cloze_target * 2)
        # Refill in stable chunks: when the buffer is crossed, add one full
        # buffer-sized chunk instead of topping up by one item. This keeps the
        # queue around 10/40 for the default 5/20 daily goals.
        composition_missing = (
            composition_buffer if current.get("composition", 0) < composition_buffer else 0
        )
        cloze_missing = cloze_buffer if current.get("cloze", 0) < cloze_buffer else 0
        generated = {"cloze": 0, "composition": 0}
        if composition_missing == 0 and cloze_missing == 0:
            await session.commit()
            return {"status": "queue_ready", "cloze": 0, "composition": 0}
        # Older runs stored one global exhausted flag even when only one quiz
        # type had been exhausted.  That stale flag must not block refilling a
        # different type that is currently below its buffer.
        if (
            state.status == "exhausted"
            and (
                (cloze_missing > 0 and current.get("composition", 0) > 0)
                or (composition_missing > 0 and current.get("cloze", 0) > 0)
            )
        ):
            state.status = "available"
        if state.status == "exhausted":
            await session.commit()
            return {"status": "source_exhausted", "cloze": 0, "composition": 0}

        covered = await _covered_node_types(session, user.id, language)
        candidates = [
            s for s in sources
            if (
                (composition_missing > 0 and "composition" not in covered.get(str(s.get("node_id")), set()))
                or (
                    cloze_missing > 0
                    and "cloze" not in covered.get(str(s.get("node_id")), set())
                )
            )
        ]
        if not candidates:
            state.status = "exhausted"
            state.source_count = len(sources)
            await session.commit()
            return {"status": "source_exhausted", "cloze": 0, "composition": 0}

        for source in candidates:
            if generated["cloze"] >= cloze_missing and generated["composition"] >= composition_missing:
                break
            source_id = str(source["node_id"])
            source_covered = covered.get(source_id, set())
            needs_composition = "composition" not in source_covered
            needs_cloze = "cloze" not in source_covered
            cloze_attempted = needs_cloze and generated["cloze"] < cloze_missing
            try:
                material, composition_cards, trace = await ensure_learning_material(
                    session, user, node_id=uuid.UUID(source_id), language=language
                )
                comp_count = 0
                for quiz in composition_cards:
                    if needs_composition and generated["composition"] < composition_missing:
                        generated["composition"] += 1
                        comp_count += 1
                        quiz.track = "daily"
                        quiz.source_kind = "learning_material"
                    else:
                        quiz.queue_kind = "archived"
                word_count = 0
                if cloze_attempted:
                    clozes, _ = await materialize_node_expressions(
                        session,
                        user,
                        node_id=uuid.UUID(source_id),
                        language=language,
                        limit=min(8, max(1, cloze_missing - generated["cloze"])),
                        queue_missing=max(0, cloze_missing - generated["cloze"]),
                    )
                    for quiz in clozes:
                        if generated["cloze"] >= cloze_missing:
                            quiz.queue_kind = "archived"
                            continue
                        generated["cloze"] += 1
                        word_count += 1
                        quiz.track = "daily"
                        quiz.source_kind = "expression_inventory"
                expression_count = material.expression_count
                valid_cloze_count = word_count
            except BundleSeedError:
                continue
            await _record_exploration(
                session,
                user.id,
                str(source["node_id"]),
                language,
                comp_count,
                valid_cloze_count,
                expression_count,
                cloze_attempted,
            )

        if generated["cloze"] == 0 and generated["composition"] == 0:
            state.status = "exhausted"

        await session.commit()
        return {
            "status": "ok" if any(generated.values()) else "source_exhausted",
            "cloze": generated["cloze"],
            "composition": generated["composition"],
        }


async def fill_user_daily_batches(session: AsyncSession, user: User) -> dict:
    result: dict[str, dict] = {}
    for language in crud.get_effective_target_languages(user):
        result[language] = await fill_daily_batch(session, user, language=language)
    return result


async def create_extra_daily_batch(
    session: AsyncSession, user: User, *, language: str
) -> dict:
    result = await session.execute(
        select(func.max(QuizBatch.sequence)).where(
            QuizBatch.user_id == user.id,
            QuizBatch.batch_date == date.today(),
            QuizBatch.track == "daily",
            QuizBatch.language == language,
        )
    )
    sequence = int(result.scalar() or 0) + 1
    return await fill_daily_batch(session, user, language=language, sequence=sequence)


