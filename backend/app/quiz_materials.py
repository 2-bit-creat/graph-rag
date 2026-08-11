"""Inventory-first learning material lifecycle.

This module is the common entry point used by graph interactions, developer
generation runs and automatic queue refills.  Keeping it here prevents those
three paths from silently using different extraction rules.
"""

from __future__ import annotations

import hashlib
import logging
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .db import async_session_factory
from .models import Node, Quiz, QuizLearningMaterial, QuizSourceExploration, User
from .quiz_bundle import BundleSeedError, generate_quiz_bundle, materialize_expression_clozes
from .quiz_policies import (
    GENERATION_POLICY_VERSION,
    generation_reason,
    record_policy_decision,
)

logger = logging.getLogger(__name__)


def source_hash(text: str) -> str:
    return hashlib.sha256(" ".join((text or "").split()).encode("utf-8")).hexdigest()


async def _node(session: AsyncSession, user_id: uuid.UUID, node_id: uuid.UUID) -> Node | None:
    return await session.scalar(
        select(Node).where(
            Node.id == node_id,
            Node.user_id == user_id,
            Node.type == "Statement",
            Node.deleted_at.is_(None),
        )
    )


async def statement_fingerprint(
    session: AsyncSession, user: User, node_id: uuid.UUID
) -> str:
    """Hash of a Statement's current content — the identity its material tracks."""
    node = await _node(session, user.id, node_id)
    if node is None:
        raise BundleSeedError("Statement node not found")
    source = next(
        (item for item in await crud.get_all_statement_nodes(session, user.id) if str(item.get("node_id")) == str(node_id)),
        None,
    )
    content = str((source or {}).get("content_ko") or "").strip()
    if len(content) < 6:
        raise BundleSeedError("Statement is too short to analyse")
    return source_hash(content)


async def _supersede_material(
    session: AsyncSession,
    user: User,
    row: QuizLearningMaterial,
    *,
    node_id: uuid.UUID,
    language: str,
    fingerprint: str,
    priority: int = 0,
) -> int:
    """Archive everything generated from an older version of this Statement.

    The old cards and expressions describe content that no longer exists.  Quiz
    rows are retained as archived history, but their learning targets must never
    be mixed into the replacement analysis.  Returns the archived quiz count.
    """
    stale_quizzes = (
        await session.scalars(
            select(Quiz).where(
                Quiz.user_id == user.id,
                Quiz.language == language,
                Quiz.quiz_type.in_(("cloze", "composition")),
                Quiz.queue_kind != "archived",
                Quiz.source_nodes.any(node_id),
            )
        )
    ).all()
    for quiz in stale_quizzes:
        quiz.queue_kind = "archived"
        quiz.generation_key = None
        quiz.batch_id = None
    from .node_expression_store import delete_node_language_expressions

    await delete_node_language_expressions(user.id, str(node_id), language)
    row.source_hash = fingerprint
    # ``stale`` is the "edited, archived, awaiting an explicit rebuild" state the
    # graph surface turns into an enabled 재생성 button.
    row.status = "stale"
    row.priority = max(row.priority, priority)
    row.composition_count = 0
    row.expression_count = 0
    row.expansion_count = 0
    row.result = None
    row.error = None
    await session.execute(
        update(QuizSourceExploration)
        .where(
            QuizSourceExploration.user_id == user.id,
            QuizSourceExploration.node_id == node_id,
            QuizSourceExploration.language == language,
        )
        .values(
            status="unexplored",
            composition_count=0,
            word_count=0,
            expression_count=0,
            cloze_status="available",
            cloze_generator_version=None,
        )
    )
    return len(stale_quizzes)


async def archive_edited_statement_materials(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    languages: list[str] | None = None,
) -> dict:
    """Retire a Statement's learning material right after its content changed.

    Editing the source invalidates every quiz and expression derived from it, so
    they are archived immediately instead of lingering until someone happens to
    request a regeneration.  Rebuilding is a separate, explicit action.
    """
    fingerprint = await statement_fingerprint(session, user, node_id)
    targets = [
        str(language).lower()
        for language in (languages or crud.get_effective_target_languages(user))
    ]
    rows = (
        await session.scalars(
            select(QuizLearningMaterial).where(
                QuizLearningMaterial.user_id == user.id,
                QuizLearningMaterial.node_id == node_id,
                QuizLearningMaterial.language.in_(targets),
            )
        )
    ).all()
    archived = 0
    stale_languages: list[str] = []
    for row in rows:
        if row.source_hash == fingerprint:
            continue
        archived += await _supersede_material(
            session,
            user,
            row,
            node_id=node_id,
            language=row.language,
            fingerprint=fingerprint,
        )
        stale_languages.append(row.language)
    if stale_languages:
        await session.commit()
    return {"archived_quiz_count": archived, "languages": stale_languages}


