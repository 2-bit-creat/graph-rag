"""Regression tests for the quiz refocus (4-type bundle, graph seeds, FIFO)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi import HTTPException

from app import crud
from app.models import Quiz
from app.quiz_queue import build_session
from app.quiz_types import ENABLED_QUIZ_TYPES, ensure_quiz_type_enabled
from app.routers.quiz import generate_quiz_graph
from app.schemas import QuizGenerateRequest
from app.tutor import DrillSeedError, generate_drill


def test_all_quiz_types_enabled():
    assert ENABLED_QUIZ_TYPES == frozenset(
        {"cloze", "composition"}
    )


def test_ensure_quiz_type_enabled_rejects_unknown():
    with pytest.raises(ValueError, match="Disabled"):
        ensure_quiz_type_enabled("bogus_type")


@pytest.mark.asyncio
async def test_generate_composition_without_journal_seed_returns_409(
    db_session, iso_user
):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    with pytest.raises(HTTPException) as exc:
        await generate_quiz_graph(
            quiz_type="composition",
            language="english",
            body=QuizGenerateRequest(),
            user=iso_user,
            session=db_session,
        )
    assert exc.value.status_code == 409
    assert exc.value.detail["code"] == "no_seed"


@pytest.mark.asyncio
async def test_generate_drill_raises_drill_seed_error_without_journal(db_session, iso_user):
    await crud.clear_user_knowledge_graph(db_session, iso_user.id)
    with pytest.raises(DrillSeedError):
        await generate_drill(db_session, iso_user, language="english", source_mode="journal")


@pytest.mark.asyncio
async def test_build_session_new_queue_is_fifo(db_session, iso_user):
    base = datetime.now(UTC)
    ids: list[uuid.UUID] = []
    for i, label in enumerate(["first", "second", "third"]):
        quiz = Quiz(
            user_id=iso_user.id,
            quiz_type="composition",
            queue_kind="new",
            repetitions=0,
            difficulty_level=iso_user.current_level,
            question_ko=label,
            language="english",
            quiz_data={"language": "english"},
            created_at=base + timedelta(seconds=i),
        )
        db_session.add(quiz)
        await db_session.flush()
        ids.append(quiz.id)
    await db_session.commit()

    picked = await build_session(
        db_session, iso_user.id, "composition", size=3, language="english"
    )
    new_only = [q for q in picked if q.queue_kind == "new"]
    assert [q.question_ko for q in new_only] == ["first", "second", "third"]


@pytest.mark.asyncio
async def test_build_session_filters_by_language(db_session, iso_user):
    """A German quiz must not surface in an English session (per-language queues)."""
    for lang in ("english", "german"):
        db_session.add(
            Quiz(
                user_id=iso_user.id,
                quiz_type="cloze",
                queue_kind="new",
                repetitions=0,
                difficulty_level=iso_user.current_level,
                question_ko=f"{lang} item",
                language=lang,
                quiz_data={"language": lang},
            )
        )
    await db_session.commit()

    english = await build_session(
        db_session, iso_user.id, "cloze", size=10, language="english"
    )
    assert english, "expected the english cloze to be served"
    assert all((q.language or q.quiz_data.get("language")) == "english" for q in english)
