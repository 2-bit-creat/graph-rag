"""Composition tutor as a first-class quiz type.

This module stores pre-generated composition drills in the canonical ``quizzes``
table. The expensive, answer-independent part (prompt, hints, model answers,
key expressions) is generated ahead of time; per-attempt coaching happens later
on submit.
"""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .models import Quiz, User
from .pipeline_trace import PipelineTracer
from .tutor import SourceMode, generate_drill


def _source_nodes(drill: dict[str, Any]) -> list[uuid.UUID] | None:
    node_id = drill.get("seed_node_id")
    if not node_id:
        return None
    try:
        return [uuid.UUID(str(node_id))]
    except (TypeError, ValueError):
        return None


async def generate_composition_quiz(
    session: AsyncSession,
    user: User,
    *,
    language: str,
    source_mode: SourceMode = "journal",
    exclude_node_ids: set[str] | None = None,
    seed_node_ids: set[str] | None = None,
    difficulty: str = "normal",
) -> tuple[Quiz, dict]:
    """Generate one queued composition quiz and return (quiz, trace).

    ``exclude_node_ids`` keeps recently-used journal seeds out of rotation;
    ``difficulty`` (easy/normal/hard) shifts the prompt-level language scope
    while the row keeps the learner's base level (queue stays drainable).
    """
    trace_id = uuid.uuid4()
    tracer = PipelineTracer(trace_id)
    tracer.run.current_phase = "quiz_path"
    tracer.run.status = "quiz_path"

    step = tracer.begin_step(
        "composition_seed_select",
        "graph",
        phase="quiz_path",
        input_data={
            "language": language,
            "source_mode": source_mode,
        },
    )
    tracer.finish_step(
        step,
        output={
            "source_mode": source_mode,
            "note": "Seed is selected inside generate_drill and recorded in the generated payload.",
        },
    )

    step = tracer.begin_step(
        "composition_drill_llm_generate",
        "llm",
        phase="quiz_path",
        input_data={
            "language": language,
            "source_mode": source_mode,
        },
    )
    drill = await generate_drill(
        session,
        user,
        language=language,
        source_mode=source_mode,
        exclude_node_ids=exclude_node_ids,
        seed_node_ids=seed_node_ids,
        difficulty=difficulty,
    )
    tracer.finish_step(
        step,
        output={
            "prompt": drill.get("prompt"),
            "source_mode": drill.get("source_mode"),
            "source_label": drill.get("source_label"),
            "seed_node_id": drill.get("seed_node_id"),
            "target_expression_count": len(drill.get("target_expressions") or []),
            "model_answer_count": len(drill.get("model_answers") or []),
        },
        artifacts=[("composition_drill.json", drill, "application/json")],
    )

    quiz_data = {
        "language": drill.get("language") or language,
        "source_mode": drill.get("source_mode") or source_mode,
        "source_label": drill.get("source_label") or "",
        "target_expressions": drill.get("target_expressions") or [],
        "glossary": drill.get("glossary") or [],
        "hints": drill.get("hints") or [],
        "model_answers": drill.get("model_answers") or [],
        "key_expressions": drill.get("key_expressions") or [],
        "thinking_tip": drill.get("thinking_tip") or "",
        "cefr": drill.get("cefr") or "",
        "difficulty": drill.get("difficulty") or "normal",
        "style": drill.get("style") or {},
    }

    step = tracer.begin_step(
        "composition_quiz_persist",
        "storage",
        phase="quiz_path",
        input_data={
            "quiz_type": "composition",
            "queue_kind": "new",
        },
    )
    trace = tracer.checkpoint()
    quiz = await crud.create_quiz(
        session,
        user_id=user.id,
        quiz_type="composition",
        question_ko=drill.get("prompt") or "",
        quiz_data=quiz_data,
        # Base (unshifted) level: keeps hard/easy drills inside the session
        # level-window filter so the queue stays drainable.
        difficulty_level=int(drill.get("base_level") or user.current_level or 10),
        queue_kind="new",
        source_nodes=_source_nodes(drill),
        pipeline_trace=trace,
        debug_run_dir=tracer.debug_dir_relative,
    )
    tracer.finish_step(
        step,
        output={
            "quiz_id": str(quiz.id),
            "difficulty_level": quiz.difficulty_level,
            "language": quiz_data["language"],
        },
    )
    trace = tracer.finish(status="completed")
    quiz.pipeline_trace = trace
    await session.commit()
    await session.refresh(quiz)
    return quiz, trace


def verdict_to_sm2(verdict: str, quality: int | None = None) -> tuple[bool, int]:
    """Map a composition evaluation to SM-2 while retaining the full 1-5 score."""
    if quality is not None:
        score = max(1, min(5, int(quality)))
        return score >= 3, score
    v = (verdict or "").strip().lower()
    if v == "natural":
        return True, 5
    if v == "understandable":
        return True, 4
    if v == "awkward":
        return False, 2
    return False, 1


def merge_composition_feedback(
    quiz_data: dict[str, Any], eval_result: dict[str, Any]
) -> dict[str, Any]:
    """Merge pre-generated drill content with attempt-specific coaching."""
    return {
        "verdict": eval_result.get("verdict", "understandable"),
        "quality": eval_result.get("quality", 3),
        "verdict_label": eval_result.get("verdict_label", ""),
        "encouragement": eval_result.get("encouragement", ""),
        "natural_versions": quiz_data.get("model_answers") or [],
        "key_expressions": quiz_data.get("key_expressions") or [],
        "thinking_tip": quiz_data.get("thinking_tip") or "",
        "save_suggestions": eval_result.get("save_suggestions") or [],
        "attempt_note": eval_result.get("attempt_note") or "",
        "corrections": eval_result.get("corrections") or [],
        "language": quiz_data.get("language") or eval_result.get("language") or "english",
    }
