"""Editing a Statement archives its learning material and hands the decision to
rebuild back to the learner.

The old pin flow generated on demand for a node the learner wanted to study.
Generation is now automatic at creation time, so the only remaining hole is an
*edited* Statement: its quizzes and expressions describe text that no longer
exists.  Those are archived the moment the edit lands, and the graph surface
turns that state into an enabled 재생성 button — disabled while nothing changed.
"""

from __future__ import annotations

import json
import uuid

import pytest
from fastapi import BackgroundTasks

from app import crud, json_doc_store, node_expression_store
from app.models import Node, QuizLearningMaterial
from app.quiz_materials import source_hash
from app.routers.graph import edit_node, read_node_study_quizzes
from app.schemas import NodeUpdate


async def _statement_with_material(db_session, user, tmp_path, monkeypatch, content):
    monkeypatch.setattr(
        json_doc_store,
        "_local_path",
        lambda user_id, filename: tmp_path / f"{user_id}-{filename}",
    )
    node = Node(
        user_id=user.id,
        name=f"edited-{uuid.uuid4()}",
        type="Statement",
        description=json.dumps({"content": content}, ensure_ascii=False),
    )
    db_session.add(node)
    await db_session.flush()
    db_session.add(
        QuizLearningMaterial(
            user_id=user.id,
            node_id=node.id,
            language="english",
            source_hash=source_hash(content),
            status="ready",
            composition_count=1,
            expression_count=1,
        )
    )
    quiz = await crud.create_quiz(
        db_session,
        user_id=user.id,
        quiz_type="composition",
        question_ko=content,
        sentence_en=None,
        quiz_data={"model_answers": [{"text": "Old answer"}]},
        language="english",
        source_nodes=[node.id],
        generation_key=f"old-{uuid.uuid4()}",
    )
    await db_session.commit()
    await node_expression_store.save_node_expressions(
        user.id,
        str(node.id),
        "english",
        [{"expression": "old expression", "meaning": "기존 표현"}],
    )
    return node, quiz


@pytest.mark.asyncio
async def test_editing_statement_archives_material_and_enables_regeneration(
    db_session, iso_user, tmp_path, monkeypatch
) -> None:
    node, quiz = await _statement_with_material(
        db_session, iso_user, tmp_path, monkeypatch, "기존 진술 내용으로 학습 문제를 만들었다."
    )

    await edit_node(
        node.id,
        NodeUpdate(
            description=json.dumps(
                {"content": "수정된 진술 내용이라 기존 문제는 더 이상 맞지 않는다."},
                ensure_ascii=False,
            )
        ),
        iso_user,
        db_session,
    )
    await db_session.refresh(quiz)

    assert quiz.queue_kind == "archived"
    assert await node_expression_store.get_node_expressions(
        iso_user.id, str(node.id), "english"
    ) == []

    result = await read_node_study_quizzes(
        node.id, BackgroundTasks(), iso_user, db_session
    )
    assert result["needs_regeneration"] is True
    assert result["word"]["count"] == 0
    assert result["composition"]["count"] == 0


@pytest.mark.asyncio
async def test_unedited_statement_leaves_regeneration_disabled(
    db_session, iso_user, tmp_path, monkeypatch
) -> None:
    node, quiz = await _statement_with_material(
        db_session, iso_user, tmp_path, monkeypatch, "그대로 둔 진술 내용은 문제를 유지한다."
    )

    # A no-op PATCH (same values) must not retire anything.
    await edit_node(
        node.id,
        NodeUpdate(name=node.name, description=node.description),
        iso_user,
        db_session,
    )
    await db_session.refresh(quiz)

    assert quiz.queue_kind != "archived"
    result = await read_node_study_quizzes(
        node.id, BackgroundTasks(), iso_user, db_session
    )
    assert result["needs_regeneration"] is False
    assert result["composition"]["count"] == 1
