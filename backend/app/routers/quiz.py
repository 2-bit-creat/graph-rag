"""Gamified quiz API — manual generation, sessions, profile."""

from __future__ import annotations

import uuid
import re
from typing import Literal

from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..composition_quiz import (
    generate_composition_quiz,
    merge_composition_feedback,
    verdict_to_sm2,
)
from ..config import get_settings
from ..db import async_session_factory, get_session
from ..deps import daily_quota, request_user_dep, require_debug_enabled, require_operator_tools
from ..rate_limit import KIND_QUIZ_GEN, remaining as rate_limit_remaining
from ..languages import DEFAULT_NATIVE, SUPPORTED_NATIVE, valid_target_for_native
from ..level_adjuster import reclassify_queue_by_level
from ..level_guidelines import cefr_label, window_for_level
from ..models import Quiz, QuizAttempt, QuizGenerationRun, QuizLearningMaterial, QuizPolicyDecision, User
from ..pipeline_flow import build_quiz_only_flow_layout
from ..pipeline_trace import inline_step_artifacts
from ..quiz_bundle import BundleSeedError, generate_quiz_bundle
from ..quiz_materials import activate_node_compositions, ensure_learning_material, materialize_node_expressions, reset_node_materials
from ..quiz_pipeline import (
    trace_quiz_queue_pick,
    trace_quiz_sm2_update,
)
from ..quiz_presenter import quiz_queue_item_dict
from ..quiz_generation_runs import (
    create_generation_run,
    list_generation_runs,
    process_generation_run,
    recover_stale_generation_runs,
    run_dict,
)
from ..quiz_queue import build_session, count_queues, grade_answer, pick_quizzes_by_ids, record_quiz_result
from ..quiz_progress import (
    add_attempt,
    dashboard as progress_dashboard,
    find_idempotent_attempt,
    user_timezone_name,
)
from ..quiz_batch import create_extra_daily_batch, fill_user_daily_batches
from ..quiz_audio_engine import (
    answer_audio_asset_key,
    resolve_cloze_answer_tts_text,
    resolve_quiz_tts_text,
    synthesize_quiz_audio,
)
from ..quiz_settings import quiz_selection_settings
from ..quiz_types import ENABLED_QUIZ_TYPES, validate_quiz_type
from ..tutor import DrillSeedError, evaluate_attempt_against_reference
from ..schemas import (
    LearningProfileOut,
    LevelUpdateRequest,
    ProfileSettingsUpdateRequest,
    QueueCounts,
    QuizDeleteOut,
    QuizDeletePreviewOut,
    QuizDeletePreviewRequest,
    QuizBatchDeleteOut,
    QuizGenerateOut,
    QuizGenerateRequest,
    QuizGenerationListOut,
    QuizGenerationRunCreateRequest,
    QuizGenerationRunListOut,
    QuizGenerationRunOut,
    QuizGenerationRunRetryRequest,
    QuizGenerationTraceOut,
    QuizExplorationListOut,
    QuizHistoryEventOut,
    QuizHistoryListOut,
    QuizItemOut,
    QuizMaterialAttemptListOut,
    QuizMaterialAttemptOut,
    QuizQueueItemOut,
    QuizQueueListOut,
    QuizAdminDetailOut,
    QuizAdminListOut,
    QuizAttemptOut,
    QuizProgressDashboardOut,
    QuizSessionOut,
    QuizSessionRequest,
    QuizSubmitRequest,
    QuizSubmitResponse,
    ScrambleHintOut,
    ScrambleHintRequest,
)
from ..workers.quiz_refill import refill_user_quizzes

router = APIRouter(prefix="/quiz", tags=["quiz"])


async def _pair_scrambles_with_compositions(
    session: AsyncSession, user_id: uuid.UUID, quizzes: list[Quiz]
) -> tuple[list[Quiz], dict[uuid.UUID, str]]:
    """Expand a scramble session into ordered scramble → composition units.

    The composition twin drills the *same* reviewed sentence, so it inherits
    the scramble's synthesized clip instead of paying for a second identical
    TTS render (compositions are never given their own audio).
    """
    ordered: list[Quiz] = []
    inherited_audio: dict[uuid.UUID, str] = {}
    for quiz in quizzes:
        ordered.append(quiz)
        if quiz.quiz_type != "scramble":
            continue
        unit_id = str((quiz.quiz_data or {}).get("learning_unit_id") or "")
        if not unit_id:
            continue
        companion = await session.scalar(
            select(Quiz).where(
                Quiz.user_id == user_id,
                Quiz.quiz_type == "composition",
                Quiz.queue_kind.in_(("new", "review")),
                Quiz.language == quiz.language,
                Quiz.source_nodes == quiz.source_nodes,
                Quiz.quiz_data["learning_unit_id"].astext == unit_id,
            )
        )
        if companion is not None:
            ordered.append(companion)
            audio_url = _quiz_audio_url(quiz)
            if audio_url and not _quiz_audio_url(companion):
                inherited_audio[companion.id] = audio_url
    return ordered, inherited_audio


def _attempt_out(attempt: QuizAttempt) -> QuizAttemptOut:
    return QuizAttemptOut(
        id=attempt.id,
        quiz_id=attempt.quiz_id,
        quiz_type=attempt.quiz_type,
        language=attempt.language,
        queue_kind=attempt.queue_kind,
        answer_payload=attempt.answer_payload,
        correct=attempt.correct,
        quality=attempt.quality,
        tutor_feedback=attempt.tutor_feedback,
        hint_level=attempt.hint_level,
        revealed_tokens=list(attempt.revealed_tokens or []),
        answer_revealed=attempt.answer_revealed,
        xp_awarded=attempt.xp_awarded,
        source=attempt.source,
        answered_at=attempt.answered_at,
    )


def _quiz_audio_url(quiz) -> str | None:
    qd = quiz.quiz_data if isinstance(quiz.quiz_data, dict) else {}
    return qd.get("audio_url")


def _quiz_answer_audio_url(quiz) -> str | None:
    qd = quiz.quiz_data if isinstance(quiz.quiz_data, dict) else {}
    return qd.get("answer_audio_url")


_SENTENCE_TERMINATOR_RE = re.compile(r"[.!?。？！](?=\s|$)")


def _scramble_presentable_reason(quiz: Quiz) -> str | None:
    if quiz.quiz_type != "scramble":
        return None
    qd = quiz.quiz_data if isinstance(quiz.quiz_data, dict) else {}
    chunks = qd.get("chunks")
    if not isinstance(chunks, list) or not chunks:
        return "missing chunks"
    sentence = str(qd.get("sentence_target") or quiz.sentence_target or "").strip()
    if len(_SENTENCE_TERMINATOR_RE.findall(sentence)) > 1:
        return "multiple target sentences"
    return None