async def retire_statement_derivatives(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    languages: list[str] | None = None,
) -> dict:
    """Retire derived learning data even when the edited node is no longer valid.

    A Statement can be shortened below the analysis threshold or changed to a
    different node type.  In both cases the previous answers are still wrong,
    so cleanup must not depend on being able to fingerprint the new Statement.
    """
    node = await session.get(Node, node_id)
    if node is None or node.user_id != user.id:
        raise BundleSeedError("Node not found")
    targets = [
        str(language).lower()
        for language in (languages or crud.get_effective_target_languages(user))
    ]
    fingerprint = source_hash(
        f"retired|{node.type}|{node.name}|{node.description or ''}"
    )
    rows = (
        await session.scalars(
            select(QuizLearningMaterial).where(
                QuizLearningMaterial.user_id == user.id,
                QuizLearningMaterial.node_id == node_id,
                QuizLearningMaterial.language.in_(targets),
            )
        )
    ).all()
    archived = 0
    seen_languages: set[str] = set()
    for row in rows:
        archived += await _supersede_material(
            session,
            user,
            row,
            node_id=node_id,
            language=row.language,
            fingerprint=fingerprint,
            priority=100,
        )
        seen_languages.add(row.language)

    # Defensive cleanup for inventories created before material rows became the
    # lifecycle owner.
    from .node_expression_store import delete_node_language_expressions

    for language in targets:
        if language not in seen_languages:
            await delete_node_language_expressions(user.id, str(node_id), language)
    await session.commit()
    return {"archived_quiz_count": archived, "languages": targets}


async def reset_node_materials(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    languages: list[str] | None = None,
) -> dict:
    """Wipe every quiz + expression a Statement produced, for an explicit re-run.

    Unlike :func:`archive_edited_statement_materials`, this always resets —
    it does not check whether the source content changed. It is the
    user-triggered "start over on this node" action: same statement, clean
    slate, so the next manual generation re-extracts from scratch instead of
    piling more near-duplicate expressions onto the existing wordbook.
    """
    node = await _node(session, user.id, node_id)
    if node is None:
        raise BundleSeedError("Statement node not found")
    fingerprint = await statement_fingerprint(session, user, node_id)
    targets = [
        str(language).lower()
        for language in (languages or crud.get_effective_target_languages(user))
    ]
    rows = {
        row.language: row
        for row in (
            await session.scalars(
                select(QuizLearningMaterial).where(
                    QuizLearningMaterial.user_id == user.id,
                    QuizLearningMaterial.node_id == node_id,
                    QuizLearningMaterial.language.in_(targets),
                )
            )
        ).all()
    }
    archived = 0
    for language in targets:
        row = rows.get(language)
        if row is not None:
            archived += await _supersede_material(
                session, user, row, node_id=node_id, language=language, fingerprint=fingerprint,
            )
            row.status = "pending"
            continue
        # No material row yet (e.g. quizzes came from an older generation path) —
        # archive whatever quizzes/expressions exist directly.
        stale_quizzes = (
            await session.scalars(
                select(Quiz).where(
                    Quiz.user_id == user.id,
                    Quiz.language == language,
                    Quiz.quiz_type.in_(("cloze", "composition")),
                    Quiz.queue_kind != "archived",
                    Quiz.source_nodes.any(node_id),
                )
            )
        ).all()
        for quiz in stale_quizzes:
            quiz.queue_kind = "archived"
            quiz.generation_key = None
            quiz.batch_id = None
        archived += len(stale_quizzes)
        from .node_expression_store import delete_node_language_expressions

        await delete_node_language_expressions(user.id, str(node_id), language)
    await session.commit()
    return {"archived_quiz_count": archived, "languages": targets}


