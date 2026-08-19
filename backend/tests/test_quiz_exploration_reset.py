from __future__ import annotations

import json

import pytest

from app import crud, json_doc_store, node_expression_store
from app.models import (
    Node,
    Quiz,
    QuizGenerationState,
    QuizLearningMaterial,
    QuizSourceExploration,
)
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
    # node_expression_store persists through json_doc_store now; redirect its
    # local-file branch rather than the store's own (removed) path helper.
    monkeypatch.setattr(
        json_doc_store,
        "_local_path",
        lambda user_id, filename: tmp_path / f"{user_id}-{filename}",
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
    material = QuizLearningMaterial(
        user_id=iso_user.id,
        node_id=node.id,
        language="german",
        source_hash="old-hash",
        status="ready",
        composition_count=2,
        expression_count=3,
        expansion_count=1,
        result={"old": True},
    )
    db_session.add_all([exploration, state, material])
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
    await db_session.refresh(material)

    assert archived_count == 0
    assert exploration.cloze_status == "available"
    assert exploration.cloze_generator_version is None
    assert state.status == "available"
    assert material.status == "pending"
    assert material.composition_count == 0
    assert material.expression_count == 0
    assert material.expansion_count == 0
    assert material.result is None
    assert await node_expression_store.get_node_expressions(
        iso_user.id, str(node.id), "german"
    ) == []
    assert not await node_expression_store.is_extracted(
        iso_user.id, str(node.id), "german"
    )


@pytest.mark.asyncio
async def test_exploration_counts_reflect_archived_quizzes_not_a_stale_cache(
    db_session, iso_user
) -> None:
    """Regression: a node whose quiz was archived by a path that didn't also
    zero QuizLearningMaterial.composition_count / QuizSourceExploration.word_count
    (any archiving that isn't reset_node_materials's own supersede step) kept
    showing "배열 1개 · 작문 1개" on the node-exploration screen forever, even
    though the queue-management list correctly showed 0 active quizzes. The
    counters are caches that can desync from the one place that can't drift —
    the quizzes table's own queue_kind — so the exploration list must read
    that directly instead of trusting them.
    """
    node = Node(
        user_id=iso_user.id,
        name="스프레드시트 정리",
        type="Statement",
        description=json.dumps({"content": "스프레드시트를 정리했다."}),
    )
    db_session.add(node)
    await db_session.flush()

    # A cache that disagrees with reality: the columns say 1/1, but every
    # actual quiz row for this node is archived.
    db_session.add(
        QuizLearningMaterial(
            user_id=iso_user.id,
            node_id=node.id,
            language="korean",
            source_hash="stale-hash",
            status="ready",
            composition_count=1,
            expression_count=2,
        )
    )
    db_session.add(
        Quiz(
            user_id=iso_user.id,
            quiz_type="composition",
            language="korean",
            queue_kind="archived",
            source_nodes=[node.id],
            quiz_data={},
        )
    )
    # A live, non-archived scramble for the SAME node must still be counted —
    # this isn't "always report zero", it's "report what's actually active".
    db_session.add(
        Quiz(
            user_id=iso_user.id,
            quiz_type="scramble",
            language="korean",
            queue_kind="new",
            source_nodes=[node.id],
            quiz_data={"chunks": [{"id": "t0", "text": "정리"}], "correct_order": ["t0"]},
        )
    )
    await db_session.flush()

    rows = await crud.list_quiz_source_explorations(db_session, iso_user.id, language="korean")
    row = next(r for r in rows if r["node_id"] == node.id)

    assert row["composition_count"] == 0
    assert row["word_count"] == 1
    # Expression count is untouched by this fix — still the cached column.
    assert row["expression_count"] == 2