async def _archive_unpresentable_scrambles(
    session: AsyncSession, quizzes: list[Quiz]
) -> tuple[list[Quiz], bool]:
    presentable: list[Quiz] = []
    archived = False
    for quiz in quizzes:
        reason = _scramble_presentable_reason(quiz)
        if reason:
            quiz.queue_kind = "archived"
            qd = dict(quiz.quiz_data or {})
            qd["archived_reason"] = f"scramble_unpresentable:{reason}"
            quiz.quiz_data = qd
            archived = True
            continue
        presentable.append(quiz)
    if archived:
        await session.flush()
    return presentable, archived


def _public_quiz_data(quiz, *, reveal_answer: bool = False) -> dict | None:
    """Never send a scramble's answer key or complete sentence before grading."""
    data = dict(quiz.quiz_data or {})
    if quiz.quiz_type == "scramble" and not reveal_answer:
        data.pop("correct_order", None)
        data.pop("accepted_orders", None)
        data.pop("sentence_target", None)
        data.pop("sentence_en", None)
        data.pop("audio_url", None)
        data.pop("answer_audio_url", None)
    return data or None


def _quiz_out(quiz, *, reveal_answer: bool = False, audio_url: str | None = None) -> QuizItemOut:
    is_hidden_scramble = quiz.quiz_type == "scramble" and not reveal_answer
    return QuizItemOut(
        id=quiz.id,
        quiz_type=quiz.quiz_type,
        difficulty_level=quiz.difficulty_level,
        queue_kind=quiz.queue_kind,
        question_ko=quiz.question_native,
        sentence_en=None if is_hidden_scramble else quiz.sentence_target,
        question_native=quiz.question_native,
        sentence_target=None if is_hidden_scramble else quiz.sentence_target,
        quiz_data=_public_quiz_data(quiz, reveal_answer=reveal_answer),
        audio_url=None if is_hidden_scramble else (_quiz_audio_url(quiz) or audio_url),
        answer_audio_url=None if is_hidden_scramble else _quiz_answer_audio_url(quiz),
        associated_entry_id=quiz.associated_entry_id,
        track=quiz.track,
        batch_id=quiz.batch_id,
    )


