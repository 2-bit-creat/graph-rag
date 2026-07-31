from __future__ import annotations

import json
import uuid

import pytest

from app import crud, json_doc_store, node_expression_store
from app.models import Node, QuizLearningMaterial
from app.quiz_materials import get_or_mark_material, source_hash


@pytest.mark.asyncio
async def test_statement_change_retires_old_quizzes_and_expressions(
    db_session, iso_user, tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(
        json_doc_store,
        "_local_path",
        lambda user_id, filename: tmp_path / f"{user_id}-{filename}",
    )
    old_content = "기존 진술 내용으로 학습 문제를 만들었다."
    new_content = "수정된 진술 내용으로 새로운 학습 문제를 만든다."
    node = Node(
        user_id=iso_user.id,
        name=f"changed-{uuid.uuid4()}",
        type="Statement",
        description=json.dumps({"content": old_content}, ensure_ascii=False),
    )
    db_session.add(node)
    await db_session.flush()
    material = QuizLearningMaterial(
        user_id=iso_user.id,
        node_id=node.id,
        language="english",
        source_hash=source_hash(old_content),
        status="ready",
        composition_count=1,
        expression_count=1,
    )
    db_session.add(material)
    composition = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="composition",
        question_ko=old_content,
        sentence_en=None,
        quiz_data={"model_answers": [{"text": "Old answer"}]},
        language="english",
        source_nodes=[node.id],
        generation_key=f"old-{uuid.uuid4()}",
    )
    cloze = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="cloze",
        question_ko="빈칸을 채우세요.",
        sentence_en="This is the old expression.",
        quiz_data={"canonical_form": "old expression"},
        language="english",
        source_nodes=[node.id],
        generation_key=f"old-{uuid.uuid4()}",
    )
    await db_session.commit()
    await node_expression_store.save_node_expressions(
        iso_user.id,
        str(node.id),
        "english",
        [{"expression": "old expression", "meaning": "기존 표현"}],
    )

    node.description = json.dumps({"content": new_content}, ensure_ascii=False)
    await db_session.commit()

    refreshed = await get_or_mark_material(
        db_session,
        iso_user,
        node_id=node.id,
        language="english",
    )
    await db_session.commit()
    await db_session.refresh(composition)
    await db_session.refresh(cloze)

    assert refreshed.status == "stale"
    assert refreshed.source_hash == source_hash(new_content)
    assert refreshed.composition_count == 0
    assert refreshed.expression_count == 0
    assert composition.queue_kind == "archived"
    assert cloze.queue_kind == "archived"
    assert composition.generation_key is None
    assert cloze.generation_key is None
    assert await node_expression_store.get_node_expressions(
        iso_user.id, str(node.id), "english"
    ) == []
