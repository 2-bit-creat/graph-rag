"""Gamified quiz API — manual generation, sessions, profile."""

from __future__ import annotations

import uuid
from typing import Literal

from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..composition_quiz import (
    generate_composition_quiz,
    merge_composition_feedback,
    verdict_to_sm2,
)
from ..config import get_settings
from ..db import get_session
from ..deps import request_user_dep
from ..level_adjuster import reclassify_queue_by_level
from ..level_guidelines import cefr_label, window_for_level
from ..models import User
from ..pipeline_flow import build_quiz_only_flow_layout
from ..quiz_pipeline import (
    run_quiz_generate_pipeline,
    trace_quiz_queue_pick,
    trace_quiz_sm2_update,
)
from ..quiz_presenter import quiz_queue_item_dict
from ..quiz_queue import build_session, count_queues, grade_answer, pick_quizzes_by_ids, record_quiz_result
from ..quiz_settings import quiz_selection_settings
from ..quiz_types import ENABLED_QUIZ_TYPES, validate_quiz_type
from ..tutor import DrillSeedError, evaluate_attempt_against_reference
from ..user_vocab_store import append_tutor_history
from ..schemas import (
    LearningProfileOut,
    LevelUpdateRequest,
    ProfileSettingsUpdateRequest,
    QueueCounts,
    QuizDeleteOut,
    QuizGenerateOut,
    QuizGenerateRequest,
    QuizGenerationListOut,
    QuizGenerationTraceOut,
    QuizItemOut,
    QuizQueueItemOut,
    QuizQueueListOut,
    QuizSessionOut,
    QuizSessionRequest,
    QuizSubmitRequest,
    QuizSubmitResponse,
)
from ..workers.quiz_refill import refill_user_quizzes

router = APIRouter(prefix="/quiz", tags=["quiz"])


def _maybe_schedule_refill(
    background_tasks: BackgroundTasks,
    user_id: uuid.UUID,
    counts: dict[str, dict[str, int]],
) -> None:
    settings = get_settings()
    if not settings.quiz_auto_enabled:
        return
    target = settings.quiz_queue_target_per_type
    if not any(counts.get(t, {}).get("new", 0) < target for t in ENABLED_QUIZ_TYPES):
        return
    background_tasks.add_task(refill_user_quizzes, user_id)


def _quiz_audio_url(quiz) -> str | None:
    qd = quiz.quiz_data if isinstance(quiz.quiz_data, dict) else {}
    return qd.get("audio_url")


def _quiz_out(quiz) -> QuizItemOut:
    return QuizItemOut(
        id=quiz.id,
        quiz_type=quiz.quiz_type,
        difficulty_level=quiz.difficulty_level,
        queue_kind=quiz.queue_kind,
        question_ko=quiz.question_ko,
        sentence_en=quiz.sentence_en,
        quiz_data=quiz.quiz_data,
        audio_url=_quiz_audio_url(quiz),
        associated_entry_id=quiz.associated_entry_id,
    )