async def get_or_mark_material(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    language: str,
    priority: int = 0,
) -> QuizLearningMaterial:
    fingerprint = await statement_fingerprint(session, user, node_id)
    language = language.lower()
    row = await session.scalar(
        select(QuizLearningMaterial).where(
            QuizLearningMaterial.user_id == user.id,
            QuizLearningMaterial.node_id == node_id,
            QuizLearningMaterial.language == language,
        )
    )
    if row is None:
        row = QuizLearningMaterial(
            user_id=user.id,
            node_id=node_id,
            language=language,
            source_hash=fingerprint,
            status="pending",
            priority=priority,
        )
        session.add(row)
        await session.flush()
    elif row.source_hash != fingerprint:
        await _supersede_material(
            session,
            user,
            row,
            node_id=node_id,
            language=language,
            fingerprint=fingerprint,
            priority=priority,
        )
    elif priority > row.priority:
        row.priority = priority
    return row


async def ensure_learning_material(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    language: str,
    priority: int = 0,
    force: bool = False,
) -> tuple[QuizLearningMaterial, list[Quiz], dict]:
    """Analyse one node once and prepare its composition cards immediately."""
    row = await get_or_mark_material(
        session, user, node_id=node_id, language=language, priority=priority
    )
    if row.status == "ready" and not force:
        return row, [], row.result or {}
    row.status = "analyzing"
    row.error = None
    await session.commit()
    try:
        created, trace = await generate_quiz_bundle(
            session,
            user,
            language=language,
            seed_node_ids={str(node_id)},
            generation_version=row.source_hash,
            materialize_cloze=False,
        )
        composition = [quiz for quiz in created if quiz.quiz_type == "composition"]
        # The analysis pass needs composition references to judge expressions,
        # but those cards are not automatically part of the learner's active
        # queue.  Keep them as cheap text inventory until refill or an explicit
        # node study action promotes them.  No TTS is generated on this path.
        for quiz in composition:
            quiz.queue_kind = "inventory"
        expression_count = next(
            (
                int(step.get("input", {}).get("expression_count") or 0)
                for step in (trace.get("steps") or [])
                if step.get("name") == "bundle_structural_validation"
            ),
            0,
        )
        # A new source version supersedes old composition cards only after the
        # replacement has been created successfully.
        if composition:
            old = (
                await session.scalars(
                    select(Quiz).where(
                        Quiz.user_id == user.id,
                        Quiz.language == language,
                        Quiz.quiz_type == "composition",
                        Quiz.queue_kind != "archived",
                        Quiz.source_nodes.any(node_id),
                        Quiz.id.not_in([quiz.id for quiz in composition]),
                    )
                )
            ).all()
            for quiz in old:
                quiz.queue_kind = "archived"
        row.status = "ready"
        row.composition_count = len(composition)
        row.expression_count = expression_count
        row.result = {"trace": trace, "ready_at": datetime.now(UTC).isoformat()}
        row.error = None
        await record_policy_decision(
            session,
            user_id=user.id,
            policy="generation",
            policy_version=GENERATION_POLICY_VERSION,
            entity_type="learning_material",
            entity_id=row.id,
            reason="진술 노드 분석 완료: 작문 단위와 표현 인벤토리를 준비",
            details={"node_id": str(node_id), "language": language, "composition_count": len(composition), "expression_count": expression_count},
        )
        await session.commit()
        return row, composition, trace
    except Exception as exc:
        await session.rollback()
        row = await session.get(QuizLearningMaterial, row.id)
        if row is not None:
            row.status = "failed"
            row.error = str(exc)[:1000]
            await session.commit()
        raise


async def activate_node_compositions(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    language: str,
    limit: int = 1,
) -> list[Quiz]:
    """Promote analysed composition inventory into the learner's new queue."""
    if limit <= 0:
        return []
    quizzes = (
        await session.scalars(
            select(Quiz)
            .where(
                Quiz.user_id == user.id,
                Quiz.language == language.lower(),
                Quiz.quiz_type == "composition",
                Quiz.queue_kind == "inventory",
                Quiz.source_nodes.any(node_id),
            )
            .order_by(Quiz.created_at, Quiz.id)
            .limit(limit)
        )
    ).all()
    for quiz in quizzes:
        quiz.queue_kind = "new"
    if quizzes:
        await session.flush()
    return quizzes


