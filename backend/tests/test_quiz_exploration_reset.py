from __future__ import annotations

import json

import pytest

from app import crud, node_expression_store
from app.models import Node, QuizGenerationState, QuizSourceExploration
from app.quiz_batch import _source_state
from app.quiz_bundle import CLOZE_GENERATOR_VERSION


@pytest.mark.asyncio
async def test_generator_upgrade_reopens_exhausted_language(db_session, iso_user) -> None:
    node = Node(
        user_id=iso_user.id,
        name="비교 작업",
        type="Statement",
        description=json.dumps({"content": "두 결과를 비교해서 검증했다."}),
    )
    db_session.add(node)
    await db_session.flush()
    db_session.add_all([
        QuizSourceExploration(
            user_id=iso_user.id,
            node_id=node.id,
            language="english",
            cloze_status="unavailable",
            cloze_generator_version="older-contract",
        ),
        QuizGenerationState(
            user_id=iso_user.id,
            language="english",
            status="exhausted",
            source_count=1,
        ),
    ])
    await db_session.commit()

    state = await _source_state(
        db_session,
        iso_user,
        "english",
        [{"node_id": str(node.id), "created_at": None}],
    )

    assert CLOZE_GENERATOR_VERSION != "older-contract"
    assert state.status == "available"


@pytest.mark.asyncio
async def test_archiving_cloze_reopens_its_source_and_language(db_session, iso_user) -> None:
    node = Node(
        user_id=iso_user.id,
        name="검증 작업",
        type="Statement",
        description=json.dumps({"content": "결과를 검증했다."}),
    )
    db_session.add(node)
    await db_session.flush()
    quiz = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="cloze",
        question_ko="빈칸을 완성하세요.",
        sentence_en="I validated the result.",
        quiz_data={"blank": "validated", "prompt_en": "I ___ the result."},
        difficulty_level=20,
        queue_kind="new",
        language="english",
        source_nodes=[node.id],
    )
    exploration = QuizSourceExploration(
        user_id=iso_user.id,
        node_id=node.id,
        language="english",
        cloze_status="generated",
        cloze_generator_version=CLOZE_GENERATOR_VERSION,
    )
    state = QuizGenerationState(
        user_id=iso_user.id,
        language="english",
        status="exhausted",
        source_count=1,
    )
    db_session.add_all([exploration, state])
    await db_session.commit()

    archived = await crud.archive_quiz(db_session, quiz.id, iso_user.id)
    await db_session.refresh(exploration)
    await db_session.refresh(state)

    assert archived is not None and archived.queue_kind == "archived"
    assert exploration.cloze_status == "available"
    assert exploration.cloze_generator_version is None
    assert state.status == "available"


@pytest.mark.asyncio
async def test_full_queue_reset_clears_invisible_unavailable_sources(
    db_session, iso_user, tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(
        node_expression_store,
        "_store_path",
        lambda user_id: tmp_path / f"{user_id}-expressions.json",
    )
    node = Node(
        user_id=iso_user.id,
        name="QA에서 탈락한 소스",
        type="Statement",
        description=json.dumps({"content": "결과를 서로 대조했다."}),
    )
    db_session.add(node)
    await db_session.flush()
    exploration = QuizSourceExploration(
        user_id=iso_user.id,
        node_id=node.id,
        language="german",
        cloze_status="unavailable",
        cloze_generator_version=CLOZE_GENERATOR_VERSION,
    )
    state = QuizGenerationState(
        user_id=iso_user.id,
        language="german",
        status="exhausted",
        source_count=1,
    )
    db_session.add_all([exploration, state])
    await db_session.commit()
    await node_expression_store.save_node_expressions(
        iso_user.id,
        str(node.id),
        "german",
        [{"expression": "Ergebnisse vergleichen", "meaning": "결과를 비교하다"}],
    )
    assert await node_expression_store.is_extracted(
        iso_user.id, str(node.id), "german"
    )

    archived_count = await crud.reset_quiz_queue(db_session, iso_user.id)
    await db_session.refresh(exploration)
    await db_session.refresh(state)

    assert archived_count == 0
    assert exploration.cloze_status == "available"
    assert exploration.cloze_generator_version is None
    assert state.status == "available"
    assert await node_expression_store.get_node_expressions(
        iso_user.id, str(node.id), "german"
    ) == []
    assert not await node_expression_store.is_extracted(
        iso_user.id, str(node.id), "german"
    )