@router.get("/profile", response_model=LearningProfileOut)
async def get_profile(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> LearningProfileOut:
    counts = await count_queues(session, user.id)
    lo, hi = window_for_level(user.current_level)
    return LearningProfileOut(
        current_level=user.current_level,
        is_freedom_on=user.is_freedom_on,
        cefr_label=cefr_label(user.current_level),
        level_window=(lo, hi),
        queue_counts={k: QueueCounts(**v) for k, v in counts.items()},
        selection_settings=quiz_selection_settings(user.current_level),
        target_language=getattr(user, "target_language", "english") or "english",
        target_languages=crud.get_effective_target_languages(user),
        native_language=getattr(user, "native_language", "korean") or "korean",
        language_levels=dict(getattr(user, "language_levels", None) or {}),
    )


@router.get("/queue/items", response_model=QuizQueueListOut)
async def list_queue_items(
    queue_kind: Literal["new", "review"] = Query(...),
    quiz_type: Literal["cloze", "scramble", "mcq_nuance", "composition"] | None = None,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    order: Literal["asc", "desc"] = Query("desc"),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    *,
    background_tasks: BackgroundTasks,
) -> QuizQueueListOut:
    items, total = await crud.list_quiz_queue_items(
        session,
        user.id,
        queue_kind,
        quiz_type=quiz_type,
        limit=limit,
        offset=offset,
        order=order,
    )
    node_ids: set[uuid.UUID] = set()
    for quiz in items:
        if quiz.source_nodes:
            node_ids.update(quiz.source_nodes)
    node_names = await crud.get_node_names(session, node_ids)
    counts = await count_queues(session, user.id)
    _maybe_schedule_refill(background_tasks, user.id, counts)
    return QuizQueueListOut(
        items=[QuizQueueItemOut(**quiz_queue_item_dict(q, node_names)) for q in items],
        total=total,
        queue_kind=queue_kind,
        quiz_type=quiz_type,
    )


@router.delete("/{quiz_id}", response_model=QuizDeleteOut)
async def delete_quiz_item(
    quiz_id: uuid.UUID,
    permanent: bool = Query(False),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizDeleteOut:
    if permanent:
        ok = await crud.delete_quiz_permanent(session, quiz_id, user.id)
        if not ok:
            raise HTTPException(status_code=404, detail="Quiz not found")
        return QuizDeleteOut(id=quiz_id, status="deleted", queue_kind="archived")
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
    quiz_type: Literal["cloze", "scramble", "mcq_nuance", "composition"] = Query(...),
    language: str | None = Query(None, description="Target language for this quiz (overrides profile default)"),
    body: QuizGenerateRequest | None = None,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizGenerateOut:
    if quiz_type not in ENABLED_QUIZ_TYPES:
        raise HTTPException(status_code=410, detail="비활성화된 퀴즈 유형입니다.")
    try:
        if quiz_type == "composition":
            lang = (
                language or getattr(user, "target_language", None) or "english"
            ).strip().lower()
            source_mode = body.source_mode if body else "journal"
            count = body.count if body else 1
            difficulty = (body.difficulty if body else None) or "normal"
            exclude_ids = await crud.get_recent_quiz_seed_node_ids(
                session, user.id, quiz_type="composition", limit=20
            )
            generated = []
            traces = []
            for _ in range(count):
                quiz, trace = await generate_composition_quiz(
                    session,
                    user,
                    language=lang,
                    source_mode=source_mode,
                    exclude_node_ids=exclude_ids,
                    difficulty=difficulty,
                )
                for nid in quiz.source_nodes or []:
                    exclude_ids.add(str(nid))
                generated.append(quiz)
                traces.append(trace)
            quiz = generated[-1]
            trace = traces[-1]
        else:
            quiz, trace = await run_quiz_generate_pipeline(
                session,
                user.id,
                quiz_type,
                selected_vocab_id=body.selected_vocab_id if body else None,
                vocab_node_id=body.vocab_node_id if body else None,
                target_language=language,
            )
    except DrillSeedError as exc:
        raise HTTPException(
            status_code=409, detail={"code": "no_seed", "message": str(exc)}
        ) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return QuizGenerateOut(
        quiz_id=quiz.id,
        quiz_type=quiz.quiz_type,
        difficulty_level=quiz.difficulty_level,
        trace_step_count=len(trace.get("steps") or []),
        generated_count=(body.count if (quiz_type == "composition" and body) else 1),
    )


@router.get("/generations/{quiz_id}/trace", response_model=QuizGenerationTraceOut)
async def get_generation_trace(
    quiz_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
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
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> LearningProfileOut:
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
    )
    if payload.level is not None and payload.level != prev_level:
        await reclassify_queue_by_level(session, user.id, payload.level)

    # NOTE: retroactive extraction is NOT triggered here.
    # Frontend must call POST /vocabularies/statement-bank/reprocess after user confirms.

    return await get_profile(user=user, session=session)


@router.post("/session", response_model=QuizSessionOut)
async def start_session(
    payload: QuizSessionRequest,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
    *,
    background_tasks: BackgroundTasks,
) -> QuizSessionOut:
    quiz_type = validate_quiz_type(payload.quiz_type)
    if quiz_type not in ENABLED_QUIZ_TYPES:
        raise HTTPException(status_code=410, detail="비활성화된 퀴즈 유형입니다.")
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
    counts = await count_queues(session, user.id)
    _maybe_schedule_refill(background_tasks, user.id, counts)
    if picked:
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
        items=[_quiz_out(q) for q in picked],
        quiz_type=quiz_type,
        new_count=new_n,
        review_count=len(picked) - new_n,
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

    submit_payload = payload.model_dump(exclude_none=True)
    tutor_feedback: dict | None = None

    if quiz.quiz_type == "composition":
        user_answer = (submit_payload.get("answer") or "").strip()
        if not user_answer:
            raise HTTPException(status_code=400, detail="answer is required")

        quiz_data = quiz.quiz_data if isinstance(quiz.quiz_data, dict) else {}
        eval_result = await evaluate_attempt_against_reference(
            user,
            prompt=quiz.question_ko or "",
            user_answer=user_answer,
            language=quiz_data.get("language") or "english",
            model_answers=quiz_data.get("model_answers"),
            target_expressions=quiz_data.get("target_expressions"),
            key_expressions=quiz_data.get("key_expressions"),
        )
        tutor_feedback = merge_composition_feedback(quiz_data, eval_result)
        correct, quality = verdict_to_sm2(str(eval_result.get("verdict") or ""))
        await append_tutor_history(
            session,
            user.id,
            quiz_data.get("language") or "english",
            prompt=quiz.question_ko or "",
            user_answer=user_answer,
            feedback=tutor_feedback,
        )
    else:
        correct, quality = grade_answer(quiz, submit_payload)

    quiz = await record_quiz_result(session, quiz, correct=correct, quality=quality)

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

    return QuizSubmitResponse(
        correct=correct,
        quality=quality,
        quiz=_quiz_out(quiz),
        explanation=explanation,
        tutor_feedback=tutor_feedback,
    )


@router.post("/refill")
async def manual_refill(
    user: User = Depends(request_user_dep),
) -> dict:
    return await refill_user_quizzes(user.id)
