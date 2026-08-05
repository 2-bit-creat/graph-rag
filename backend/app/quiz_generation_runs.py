"""Durable developer generation runs over Statement × target-language pairs."""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .db import async_session_factory
from .models import Node, Quiz, QuizGenerationRun, User
from .quiz_batch import _record_exploration
from .quiz_bundle import BundleSeedError
from .quiz_materials import generate_complete_learning_set

logger = logging.getLogger(__name__)
_RUN_STALE_AFTER = timedelta(minutes=15)


async def recover_stale_generation_runs(
    session: AsyncSession, user_id: uuid.UUID, *, now: datetime | None = None
) -> int:
    """Make interrupted in-process generation runs retryable again.

    Generation persists progress after every node/language pair.  If the worker
    or Lambda is terminated, only the pair in flight stays ``running``.  Once a
    run has made no progress for 15 minutes, mark unfinished pairs failed so the
    existing retry endpoint can create a clean, scoped retry.
    """
    now = now or datetime.now(UTC)
    cutoff = now - _RUN_STALE_AFTER
    runs = (
        await session.scalars(
            select(QuizGenerationRun).where(
                QuizGenerationRun.user_id == user_id,
                QuizGenerationRun.status.in_(("queued", "running")),
                QuizGenerationRun.updated_at < cutoff,
            )
        )
    ).all()
    for run in runs:
        items = [dict(item) for item in (run.items or [])]
        for item in items:
            if item.get("status") in {"queued", "running"}:
                item.update(status="failed", error="generation worker interrupted; retry this item")
        run.items = items
        run.completed_count = sum(item.get("status") == "completed" for item in items)
        run.failed_count = sum(item.get("status") == "failed" for item in items)
        run.status = "failed" if run.completed_count == 0 else "partial"
        run.finished_at = now
    if runs:
        await session.commit()
    return len(runs)


def run_dict(run: QuizGenerationRun) -> dict:
    return {
        "id": run.id,
        "source": run.source,
        "status": run.status,
        "node_ids": [uuid.UUID(value) for value in (run.node_ids or [])],
        "languages": list(run.languages or []),
        "items": list(run.items or []),
        "total_count": run.total_count,
        "completed_count": run.completed_count,
        "failed_count": run.failed_count,
        "created_at": run.created_at,
        "updated_at": run.updated_at,
        "finished_at": run.finished_at,
    }


async def create_generation_run(
    session: AsyncSession,
    user: User,
    *,
    node_ids: list[uuid.UUID],
    languages: list[str],
    idempotency_key: str,
    source: str = "manual",
) -> tuple[QuizGenerationRun, bool]:
    """Validate a request and persist its complete Cartesian product."""
    existing = await session.scalar(
        select(QuizGenerationRun).where(
            QuizGenerationRun.user_id == user.id,
            QuizGenerationRun.idempotency_key == idempotency_key,
        )
    )
    if existing is not None:
        return existing, False

    unique_node_ids = list(dict.fromkeys(node_ids))
    unique_languages = list(
        dict.fromkeys(lang.strip().lower() for lang in languages if lang.strip())
    )
    active_languages = {
        lang.lower() for lang in crud.get_effective_target_languages(user)
    }
    invalid_languages = set(unique_languages) - active_languages
    if invalid_languages:
        raise ValueError(
            f"비활성 Target 언어입니다: {', '.join(sorted(invalid_languages))}"
        )

    rows = (
        await session.scalars(
            select(Node).where(
                Node.id.in_(unique_node_ids),
                Node.user_id == user.id,
                Node.type == "Statement",
                Node.deleted_at.is_(None),
            )
        )
    ).all()
    nodes_by_id = {node.id: node for node in rows}
    missing = [node_id for node_id in unique_node_ids if node_id not in nodes_by_id]
    if missing:
        raise ValueError("선택한 노드 중 사용할 수 없는 Statement가 있습니다.")

    items = [
        {
            "node_id": str(node_id),
            "node_name": nodes_by_id[node_id].name or "",
            "language": language,
            "status": "queued",
            "generated_counts": {},
            "quiz_ids": [],
            "error": None,
        }
        for node_id in unique_node_ids
        for language in unique_languages
    ]
    run = QuizGenerationRun(
        user_id=user.id,
        idempotency_key=idempotency_key,
        source=source,
        node_ids=[str(node_id) for node_id in unique_node_ids],
        languages=unique_languages,
        items=items,
        total_count=len(items),
    )
    session.add(run)
    await session.commit()
    await session.refresh(run)
    return run, True


async def _archive_previous_pair(
    session: AsyncSession,
    user_id: uuid.UUID,
    node_id: uuid.UUID,
    language: str,
    *,
    keep_ids: set[uuid.UUID],
) -> None:
    quizzes = (
        await session.scalars(
            select(Quiz).where(
                Quiz.user_id == user_id,
                Quiz.language == language,
                Quiz.quiz_type.in_(("cloze", "composition")),
                Quiz.queue_kind != "archived",
                Quiz.source_nodes.any(node_id),
            )
        )
    ).all()
    for quiz in quizzes:
        if quiz.id in keep_ids:
            continue
        quiz.queue_kind = "archived"
        quiz.generation_key = None
        quiz.batch_id = None
    await session.commit()


