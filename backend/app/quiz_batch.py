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
from .quiz_materials import (
    activate_node_compositions,
    ensure_learning_material,
)
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
        cloze_target=0,
        scramble_target=user.daily_scramble_target if track == "daily" else 1,
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
            Quiz.queue_kind.in_(("new", "review")),
            Quiz.quiz_type.in_(("scramble", "composition")),
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
            Quiz.quiz_type.in_(("scramble", "composition")),
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
                Quiz.quiz_type.in_(("scramble", "composition")),
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
            Quiz.queue_kind.in_(("new", "review")),
            Quiz.quiz_type.in_(("scramble", "composition")),
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
                Quiz.quiz_type.in_(("scramble", "composition")),
            )
            .group_by(Quiz.quiz_type)
        )
        current = {str(kind): int(n) for kind, n in active_counts.all()}
        # Daily goals are inventory targets, not batch sizes.  The old policy
        # added an entire 2x buffer whenever the count crossed the threshold
        # (39 -> +40 for a target of 40), leaving large piles of never-opened
        # cards.  Refill only the actual deficit and wait until a low-water mark
        # is crossed so small fluctuations do not start model work.
        composition_target = max(0, user.daily_composition_target)
        scramble_target = max(0, user.daily_scramble_target)
        composition_low = min(composition_target, max(2, composition_target // 2))
        scramble_low = min(scramble_target, max(5, scramble_target // 2))
        composition_current = current.get("composition", 0)
        scramble_current = current.get("scramble", 0)
        composition_missing = (
            max(0, composition_target - composition_current)
            if composition_current <= composition_low
            else 0
        )
        scramble_missing = (
            max(0, scramble_target - scramble_current)
            if scramble_current <= scramble_low
            else 0
        )
        generated = {"scramble": 0, "composition": 0}
        if composition_missing == 0 and scramble_missing == 0:
            await session.commit()
            return {"status": "queue_ready", "scramble": 0, "composition": 0}
        # Older runs stored one global exhausted flag even when only one quiz
        # type had been exhausted.  That stale flag must not block refilling a
        # different type that is currently below its buffer.
        if (
            state.status == "exhausted"
            and (
                (scramble_missing > 0 and current.get("composition", 0) > 0)
                or (composition_missing > 0 and current.get("scramble", 0) > 0)
            )
        ):
            state.status = "available"
        if state.status == "exhausted":
            await session.commit()
            return {"status": "source_exhausted", "scramble": 0, "composition": 0}

        covered = await _covered_node_types(session, user.id, language)
        ranked_sources: list[tuple[int, str, dict]] = []
        for source in sources:
            source_id = str(source.get("node_id"))
            needs_scramble = scramble_missing > 0 and "scramble" not in covered.get(source_id, set())
            needs_composition = (
                composition_missing > 0
                and "composition" not in covered.get(source_id, set())
            )
            if not needs_composition and not needs_scramble:
                continue
            ranked_sources.append(
                (0, str(source.get("created_at") or ""), source)
            )
        # High-value expressions first, then recent memories.  This replaces
        # database return order, which was never a recommendation policy.
        ranked_sources.sort(key=lambda item: (item[0], item[1]), reverse=True)
        candidates = [item[2] for item in ranked_sources]
        if not candidates:
            state.status = "exhausted"
            state.source_count = len(sources)
            await session.commit()
            return {"status": "source_exhausted", "scramble": 0, "composition": 0}

        for source in candidates:
            if generated["scramble"] >= scramble_missing and generated["composition"] >= composition_missing:
                break
            source_id = str(source["node_id"])
            source_covered = covered.get(source_id, set())
            needs_composition = "composition" not in source_covered
            try:
                material, created_cards, trace = await ensure_learning_material(
                    session, user, node_id=uuid.UUID(source_id), language=language
                )
                activated_cards = await activate_node_compositions(
                    session, user, node_id=uuid.UUID(source_id), language=language, limit=1
                ) if (needs_composition or generated["scramble"] < scramble_missing) else []
                # activate_node_compositions always promotes a scramble/composition
                # pair together, but the two have independent daily deficits. A
                # member this pass doesn't need is put back to "inventory" (not
                # "archived") so a later pass — or a different day — can still
                # activate it instead of losing that unit's only paired scramble.
                scramble_count = 0
                for quiz in activated_cards:
                    if quiz.quiz_type != "scramble":
                        continue
                    if generated["scramble"] >= scramble_missing:
                        quiz.queue_kind = "inventory"
                        continue
                    generated["scramble"] += 1
                    scramble_count += 1
                    quiz.track = "daily"
                    quiz.source_kind = "learning_material"
                comp_count = 0
                for quiz in (quiz for quiz in activated_cards if quiz.quiz_type == "composition"):
                    if needs_composition and generated["composition"] < composition_missing:
                        generated["composition"] += 1
                        comp_count += 1
                        quiz.track = "daily"
                        quiz.source_kind = "learning_material"
                    else:
                        quiz.queue_kind = "inventory"
                expression_count = material.expression_count
            except BundleSeedError:
                continue
            await _record_exploration(
                session,
                user.id,
                str(source["node_id"]),
                language,
                comp_count,
                scramble_count,
                expression_count,
                False,
            )

        if generated["scramble"] == 0 and generated["composition"] == 0:
            state.status = "exhausted"

        await session.commit()
        return {
            "status": "ok" if any(generated.values()) else "source_exhausted",
            "scramble": generated["scramble"],
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


