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
from ..quiz_bundle import BundleSeedError, generate_quiz_bundle
from ..quiz_pipeline import (
    trace_quiz_queue_pick,
    trace_quiz_sm2_update,
)
from ..quiz_presenter import quiz_queue_item_dict
from ..quiz_queue import build_session, count_queues, grade_answer, pick_quizzes_by_ids, record_quiz_result
from ..quiz_batch import create_extra_daily_batch, fill_user_daily_batches
from ..quiz_audio_engine import resolve_quiz_tts_text, synthesize_quiz_audio
from ..quiz_settings import quiz_selection_settings
from ..quiz_types import ENABLED_QUIZ_TYPES, validate_quiz_type
from ..tutor import DrillSeedError, evaluate_attempt_against_reference
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
    QuizExplorationListOut,
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
        session, user.id, target_languages
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
        daily_composition_target=user.daily_composition_target,
        quiz_review_ratio=user.quiz_review_ratio,
        daily_progress_by_language=daily_progress,
    )


async def _ensure_cloze_audio(session: AsyncSession, quizzes: list) -> None:
    """Backfill TTS for legacy bundle quizzes that were created without audio."""
    changed = False
    for quiz in quizzes:
        if quiz.quiz_type != "cloze":
            continue
        qd = dict(quiz.quiz_data or {})
        if qd.get("audio_url"):
            continue
        text = resolve_quiz_tts_text(
            "cloze", {"sentence_en": quiz.sentence_en, "quiz_data": qd}
        )
        audio_url, _ = await synthesize_quiz_audio(
            quiz.id,
            text,
            language=quiz.language or qd.get("language") or "english",
        )
        if audio_url:
            qd["audio_url"] = audio_url
            quiz.quiz_data = qd
            changed = True
    if changed:
        await session.commit()


@router.get("/queue/items", response_model=QuizQueueListOut)
async def list_queue_items(
    queue_kind: Literal["new", "review"] = Query(...),
    quiz_type: Literal["cloze", "composition"] | None = None,
    track: Literal["daily", "pinned"] | None = None,
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
        track=track,
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


@router.get("/queue/explorations", response_model=QuizExplorationListOut)
async def list_queue_explorations(
    language: str | None = Query(None),
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
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
                    "expression_count": 0,
                    "composition_count": 0,
                    "updated_at": None,
                    "language_stats": [],
                },
            )
            item["language_stats"].append({
                "language": lang,
                "status": row["status"],
                "cloze_status": row["cloze_status"],
                "generated_counts": {
                    "cloze": row["word_count"],
                    "composition": row["composition_count"],
                },
                "word_count": row["word_count"],
                "expression_count": row["expression_count"],
                "composition_count": row["composition_count"],
                "updated_at": row["updated_at"],
            })
            item["word_count"] += row["word_count"]
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


@router.delete("/queue/reset")
async def reset_quiz_queue(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    archived = await crud.reset_quiz_queue(session, user.id)
    return {"status": "reset", "archived": archived}


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


@router.get("/history", response_model=QuizQueueListOut)
async def list_quiz_history(
    quiz_type: Literal["cloze", "composition"] | None = None,
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
    quiz_type: Literal["cloze", "composition"] = Query(...),
    language: str | None = Query(None, description="Target language for this quiz (overrides profile default)"),
    body: QuizGenerateRequest | None = None,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
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
    # Whitelist: learn English/German/Korean; explanations in Korean or English.
    allowed_targets = {"english", "german", "korean"}
    allowed_natives = {"korean", "english"}
    if payload.target_languages is not None:
        bad = {l.lower() for l in payload.target_languages} - allowed_targets
        if bad:
            raise HTTPException(
                status_code=400,
                detail={"code": "unsupported_target", "languages": sorted(bad)},
            )
    if payload.target_language is not None and payload.target_language.lower() not in allowed_targets:
        raise HTTPException(
            status_code=400,
            detail={"code": "unsupported_target", "languages": [payload.target_language]},
        )
    if payload.native_language is not None and payload.native_language.lower() not in allowed_natives:
        raise HTTPException(
            status_code=400,
            detail={"code": "unsupported_native", "language": payload.native_language},
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
        daily_composition_target=payload.daily_composition_target,
        quiz_review_ratio=payload.quiz_review_ratio,
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
) -> QuizSessionOut:
    # The chat's legacy "word" alias now means the single supported word quiz.
    if payload.quiz_type == "word":
        payload = payload.model_copy(update={"quiz_type": "cloze"})

    # "word" fans out into a single mixed session over the three word types so
    # the chat "단어 퀴즈" serves cloze/scramble/mcq_nuance interleaved.
    if payload.quiz_type == "word":
        quiz_type = "word"
        merged: list = []
        for wt in ("cloze",):
            merged.extend(
                await build_session(
                    session,
                    user.id,
                    wt,
                    size=payload.size,
                    vocab_source=payload.vocab_source,
                    language=payload.language,
                )
            )
        # Round-robin by type so the learner doesn't get all clozes first.
        by_type: dict[str, list] = {}
        for q in merged:
            by_type.setdefault(q.quiz_type, []).append(q)
        picked = []
        while by_type and len(picked) < payload.size:
            for wt in list(by_type.keys()):
                if by_type[wt]:
                    picked.append(by_type[wt].pop(0))
                    if len(picked) >= payload.size:
                        break
                if not by_type[wt]:
                    by_type.pop(wt, None)
    else:
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
    if picked:
        await _ensure_cloze_audio(session, picked)
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

    if quiz.quiz_type == "composition":
        qd = quiz.quiz_data or {}
        eval_result = await evaluate_attempt_against_reference(
            user,
            prompt=quiz.question_ko or qd.get("prompt") or "",
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
        quiz = await record_quiz_result(session, quiz, correct=correct, quality=quality)
        await trace_quiz_sm2_update(
            session, quiz_id, user.id, quiz, correct=correct, quality=quality,
        )
        return QuizSubmitResponse(
            correct=correct,
            quality=quality,
            quiz=_quiz_out(quiz),
            explanation=None,
            tutor_feedback=merge_composition_feedback(qd, eval_result),
        )

    submit_payload = payload.model_dump(exclude_none=True)
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
    )


@router.post("/refill")
async def manual_refill(
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
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
) -> dict:
    lang = (language or crud.get_effective_target_languages(user)[0]).lower()
    return await create_extra_daily_batch(session, user, language=lang)
