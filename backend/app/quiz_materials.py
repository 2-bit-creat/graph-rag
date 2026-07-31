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


async def get_or_mark_material(
    session: AsyncSession,
    user: User,
    *,
    node_id: uuid.UUID,
    language: str,
    priority: int = 0,
) -> QuizLearningMaterial:
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
    language = language.lower()
    fingerprint = source_hash(content)
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
        # The old cards and expressions describe content that no longer exists.
        # Retain quiz rows as archived history, but never mix their learning
        # targets into the replacement analysis.
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
    row, composition, trace = await ensure_learning_material(
        session,
        user,
        node_id=node_id,
        language=language,
        priority=priority,
        force=force_analysis,
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