def _expression_count(trace: dict) -> int:
    return next(
        (
            int(step.get("input", {}).get("expression_count") or 0)
            for step in (trace.get("steps") or [])
            if step.get("name") == "bundle_structural_validation"
        ),
        0,
    )


async def _persisted_pair_quiz_result(
    session: AsyncSession,
    *,
    user_id: uuid.UUID,
    node_id: uuid.UUID,
    language: str,
) -> tuple[dict[str, int], list[str]]:
    """Read the durable result rather than trusting an intermediate return list.

    A complete learning set commits several times (analysis, expressions, TTS).
    The generation-run history must therefore describe the quizzes that really
    survived for this node/language pair, not whichever subset one sub-step
    happened to return.
    """
    quizzes = (
        await session.scalars(
            select(Quiz)
            .where(
                Quiz.user_id == user_id,
                Quiz.language == language,
                Quiz.quiz_type.in_(("cloze", "composition")),
                Quiz.queue_kind != "archived",
                Quiz.source_nodes.any(node_id),
            )
            .order_by(Quiz.created_at, Quiz.id)
        )
    ).all()
    return (
        {
            "cloze": sum(quiz.quiz_type == "cloze" for quiz in quizzes),
            "composition": sum(quiz.quiz_type == "composition" for quiz in quizzes),
        },
        [str(quiz.id) for quiz in quizzes],
    )


async def process_generation_run(run_id: uuid.UUID) -> None:
    """Background entry point; commits each pair independently."""
    async with async_session_factory() as session:
        run = await session.get(QuizGenerationRun, run_id)
        if run is None or run.status not in {"queued", "running"}:
            return
        user = await session.get(User, run.user_id)
        if user is None:
            run.status = "failed"
            run.failed_count = run.total_count
            run.finished_at = datetime.now(UTC)
            await session.commit()
            return

        run.status = "running"
        await session.commit()

        for index, original in enumerate(list(run.items or [])):
            if original.get("status") == "completed":
                continue
            items = [dict(item) for item in (run.items or [])]
            item = items[index]
            item["status"] = "running"
            item["error"] = None
            run.items = items
            await session.commit()

            node_id = uuid.UUID(str(item["node_id"]))
            language = str(item["language"]).lower()
            try:
                material, created, _ = await generate_complete_learning_set(
                    session,
                    user,
                    node_id=node_id,
                    language=language,
                    priority=100 if run.source == "manual" else 0,
                    force_analysis=run.source == "manual",
                    limit=8,
                    direct_node=run.source == "manual",
                )
                for quiz in created:
                    quiz.source_kind = (
                        "auto_generation"
                        if run.source == "auto"
                        else "developer_generation"
                    )
                created_counts = {
                    "cloze": sum(quiz.quiz_type == "cloze" for quiz in created),
                    "composition": sum(
                        quiz.quiz_type == "composition" for quiz in created
                    ),
                }
                await _record_exploration(
                    session,
                    user.id,
                    str(node_id),
                    language,
                    created_counts["composition"],
                    created_counts["cloze"],
                    material.expression_count,
                    True,
                )
                await session.commit()
                # Persisted rows are authoritative. In particular, a run can
                # cross multiple commits while it creates composition and
                # expression cards, which previously left the history at 0/0.
                counts, quiz_ids = await _persisted_pair_quiz_result(
                    session,
                    user_id=user.id,
                    node_id=node_id,
                    language=language,
                )
                item.update(
                    status="completed",
                    generated_counts=counts,
                    quiz_ids=quiz_ids,
                    error=None,
                )
            except BundleSeedError as exc:
                item.update(status="failed", error=str(exc)[:500])
            except Exception as exc:  # noqa: BLE001 - one pair must not abort the run
                logger.exception(
                    "quiz generation run item failed run=%s node=%s lang=%s",
                    run.id,
                    node_id,
                    language,
                )
                item.update(status="failed", error=str(exc)[:500])
                await session.rollback()
                await session.refresh(run)
                await session.refresh(user)

            items = [dict(value) for value in (run.items or [])]
            items[index] = item
            run.items = items
            run.completed_count = sum(
                value.get("status") == "completed" for value in items
            )
            run.failed_count = sum(
                value.get("status") == "failed" for value in items
            )
            await session.commit()

        if run.failed_count == 0:
            run.status = "completed"
        elif run.completed_count == 0:
            run.status = "failed"
        else:
            run.status = "partial"
        run.finished_at = datetime.now(UTC)
        await session.commit()


async def list_generation_runs(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    limit: int = 20,
    offset: int = 0,
) -> tuple[list[QuizGenerationRun], int]:
    await recover_stale_generation_runs(session, user_id)
    total = int(
        (
            await session.execute(
                select(func.count())
                .select_from(QuizGenerationRun)
                .where(QuizGenerationRun.user_id == user_id)
            )
        ).scalar_one()
    )
    rows = (
        await session.scalars(
            select(QuizGenerationRun)
            .where(QuizGenerationRun.user_id == user_id)
            .order_by(QuizGenerationRun.created_at.desc())
            .offset(offset)
            .limit(limit)
        )
    ).all()
    return list(rows), total