async def materialize_node_expressions(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    language: str,
    limit: int = 8,
    expressions: list[dict[str, Any]] | None = None,
    direct_node: bool = False,
    queue_missing: int = 0,
) -> tuple[list[Quiz], dict]:
    row, _, _ = await ensure_learning_material(
        session, user, node_id=node_id, language=language, priority=100 if direct_node else 0
    )
    if row.status != "ready":
        return [], {"status": row.status}
    created, trace = await materialize_expression_clozes(
        session, user, node_id=str(node_id), language=language, expressions=expressions, limit=limit
    )
    if created:
        reason, details = generation_reason(
            direct_node=direct_node,
            queue_missing=queue_missing,
            expression=(expressions or [{}])[0],
        )
        await record_policy_decision(
            session,
            user_id=user.id,
            policy="generation",
            policy_version=GENERATION_POLICY_VERSION,
            entity_type="quiz_materialization",
            entity_id=node_id,
            reason=reason,
            details={**details, "language": language, "created_count": len(created)},
        )
        await session.commit()
    return created, trace


async def generate_complete_learning_set(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    language: str,
    priority: int = 0,
    force_analysis: bool = False,
    direct_node: bool = False,
    limit: int = 8,
) -> tuple[QuizLearningMaterial, list[Quiz], dict]:
    """Complete one visible exploration for one Statement × language pair.

    Analysis may use multiple model calls for quality, but callers get one
    operation that finishes composition creation, expression extraction and
    expression-based cloze creation.
    """
    row, _, trace = await ensure_learning_material(
        session,
        user,
        node_id=node_id,
        language=language,
        priority=priority,
        force=force_analysis,
    )
    composition = await activate_node_compositions(
        session,
        user,
        node_id=node_id,
        language=language,
        limit=1,
    )
    clozes, cloze_trace = await materialize_node_expressions(
        session,
        user,
        node_id=node_id,
        language=language,
        limit=limit,
        direct_node=direct_node,
        queue_missing=limit,
    )
    return row, composition + clozes, {
        "analysis": trace,
        "materialization": cloze_trace,
    }


async def analyse_material_background(
    user_id: uuid.UUID,
    node_id: uuid.UUID,
    languages: list[str],
    *,
    priority: int = 0,
) -> None:
    """Background-safe bridge used by graph routes without holding their DB session."""
    async with async_session_factory() as session:
        user = await session.get(User, user_id)
        if user is None:
            return
        for language in dict.fromkeys(value.lower() for value in languages if value):
            try:
                await ensure_learning_material(
                    session, user, node_id=node_id, language=language, priority=priority
                )
            except Exception:  # one language should not block other languages
                logger.exception("learning material analysis failed user=%s node=%s lang=%s", user_id, node_id, language)


async def analyse_nodes_and_refill_background(
    user_id: uuid.UUID,
    node_ids: list[uuid.UUID],
    languages: list[str],
    *,
    priority: int = 0,
) -> None:
    """Analyse confirmed Statements once, then top up the shared quiz queue.

    Analysis and card inventory are deliberately separate.  A journal may add
    many Statements at once; extracting every useful expression is cheap future
    curriculum work, while materialising every expression immediately would
    create a large queue the learner may never open.  One refill after the whole
    group also avoids each Statement starting a competing background refill.
    """
    unique_nodes = list(dict.fromkeys(node_ids))
    unique_languages = list(
        dict.fromkeys(value.lower() for value in languages if value)
    )
    async with async_session_factory() as session:
        user = await session.get(User, user_id)
        if user is None:
            return
        for node_id in unique_nodes:
            for language in unique_languages:
                try:
                    await ensure_learning_material(
                        session,
                        user,
                        node_id=node_id,
                        language=language,
                        priority=priority,
                    )
                except Exception:
                    logger.exception(
                        "learning material analysis failed user=%s node=%s lang=%s",
                        user_id,
                        node_id,
                        language,
                    )

    # The refill worker owns its own session and an in-flight guard. Running it
    # after analysis means it can choose across all newly discovered expressions
    # instead of over-producing from whichever Statement happened to finish first.
    from .workers.quiz_refill import refill_user_quizzes

    await refill_user_quizzes(user_id)