@router.get("/profile", response_model=LearningProfileOut)
async def get_profile(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> LearningProfileOut:
    counts = await count_queues(session, user.id)
    target_languages = crud.get_effective_target_languages(user)
    daily_progress = await crud.count_today_completed_quiz_types(
        session, user.id, target_languages, timezone_name=user_timezone_name(user)
    )

    lo, hi = window_for_level(user.current_level)
    return LearningProfileOut(
        current_level=user.current_level,
        is_freedom_on=user.is_freedom_on,
        cefr_label=cefr_label(user.current_level),
        level_window=(lo, hi),
        queue_counts={k: QueueCounts(**v) for k, v in counts.items()},
        selection_settings=quiz_selection_settings(user.current_level),
        target_language=getattr(user, "target_language", "english") or "english",
        target_languages=target_languages,
        native_language=getattr(user, "native_language", "korean") or "korean",
        language_levels=dict(getattr(user, "language_levels", None) or {}),
        daily_cloze_target=user.daily_cloze_target,
        daily_scramble_target=user.daily_scramble_target,
        daily_composition_target=user.daily_composition_target,
        quiz_review_ratio=user.quiz_review_ratio,
        # Compatibility field for older clients. Generation no longer branches
        # on this temporary development setting.
        auto_generate_quizzes=True,
        daily_progress_by_language=daily_progress,
        timezone=user_timezone_name(user),
        # Surfaced so the client can warn before a generation attempt fails.
        # Learning that the quota is gone from a 429 is learning it too late.
        daily_quota=await rate_limit_remaining(session, user.id, user),
        is_operator=_is_operator(user),
    )


def _is_operator(user: User) -> bool:
    """Whether this account may open the operator/developer tools.

    Two gates, both server-side: the deployment must have the tools enabled at
    all, and the handle must be on the allow-list. The app previously decided
    this locally by comparing the handle to 'main', so signing in with that
    handle was enough to reach pipeline traces and account administration.
    """
    from .auth import handle_from_email

    settings = get_settings()
    if not settings.operator_tools_enabled:
        return False
    handle = handle_from_email(user.email or "").strip().lower()
    return bool(handle) and handle in settings.operator_handle_list


async def _ensure_quiz_audio(session: AsyncSession, quizzes: list) -> None:
    """Backfill missing TTS for cloze and scramble quizzes.

    Covers two gaps: legacy cards from before audio existed, and cards whose
    TTS synthesis simply failed at generation time (see
    ``quiz_bundle.generate_quiz_bundle``, which logs and moves on rather than
    retrying). Nothing else ever revisits a scramble quiz's audio once it's
    created, so without this it stays permanently silent.
    """
    changed = False
    for quiz in quizzes:
        if quiz.quiz_type not in ("cloze", "scramble"):
            continue
        quiz_changed = False
        qd = dict(quiz.quiz_data or {})
        language = quiz.language or qd.get("language") or "english"
        if not qd.get("audio_url"):
            text = resolve_quiz_tts_text(
                quiz.quiz_type,
                {"sentence_en": quiz.sentence_target, "quiz_data": qd},
            )
            audio_url, _ = await synthesize_quiz_audio(
                quiz.id, text, language=language
            )
            if audio_url:
                qd["audio_url"] = audio_url
                changed = True
                quiz_changed = True
        if quiz.quiz_type == "cloze" and not qd.get("answer_audio_url"):
            answer_text = resolve_cloze_answer_tts_text({"quiz_data": qd})
            answer_url, _ = await synthesize_quiz_audio(
                quiz.id,
                answer_text,
                language=language,
                variant="answer",
                asset_key=answer_audio_asset_key(answer_text, language),
            )
            if answer_url:
                qd["answer_audio_url"] = answer_url
                changed = True
                quiz_changed = True
        if quiz_changed:
            quiz.quiz_data = qd
    if changed:
        await crud.sync_quiz_audio_links(session, quizzes)
        await session.commit()


async def _backfill_quiz_audio_background(quiz_ids: list[uuid.UUID]) -> None:
    """Prepare later session cards without delaying the first question."""
    if not quiz_ids:
        return
    async with async_session_factory() as background_session:
        quizzes = [
            quiz
            for quiz_id in quiz_ids
            if (quiz := await background_session.get(Quiz, quiz_id)) is not None
        ]
        await _ensure_quiz_audio(background_session, quizzes)


@router.get("/queue/items", response_model=QuizQueueListOut)
async def list_queue_items(
    queue_kind: Literal["new", "review"] = Query(...),
    quiz_type: Literal["scramble", "composition"] | None = None,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizQueueListOut:
    items, total = await crud.list_quiz_queue_items(
        session,
        user.id,
        queue_kind,
        quiz_type=quiz_type,
        limit=limit,
        offset=offset,
    )
    # Listing a queue must be read-only.  Scheduling LLM refills from this GET
    # endpoint made page refreshes repeatedly spend API budget when a source
    # could not produce a valid vocabulary item.  Refill is now triggered by a
    # graph update or an explicit learner action only.
    node_ids: set[uuid.UUID] = set()
    for quiz in items:
        if quiz.source_nodes:
            node_ids.update(quiz.source_nodes)
    node_names = await crud.get_node_names(session, node_ids)
    return QuizQueueListOut(
        items=[QuizQueueItemOut(**quiz_queue_item_dict(q, node_names)) for q in items],
        total=total,
        queue_kind=queue_kind,
        quiz_type=quiz_type,
    )


@router.get("/admin/items", response_model=QuizAdminListOut)
async def list_admin_quiz_items(
    queue_kinds: list[Literal["new", "review"]] | None = Query(None),
    quiz_types: list[Literal["cloze", "scramble", "composition"]] | None = Query(None),
    languages: list[str] | None = Query(None),
    include_archived: bool = False,
    sort: Literal["created_desc", "created_asc", "studied_desc"] = "created_desc",
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizAdminListOut:
    filters = [Quiz.user_id == user.id]
    # Operators can audit preserved cloze history only when they explicitly
    # include archived rows; learner-facing listings never expose it.
    filters.append(
        Quiz.quiz_type.in_(("cloze", "scramble", "composition"))
        if include_archived else Quiz.quiz_type.in_(("scramble", "composition"))
    )
    if not include_archived:
        filters.append(Quiz.queue_kind != "archived")
    if queue_kinds:
        filters.append(Quiz.queue_kind.in_(queue_kinds))
    if quiz_types:
        filters.append(Quiz.quiz_type.in_(quiz_types))
    if languages:
        filters.append(func.lower(Quiz.language).in_([v.lower() for v in languages]))
    ordering = {
        "created_desc": Quiz.created_at.desc(),
        "created_asc": Quiz.created_at.asc(),
        "studied_desc": Quiz.last_answered_at.desc().nullslast(),
    }[sort]
    total = int(
        await session.scalar(select(func.count()).select_from(Quiz).where(*filters))
        or 0
    )
    items = list(
        (
            await session.scalars(
                select(Quiz)
                .where(*filters)
                .order_by(ordering, Quiz.created_at.desc())
                .offset(offset)
                .limit(limit)
            )
        ).all()
    )
    node_ids = {node_id for item in items for node_id in (item.source_nodes or [])}
    names = await crud.get_node_names(session, node_ids)
    return QuizAdminListOut(
        items=[QuizQueueItemOut(**quiz_queue_item_dict(item, names)) for item in items],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.get("/admin/items/{quiz_id}", response_model=QuizAdminDetailOut)
async def get_admin_quiz_item(
    quiz_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizAdminDetailOut:
    quiz = await crud.get_quiz(session, quiz_id, user.id)
    if quiz is None:
        raise HTTPException(status_code=404, detail="Quiz not found")
    names = await crud.get_node_names(session, set(quiz.source_nodes or []))
    attempts = list(
        (
            await session.scalars(
                select(QuizAttempt)
                .where(
                    QuizAttempt.user_id == user.id,
                    QuizAttempt.quiz_id == quiz.id,
                )
                .order_by(QuizAttempt.answered_at.desc())
            )
        ).all()
    )
    return QuizAdminDetailOut(
        item=QuizQueueItemOut(**quiz_queue_item_dict(quiz, names)),
        attempts=[_attempt_out(attempt) for attempt in attempts],
        generation_key=quiz.generation_key,
        pipeline_trace=quiz.pipeline_trace,
        debug_run_dir=quiz.debug_run_dir,
        source_node_ids=list(quiz.source_nodes or []),
    )


@router.get("/progress/dashboard", response_model=QuizProgressDashboardOut)
async def get_progress_dashboard(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizProgressDashboardOut:
    """Streaks, goals and XP in the learner's own timezone.

    The zone comes from the stored profile, not a query parameter: attempt
    recording reads the same field, so the streak shown here and the day the XP
    cap applies to can no longer drift apart. Older clients still send
    `?timezone=`; FastAPI ignores the unknown parameter.
    """
    return QuizProgressDashboardOut(**await progress_dashboard(session, user))


@router.get("/queue/explorations", response_model=QuizExplorationListOut)
async def list_queue_explorations(
    language: str | None = Query(None),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizExplorationListOut:
    """Show Statement coverage, including per-language quiz-type counts."""
    languages = (
        [language.lower()]
        if language
        else crud.get_effective_target_languages(user)
    )
    rows_by_language = {
        lang: await crud.list_quiz_source_explorations(session, user.id, language=lang)
        for lang in languages
    }
    merged: dict[str, dict] = {}
    for lang, rows in rows_by_language.items():
        for row in rows:
            node_id = str(row["node_id"])
            item = merged.setdefault(
                node_id,
                {
                    "node_id": row["node_id"],
                    "node_name": row["node_name"],
                    "content_ko": row["content_ko"],
                    "status": "unexplored",
                "cloze_status": "available",
                "word_count": 0,
                "scramble_count": 0,
                "expression_count": 0,
                "composition_count": 0,
                    "updated_at": None,
                    "language_stats": [],
                },
            )
            item["language_stats"].append({
                "language": lang,
                "status": row["status"],
                "material_status": row.get("material_status", "unprocessed"),
                "cloze_status": row["cloze_status"],
                "generated_counts": {
                    "scramble": row["word_count"],
                    "composition": row["composition_count"],
                },
                "word_count": row["word_count"],
                "scramble_count": row["word_count"],
                "expression_count": row["expression_count"],
                "composition_count": row["composition_count"],
                "updated_at": row["updated_at"],
            })
            item["word_count"] += row["word_count"]
            item["scramble_count"] += row["word_count"]
            item["expression_count"] += row["expression_count"]
            item["composition_count"] += row["composition_count"]
            if row["updated_at"] and (
                item["updated_at"] is None or row["updated_at"] > item["updated_at"]
            ):
                item["updated_at"] = row["updated_at"]
    items = list(merged.values())
    for item in items:
        explored_languages = sum(
            1 for stat in item["language_stats"] if stat["status"] == "explored"
        )
        if explored_languages == len(languages):
            item["status"] = "explored"
        elif explored_languages:
            item["status"] = "partial"
    explored = sum(1 for item in items if item["status"] == "explored")
    partial = sum(1 for item in items if item["status"] == "partial")
    return QuizExplorationListOut(
        items=items,
        explored_count=explored,
        partial_count=partial,
        unexplored_count=len(items) - explored - partial,
        languages=languages,
    )


@router.post("/generation-runs", response_model=QuizGenerationRunOut)
async def start_generation_run(
    payload: QuizGenerationRunCreateRequest,
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizGenerationRunOut:
    try:
        run, created = await create_generation_run(
            session,
            user,
            node_ids=payload.node_ids,
            languages=payload.languages,
            idempotency_key=payload.idempotency_key,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if created:
        background.add_task(process_generation_run, run.id)
    return QuizGenerationRunOut(**run_dict(run))


@router.get("/generation-runs", response_model=QuizGenerationRunListOut)
async def get_generation_runs(
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizGenerationRunListOut:
    runs, total = await list_generation_runs(
        session, user.id, limit=limit, offset=offset
    )
    return QuizGenerationRunListOut(
        items=[QuizGenerationRunOut(**run_dict(run)) for run in runs],
        total=total,
    )


@router.get("/generation-runs/{run_id}", response_model=QuizGenerationRunOut)
async def get_generation_run(
    run_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizGenerationRunOut:
    await recover_stale_generation_runs(session, user.id)
    run = await session.get(QuizGenerationRun, run_id)
    if run is None or run.user_id != user.id:
        raise HTTPException(status_code=404, detail="Generation run not found")
    return QuizGenerationRunOut(**run_dict(run))


@router.get("/materials/{node_id}")
async def get_learning_material(
    node_id: uuid.UUID,
    language: str = Query(...),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Read the inventory state needed by a graph-node learning surface."""
    language = language.lower()
    row = await session.scalar(
        select(QuizLearningMaterial).where(
            QuizLearningMaterial.user_id == user.id,
            QuizLearningMaterial.node_id == node_id,
            QuizLearningMaterial.language == language,
        )
    )
    from ..node_expression_store import get_node_expressions
    expressions = await get_node_expressions(user.id, str(node_id), language)
    return {
        "node_id": str(node_id),
        "language": language,
        "status": row.status if row else "unprocessed",
        "composition_count": row.composition_count if row else 0,
        "expression_count": row.expression_count if row else len(expressions),
        "error": row.error if row else None,
        "expressions": expressions,
    }


@router.post("/materials/{node_id}/analyse")
async def analyse_learning_material(
    node_id: uuid.UUID,
    language: str = Query(...),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Queue/upgrade analysis for a node selected from the knowledge graph."""
    language = language.lower()
    # Direct selection is intentionally synchronous here: it either returns a
    # ready inventory or a truthful failure instead of making the client poll a
    # hidden task. The graph-save path remains background-only.
    row, created, _ = await ensure_learning_material(
        session, user, node_id=node_id, language=language, priority=100
    )
    # A learner explicitly selected this node, so complete the whole visible
    # learning set now: composition prompts plus every immediately useful
    # expression-based cloze (bounded to keep one request predictable).  The
    # former analysis-only path made this look like a random single word quiz
    # later when the refill worker happened to need one.
    activated = await activate_node_compositions(
        session, user, node_id=node_id, language=language, limit=8
    )
    return {
        "node_id": str(node_id),
        "language": language,
        "status": row.status,
        "composition_quiz_ids": [str(quiz.id) for quiz in activated if quiz.quiz_type == "composition"],
        "scramble_quiz_ids": [str(quiz.id) for quiz in activated if quiz.quiz_type == "scramble"],
        "composition_count": row.composition_count,
        "expression_count": row.expression_count,
        "scramble_count": sum(1 for quiz in activated if quiz.quiz_type == "scramble"),
    }


@router.post("/materials/{node_id}/expressions/materialize")
async def materialize_learning_expressions(
    node_id: uuid.UUID,
    language: str = Query(...),
    expressions: list[str] | None = None,
    limit: int = Query(6, ge=1, le=8),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Create cloze cards for selected (or top-ranked) stored expressions."""
    language = language.lower()
    selected = None
    if expressions:
        from ..node_expression_store import get_node_expressions
        requested = {value.strip().lower() for value in expressions if value.strip()}
        selected = [
            item for item in await get_node_expressions(user.id, str(node_id), language)
            if str(item.get("expression") or "").lower() in requested
            and str(item.get("quiz_status") or "available") == "available"
        ]
    created, _ = await materialize_node_expressions(
        session,
        user,
        node_id=node_id,
        language=language,
        expressions=selected,
        limit=limit,
        direct_node=True,
        queue_missing=limit,
    )
    return {"status": "ok", "quiz_ids": [str(quiz.id) for quiz in created], "count": len(created)}


@router.delete("/materials/{node_id}")
async def reset_learning_material(
    node_id: uuid.UUID,
    language: str | None = Query(None),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Archive every quiz + delete every expression this Statement produced.

    Scoped to one ``language`` when given, otherwise every active target
    language. The Statement itself is untouched — the next manual generation
    (or auto-refill) starts this node over from a clean slate.
    """
    try:
        result = await reset_node_materials(
            session, user,
            node_id=node_id,
            languages=[language.lower()] if language else None,
        )
    except BundleSeedError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {"node_id": str(node_id), **result}


@router.get("/admin/policy-dashboard")
async def policy_dashboard(
    limit: int = Query(30, ge=1, le=200),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Read-only, explainable policy overview for the manager surface."""
    materials = (
        await session.scalars(
            select(QuizLearningMaterial)
            .where(QuizLearningMaterial.user_id == user.id)
            .order_by(QuizLearningMaterial.updated_at.desc())
            .limit(limit)
        )
    ).all()
    decisions = (
        await session.scalars(
            select(QuizPolicyDecision)
            .where(QuizPolicyDecision.user_id == user.id)
            .order_by(QuizPolicyDecision.created_at.desc())
            .limit(limit)
        )
    ).all()
    queues = await count_queues(session, user.id)
    token_usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    for material in materials:
        trace = (material.result or {}).get("trace") or {}
        for step in trace.get("steps") or []:
            usage = (step.get("output") or {}).get("usage") or {}
            for key in token_usage:
                token_usage[key] += int(usage.get(key) or 0)
    return {
        "policies": [
            {"name": "generation", "version": "generation-v1-inventory-first", "summary": "학습 소재 분석 후 미생성 표현만 필요할 때 문제화"},
            {"name": "presentation", "version": "presentation-v1-tiered", "summary": "직접 선택 노드, 지연 복습, 오늘 복습, 새 문제 순"},
            {"name": "review", "version": "review-v1-sm2", "summary": "풀이 품질과 결과로 다음 복습 시점 계산"},
        ],
        "queues": queues,
        "token_usage": token_usage,
        "materials": [
            {"node_id": str(row.node_id), "language": row.language, "status": row.status,
             "composition_count": row.composition_count, "expression_count": row.expression_count,
             "expansion_count": row.expansion_count, "error": row.error, "updated_at": row.updated_at}
            for row in materials
        ],
        "recent_decisions": [
            {"policy": row.policy, "version": row.policy_version, "entity_type": row.entity_type,
             "entity_id": row.entity_id, "reason": row.reason, "details": row.details or {}, "created_at": row.created_at}
            for row in decisions
        ],
    }


@router.post(
    "/generation-runs/{run_id}/retry",
    response_model=QuizGenerationRunOut,
)
async def retry_generation_run(
    run_id: uuid.UUID,
    payload: QuizGenerationRunRetryRequest,
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizGenerationRunOut:
    await recover_stale_generation_runs(session, user.id)
    previous = await session.get(QuizGenerationRun, run_id)
    if previous is None or previous.user_id != user.id:
        raise HTTPException(status_code=404, detail="Generation run not found")
    failed = [
        item for item in (previous.items or []) if item.get("status") == "failed"
    ]
    if not failed:
        raise HTTPException(status_code=409, detail="재시도할 실패 항목이 없습니다.")

    node_ids = list(
        dict.fromkeys(uuid.UUID(str(item["node_id"])) for item in failed)
    )
    languages = list(
        dict.fromkeys(str(item["language"]).lower() for item in failed)
    )
    try:
        run, created = await create_generation_run(
            session,
            user,
            node_ids=node_ids,
            languages=languages,
            idempotency_key=payload.idempotency_key,
            source="retry",
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    failed_pairs = {
        (str(item["node_id"]), str(item["language"]).lower()) for item in failed
    }
    if created:
        run.items = [
            item
            for item in (run.items or [])
            if (str(item["node_id"]), str(item["language"]).lower())
            in failed_pairs
        ]
        run.node_ids = list(dict.fromkeys(item["node_id"] for item in run.items))
        run.languages = list(
            dict.fromkeys(item["language"] for item in run.items)
        )
        run.total_count = len(run.items)
        await session.commit()
        await session.refresh(run)
        background.add_task(process_generation_run, run.id)
    return QuizGenerationRunOut(**run_dict(run))


@router.delete("/queue/reset")
async def reset_quiz_queue(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    archived = await crud.reset_quiz_queue(session, user.id)
    return {"status": "reset", "archived": archived}


@router.post("/delete-preview", response_model=QuizDeletePreviewOut)
async def preview_quiz_delete(
    payload: QuizDeletePreviewRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizDeletePreviewOut:
    return QuizDeletePreviewOut(
        **await crud.preview_quiz_audio_cleanup(session, user.id, payload.quiz_ids)
    )


@router.post("/delete-permanent", response_model=QuizBatchDeleteOut)
async def delete_quizzes_permanent(
    payload: QuizDeletePreviewRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizBatchDeleteOut:
    preview = await crud.preview_quiz_audio_cleanup(session, user.id, payload.quiz_ids)
    cleanup = await crud.delete_quizzes_permanent_batch(session, payload.quiz_ids, user.id)
    return QuizBatchDeleteOut(
        deleted_quiz_count=cleanup["quiz_count"],
        audio_deleted_count=len(cleanup["deleted"]),
        audio_retained_count=preview["audio_retained_count"],
    )


@router.delete("/{quiz_id}", response_model=QuizDeleteOut)
async def delete_quiz_item(
    quiz_id: uuid.UUID,
    permanent: bool = Query(False),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizDeleteOut:
    if permanent:
        cleanup = await crud.delete_quiz_permanent(session, quiz_id, user.id)
        if cleanup is None:
            raise HTTPException(status_code=404, detail="Quiz not found")
        return QuizDeleteOut(
            id=quiz_id, status="deleted", queue_kind="archived",
            audio_deleted=cleanup["deleted"], audio_retained=cleanup["retained"],
        )
    quiz = await crud.archive_quiz(session, quiz_id, user.id)
    if quiz is None:
        raise HTTPException(status_code=404, detail="Quiz not found")
    return QuizDeleteOut(id=quiz.id, status="archived", queue_kind=quiz.queue_kind)


@router.get("/generations", response_model=QuizGenerationListOut)
async def list_generations(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizGenerationListOut:
    items, total = await crud.list_quiz_generations(
        session, user.id, limit=limit, offset=offset
    )
    node_ids: set[uuid.UUID] = set()
    for quiz in items:
        if quiz.source_nodes:
            node_ids.update(quiz.source_nodes)
    node_names = await crud.get_node_names(session, node_ids)
    return QuizGenerationListOut(
        items=[QuizQueueItemOut(**quiz_queue_item_dict(q, node_names)) for q in items],
        total=total,
    )


@router.get("/generation-history", response_model=QuizHistoryListOut)
async def list_generation_history(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizHistoryListOut:
    """Cards that got created and node analyses that rejected every candidate,
    interleaved by time — the single feed the debug hub's quiz tab renders,
    mirroring the KG tab's one chronological run list."""
    pairs, total = await crud.list_quiz_generation_history(
        session, user.id, limit=limit, offset=offset
    )
    node_ids: set[uuid.UUID] = set()
    for kind, obj in pairs:
        if kind == "quiz" and obj.source_nodes:
            node_ids.update(obj.source_nodes)
        elif kind == "material":
            node_ids.add(obj.node_id)
    node_names = await crud.get_node_names(session, node_ids)

    events: list[QuizHistoryEventOut] = []
    for kind, obj in pairs:
        if kind == "quiz":
            names = [node_names[nid] for nid in (obj.source_nodes or []) if nid in node_names]
            title = obj.sentence_target or obj.question_native or ", ".join(names) or "(문제)"
            events.append(QuizHistoryEventOut(
                kind="quiz",
                id=obj.id,
                timestamp=obj.created_at,
                ok=True,
                title=title,
                subtitle=f"{obj.language or ''} · {obj.queue_kind}".strip(" ·"),
                quiz_type=obj.quiz_type,
                language=obj.language,
            ))
        else:
            events.append(QuizHistoryEventOut(
                kind="material",
                id=obj.id,
                timestamp=obj.updated_at,
                ok=obj.status != "failed" and obj.composition_count > 0,
                title=node_names.get(obj.node_id, "(제목 없음)"),
                subtitle=(
                    obj.error
                    or f"작문 {obj.composition_count}개 · 표현 {obj.expression_count}개"
                ),
                quiz_type=None,
                language=obj.language,
            ))
    return QuizHistoryListOut(items=events, total=total)


@router.get("/material-attempts", response_model=QuizMaterialAttemptListOut)
async def list_material_attempts(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_operator_tools),
) -> QuizMaterialAttemptListOut:
    """Every node analysis attempt, including ones that rejected every candidate
    and produced zero quizzes — invisible in /generations, which only lists
    cards that survived."""
    items, total = await crud.list_quiz_material_attempts(
        session, user.id, limit=limit, offset=offset
    )
    node_names = await crud.get_node_names(session, {item.node_id for item in items})
    return QuizMaterialAttemptListOut(
        items=[
            QuizMaterialAttemptOut(
                id=item.id,
                node_id=item.node_id,
                node_name=node_names.get(item.node_id, ""),
                language=item.language,
                status=item.status,
                composition_count=item.composition_count,
                expression_count=item.expression_count,
                error=item.error,
                updated_at=item.updated_at,
            )
            for item in items
        ],
        total=total,
    )


@router.get("/material-attempts/{material_id}/trace", response_model=QuizGenerationTraceOut)
async def get_material_attempt_trace(
    material_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_debug_enabled),
) -> QuizGenerationTraceOut:
    material = await session.get(QuizLearningMaterial, material_id)
    if material is None or material.user_id != user.id:
        raise HTTPException(status_code=404, detail="Material analysis not found")
    result = material.result if isinstance(material.result, dict) else {}
    trace = result.get("trace") if isinstance(result.get("trace"), dict) else {}
    trace = inline_step_artifacts(dict(trace))
    return QuizGenerationTraceOut(
        run_id=trace.get("run_id") or str(material_id),
        status=trace.get("status") or material.status,
        steps=trace.get("steps") or [],
        flow_layout=None,
        debug_dir=None,
    )


@router.get("/history", response_model=QuizQueueListOut)
async def list_quiz_history(
    quiz_type: Literal["scramble", "composition"] | None = None,
    language: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizQueueListOut:
    """Past answered quizzes (most-recent first) for the review/history screen."""
    items, total = await crud.list_quiz_history(
        session,
        user.id,
        quiz_type=quiz_type,
        language=language,
        limit=limit,
        offset=offset,
    )
    node_ids: set[uuid.UUID] = set()
    for quiz in items:
        if quiz.source_nodes:
            node_ids.update(quiz.source_nodes)
    node_names = await crud.get_node_names(session, node_ids)
    return QuizQueueListOut(
        items=[QuizQueueItemOut(**quiz_queue_item_dict(q, node_names)) for q in items],
        total=total,
        queue_kind="history",
        quiz_type=quiz_type,
    )


@router.get("/pipeline/flow-blueprint")
async def get_quiz_flow_blueprint() -> dict:
    """Quiz Path DAG only — pending layout for the problem-generation hub."""
    layout = build_quiz_only_flow_layout({"steps": [], "status": "pending"})
    return {
        "version": layout.get("version"),
        "flow_layout": layout,
    }


@router.post("/generate", response_model=QuizGenerateOut)
async def generate_quiz_graph(
    quiz_type: Literal["scramble", "composition"] = Query(...),
    language: str | None = Query(None, description="Target language for this quiz (overrides profile default)"),
    body: QuizGenerateRequest | None = None,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _quota: None = Depends(daily_quota(KIND_QUIZ_GEN)),
) -> QuizGenerateOut:
    if quiz_type not in ENABLED_QUIZ_TYPES:
        raise HTTPException(
            status_code=410,
            detail={"code": "disabled", "quiz_type": quiz_type},
        )

    if quiz_type == "composition":
        lang = (language or getattr(user, "target_language", None) or "english").lower()
        count = max(1, min(body.count if body else 1, 10))
        source_mode = body.source_mode if body else "journal"
        difficulty = body.difficulty if body else "normal"
        first: object | None = None
        first_trace: dict = {}
        used_nodes: set[str] = set()
        generated = 0
        for _ in range(count):
            try:
                quiz, trace = await generate_composition_quiz(
                    session,
                    user,
                    language=lang,
                    source_mode=source_mode,
                    exclude_node_ids=used_nodes or None,
                    difficulty=difficulty,
                )
            except DrillSeedError as exc:
                if generated == 0:
                    raise HTTPException(
                        status_code=409,
                        detail={"code": "no_seed", "message": str(exc)},
                    ) from exc
                break
            if first is None:
                first, first_trace = quiz, trace
            for nid in quiz.source_nodes or []:
                used_nodes.add(str(nid))
            generated += 1
        assert first is not None  # generated >= 1 guaranteed by the raise above
        return QuizGenerateOut(
            quiz_id=first.id,
            quiz_type=first.quiz_type,
            difficulty_level=first.difficulty_level,
            trace_step_count=len(first_trace.get("steps") or []),
            generated_count=generated,
        )

    # Word types (cloze/scramble/mcq_nuance) → unified bundle: one LLM call
    # generates all four types from one Statement; we return the requested type
    # and leave the rest queued.
    lang = (language or getattr(user, "target_language", None) or "english").lower()
    try:
        created, trace = await generate_quiz_bundle(session, user, language=lang)
    except BundleSeedError as exc:
        raise HTTPException(
            status_code=409, detail={"code": "no_seed", "message": str(exc)}
        ) from exc
    match = next((q for q in created if q.quiz_type == quiz_type), None)
    if match is None:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "no_item",
                "quiz_type": quiz_type,
                "generated": len(created),
            },
        )
    return QuizGenerateOut(
        quiz_id=match.id,
        quiz_type=match.quiz_type,
        difficulty_level=match.difficulty_level,
        trace_step_count=len(trace.get("steps") or []),
        generated_count=len(created),
    )


@router.get("/generations/{quiz_id}/trace", response_model=QuizGenerationTraceOut)
async def get_generation_trace(
    quiz_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_debug_enabled),
) -> QuizGenerationTraceOut:
    quiz = await crud.get_quiz(session, quiz_id, user.id)
    if quiz is None:
        raise HTTPException(status_code=404, detail="Quiz not found")
    if quiz.pipeline_trace:
        trace = dict(quiz.pipeline_trace)
    else:
        trace = {
            "run_id": str(quiz_id),
            "status": "pending",
            "steps": [],
            "debug_dir": quiz.debug_run_dir,
        }
    trace["flow_layout"] = build_quiz_only_flow_layout(trace)
    trace = inline_step_artifacts(trace)
    return QuizGenerationTraceOut(
        run_id=trace.get("run_id"),
        status=trace.get("status", "pending"),
        steps=trace.get("steps") or [],
        flow_layout=trace.get("flow_layout"),
        debug_dir=quiz.debug_run_dir,
    )


@router.get("/generations/{quiz_id}/artifacts/{artifact_path:path}")
async def get_generation_artifact(
    quiz_id: uuid.UUID,
    artifact_path: str,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _: None = Depends(require_debug_enabled),
) -> FileResponse:
    quiz = await crud.get_quiz(session, quiz_id, user.id)
    if quiz is None:
        raise HTTPException(status_code=404, detail="Quiz not found")
    if not quiz.debug_run_dir:
        raise HTTPException(status_code=404, detail="No debug artifacts")

    settings = get_settings()
    rel = (quiz.debug_run_dir or f"debug_runs/{quiz_id}").removeprefix("debug_runs/").lstrip("/")
    root = (Path(settings.debug_runs_dir) / rel).resolve()
    file_path = (root / artifact_path).resolve()
    if not file_path.is_relative_to(root.resolve()):
        raise HTTPException(status_code=400, detail="Invalid artifact path")
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Artifact not found")

    media = "application/octet-stream"
    if file_path.suffix == ".json":
        media = "application/json"
    elif file_path.suffix == ".txt":
        media = "text/plain"
    return FileResponse(file_path, media_type=media, filename=file_path.name)


@router.patch("/profile/level", response_model=LearningProfileOut)
async def update_level(
    payload: LevelUpdateRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> LearningProfileOut:
    await crud.update_user_level(session, user, payload.level)
    await reclassify_queue_by_level(session, user.id, payload.level)
    return await get_profile(user=user, session=session)


@router.patch("/profile/settings", response_model=LearningProfileOut)
async def update_profile_settings(
    payload: ProfileSettingsUpdateRequest,
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> LearningProfileOut:
    native = (payload.native_language or getattr(user, "native_language", None) or DEFAULT_NATIVE).lower()
    if payload.native_language is not None and native not in SUPPORTED_NATIVE:
        raise HTTPException(
            status_code=400,
            detail={"code": "unsupported_native", "language": payload.native_language},
        )
    if (
        payload.native_language is not None
        and native != (getattr(user, "native_language", None) or DEFAULT_NATIVE).lower()
    ):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "native_language_locked",
                "message": "Native language is fixed when the account is created",
            },
        )
    # Only the 3 supported (native, target) pairs may be chosen.
    allowed_targets = valid_target_for_native(native)
    if payload.target_languages is not None:
        bad = {l.lower() for l in payload.target_languages} - allowed_targets
        if bad:
            raise HTTPException(
                status_code=400,
                detail={
                    "code": "unsupported_target",
                    "languages": sorted(bad),
                    "allowed": sorted(allowed_targets),
                },
            )
    if payload.target_language is not None and payload.target_language.lower() not in allowed_targets:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "unsupported_target",
                "languages": [payload.target_language],
                "allowed": sorted(allowed_targets),
            },
        )

    prev_level = user.current_level
    prev_langs = set(crud.get_effective_target_languages(user))
    await crud.update_user_profile_settings(
        session,
        user,
        level=payload.level,
        is_freedom_on=payload.is_freedom_on,
        target_language=payload.target_language,
        target_languages=payload.target_languages,
        native_language=payload.native_language,
        language_levels=payload.language_levels,
        daily_cloze_target=payload.daily_cloze_target,
        daily_scramble_target=payload.daily_scramble_target,
        daily_composition_target=payload.daily_composition_target,
        quiz_review_ratio=payload.quiz_review_ratio,
        auto_generate_quizzes=True,
        timezone=payload.timezone,
    )
    if payload.level is not None and payload.level != prev_level:
        await reclassify_queue_by_level(session, user.id, payload.level)

    new_languages = set(crud.get_effective_target_languages(user)) - prev_langs
    if new_languages:
        from ..quiz_materials import analyse_material_background
        for source in await crud.get_all_statement_nodes(session, user.id):
            node_id = source.get("node_id")
            if node_id:
                background.add_task(
                    analyse_material_background,
                    user.id,
                    uuid.UUID(str(node_id)),
                    sorted(new_languages),
                )

    return await get_profile(user=user, session=session)


@router.post("/session", response_model=QuizSessionOut)
async def start_session(
    payload: QuizSessionRequest,
    background_tasks: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizSessionOut:
    # Keep old clients working, but route their generic word entry to the new
    # deterministic sentence-order exercise rather than the parked cloze.
    if payload.quiz_type == "word":
        payload = payload.model_copy(update={"quiz_type": "scramble"})

    inherited_audio: dict[uuid.UUID, str] = {}
    quiz_type = validate_quiz_type(payload.quiz_type)
    if quiz_type not in ENABLED_QUIZ_TYPES:
        raise HTTPException(
            status_code=410,
            detail={"code": "disabled", "quiz_type": quiz_type},
        )
    if payload.quiz_ids:
        picked = await pick_quizzes_by_ids(session, user.id, payload.quiz_ids)
        if not picked:
            raise HTTPException(status_code=404, detail="Quiz not found")
    else:
        picked = await build_session(
            session,
            user.id,
            quiz_type,
            size=payload.size,
            entry_id=payload.entry_id,
            vocab_source=payload.vocab_source,
            language=payload.language,
        )
    if quiz_type == "scramble":
        picked, archived_scrambles = await _archive_unpresentable_scrambles(
            session, list(picked)
        )
        if archived_scrambles and not picked:
            await session.commit()
        # Pairing only applies to the auto-built daily queue. An explicit
        # quiz_ids selection (studying specific cards from a node) is a
        # deliberate, scoped choice — silently appending each scramble's
        # composition twin turned "study just this scramble" into "and then
        # a composition card you never asked for" once the scramble was
        # answered. Scramble and composition stay independent selections
        # until pairing them is an explicit, opt-in feature.
        if not payload.quiz_ids:
            picked, inherited_audio = await _pair_scrambles_with_compositions(
                session, user.id, list(picked)
            )
    if picked:
        # The learner sees this first card immediately, so ensure its answer
        # clip before returning. Remaining legacy/failed-TTS cards are
        # repaired in the background while the learner works on the first one.
        await _ensure_quiz_audio(session, picked[:1])
        remaining_legacy_ids = [
            quiz.id
            for quiz in picked[1:]
            if (
                quiz.quiz_type == "cloze"
                and not (quiz.quiz_data or {}).get("answer_audio_url")
            )
            or (
                quiz.quiz_type == "scramble"
                and not (quiz.quiz_data or {}).get("audio_url")
            )
        ]
        if remaining_legacy_ids:
            background_tasks.add_task(
                _backfill_quiz_audio_background, remaining_legacy_ids
            )
        lo, hi = window_for_level(user.current_level)
        await trace_quiz_queue_pick(
            session,
            picked[0].id,
            user.id,
            quiz_type,
            picked,
            level=user.current_level,
            window=(lo, hi),
        )
    new_n = sum(1 for q in picked if q.queue_kind == "new")
    return QuizSessionOut(
        items=[_quiz_out(q, audio_url=inherited_audio.get(q.id)) for q in picked],
        quiz_type=quiz_type,
        new_count=new_n,
        review_count=len(picked) - new_n,
    )


@router.post("/{quiz_id}/hint", response_model=ScrambleHintOut)
async def scramble_hint(
    quiz_id: uuid.UUID,
    payload: ScrambleHintRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> ScrambleHintOut:
    """Reveal the first N chunks of the reference order.

    The answer key never reaches the client before grading (see
    ``_public_quiz_data``), so an order hint has to be served here. Hints are
    a strict prefix: the learner still has to place everything after it, and
    the level travels back with the attempt for XP/telemetry.
    """
    quiz = await crud.get_quiz(session, quiz_id, user.id)
    if quiz is None:
        raise HTTPException(status_code=404, detail="Quiz not found")
    if quiz.quiz_type != "scramble":
        raise HTTPException(status_code=400, detail="Hints are scramble-only")
    order = [str(chunk_id) for chunk_id in ((quiz.quiz_data or {}).get("correct_order") or [])]
    if not order:
        raise HTTPException(status_code=409, detail="Quiz has no answer key")
    # Placing every chunk but the last one leaves no choice at all, so that is
    # the ceiling: a hint assists, it never answers the card outright.
    max_hint_level = max(0, len(order) - 2)
    level = min(max(int(payload.hint_level or 1), 1), max_hint_level) if max_hint_level else 0
    return ScrambleHintOut(
        hint_level=level,
        ordered_prefix=order[:level],
        max_hint_level=max_hint_level,
    )


@router.post("/{quiz_id}/submit", response_model=QuizSubmitResponse)
async def submit_quiz(
    quiz_id: uuid.UUID,
    payload: QuizSubmitRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizSubmitResponse:
    quiz = await crud.get_quiz(session, quiz_id, user.id)
    if quiz is None:
        raise HTTPException(status_code=404, detail="Quiz not found")
    idempotency_key = payload.idempotency_key or f"submit-{uuid.uuid4()}"
    # Serialize identical client retries before checking the unique key. This
    # prevents two fast taps from both grading/updating SM-2 before one loses
    # the unique-index race at commit time.
    await session.execute(
        select(func.pg_advisory_xact_lock(func.hashtext(idempotency_key)))
    )
    existing = await find_idempotent_attempt(session, user.id, idempotency_key)
    if existing is not None:
        if existing.quiz_id != quiz.id:
            raise HTTPException(status_code=409, detail="Idempotency key already used")
        return QuizSubmitResponse(
            correct=existing.correct,
            quality=existing.quality,
            quiz=_quiz_out(quiz, reveal_answer=quiz.quiz_type == "scramble"),
            explanation=(quiz.quiz_data or {}).get("explanation"),
            tutor_feedback=existing.tutor_feedback,
            attempt_id=existing.id,
            xp_awarded=existing.xp_awarded,
        )

    answer_payload = {
        key: value
        for key, value in {
            "answer": payload.answer,
            "order": payload.order,
            "selected_index": payload.selected_index,
            "self_grade": payload.self_grade,
            "entry_id": str(payload.entry_id) if payload.entry_id else None,
        }.items()
        if value is not None
    }

    # A self-graded flashcard carries no written attempt, so the reference
    # evaluation below would score an empty string with a real LLM call. Fall
    # through to grade_answer's self_grade branch instead.
    if quiz.quiz_type == "composition" and payload.self_grade is None:
        qd = quiz.quiz_data or {}
        eval_result = await evaluate_attempt_against_reference(
            user,
            prompt=quiz.question_native or qd.get("prompt") or "",
            user_answer=payload.answer or "",
            language=qd.get("language") or getattr(user, "target_language", None) or "english",
            model_answers=qd.get("model_answers"),
            target_expressions=qd.get("target_expressions"),
            key_expressions=qd.get("key_expressions"),
        )
        correct, quality = verdict_to_sm2(
            eval_result.get("verdict", "understandable"),
            eval_result.get("quality"),
        )
        feedback = merge_composition_feedback(qd, eval_result)
        attempt = await add_attempt(
            session,
            user_id=user.id,
            quiz=quiz,
            idempotency_key=idempotency_key,
            answer_payload=answer_payload,
            correct=correct,
            quality=quality,
            tutor_feedback=feedback,
            hint_level=payload.hint_level,
            revealed_tokens=payload.revealed_tokens,
            answer_revealed=payload.answer_revealed,
            timezone_name=user_timezone_name(user),
        )
        quiz = await record_quiz_result(
            session, quiz, correct=correct, quality=quality, commit=False
        )
        await session.commit()
        await session.refresh(quiz)
        await session.refresh(attempt)
        await trace_quiz_sm2_update(
            session, quiz_id, user.id, quiz, correct=correct, quality=quality,
        )
        return QuizSubmitResponse(
            correct=correct,
            quality=quality,
            quiz=_quiz_out(quiz, reveal_answer=quiz.quiz_type == "scramble"),
            explanation=None,
            tutor_feedback=feedback,
            attempt_id=attempt.id,
            xp_awarded=attempt.xp_awarded,
        )

    correct, quality = grade_answer(quiz, answer_payload)
    attempt = await add_attempt(
        session,
        user_id=user.id,
        quiz=quiz,
        idempotency_key=idempotency_key,
        answer_payload=answer_payload,
        correct=correct,
        quality=quality,
        tutor_feedback=None,
        hint_level=payload.hint_level,
        revealed_tokens=payload.revealed_tokens,
        answer_revealed=payload.answer_revealed,
        timezone_name=user_timezone_name(user),
    )
    quiz = await record_quiz_result(
        session, quiz, correct=correct, quality=quality, commit=False
    )
    await session.commit()
    await session.refresh(quiz)
    await session.refresh(attempt)

    await trace_quiz_sm2_update(
        session,
        quiz_id,
        user.id,
        quiz,
        correct=correct,
        quality=quality,
    )

    explanation = None
    if quiz.quiz_data:
        explanation = quiz.quiz_data.get("explanation")

    # The grading reveal is the learner's one chance to hear this sentence.
    # Background repair (see the session-build endpoint) usually wins the
    # race, but if it hasn't landed yet — or this card was never covered by
    # it at all — catch it here rather than leaving the card silent forever.
    if quiz.quiz_type == "scramble" and not (quiz.quiz_data or {}).get("audio_url"):
        await _ensure_quiz_audio(session, [quiz])

    return QuizSubmitResponse(
        correct=correct,
        quality=quality,
        quiz=_quiz_out(quiz, reveal_answer=quiz.quiz_type == "scramble"),
        explanation=explanation,
        attempt_id=attempt.id,
        xp_awarded=attempt.xp_awarded,
    )


@router.post("/refill")
async def manual_refill(
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    _quota: None = Depends(daily_quota(KIND_QUIZ_GEN)),
) -> dict:
    # A refill can include several LLM + TTS calls.  Return immediately so the
    # client connection never waits for the entire batch and times out.
    background.add_task(refill_user_quizzes, user.id)
    return {"status": "scheduled"}


async def _fill_now(user_id: uuid.UUID) -> dict:
    from ..db import async_session_factory
    async with async_session_factory() as session:
        user = await session.get(User, user_id)
        if user is None:
            return {"status": "skipped", "reason": "user not found"}
        return {"status": "ok", "batches": await fill_user_daily_batches(session, user)}


@router.post("/batch/more")
async def generate_more_batch(
    language: str | None = Query(None),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    _quota: None = Depends(daily_quota(KIND_QUIZ_GEN)),
) -> dict:
    lang = (language or crud.get_effective_target_languages(user)[0]).lower()
    return await create_extra_daily_batch(session, user, language=lang)
