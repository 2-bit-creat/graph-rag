"""Deleting an expression deletes the quizzes it produced.

A cloze card *is* its expression (quiz_data.canonical_form). Leaving the card
behind after the learner removed the word means the deletion visibly did
nothing — the same word keeps being asked. Composition cards drill a whole
Statement, so they must survive.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app import crud
from app.models import Quiz
from app.node_expression_store import (
    get_node_expressions,
    save_node_expressions,
)
from app.routers.graph import delete_node_expressions
from app.schemas import NodeExpressionDeleteItem, NodeExpressionDeleteRequest


async def _statement_with_expression_and_quizzes(db_session, user_id):
    stmt = await crud._get_or_create_node(
        db_session, name="수영장에 갔다", type_="Statement", user_id=user_id
    )
    await db_session.commit()
    await save_node_expressions(
        user_id,
        str(stmt.id),
        "german",
        [
            {"expression": "gut sein", "meaning_ko": "좋다"},
            {"expression": "ins Schwimmbad gehen", "meaning_ko": "수영장에 가다"},
        ],
        node_name=stmt.name,
    )
    for canonical in ("gut sein", "ins Schwimmbad gehen"):
        await crud.create_quiz(
            db_session,
            user_id=user_id,
            quiz_type="cloze",
            question_ko="빈칸을 채우세요",
            sentence_en="___",
            quiz_data={"canonical_form": canonical},
            language="german",
            source_nodes=[stmt.id],
        )
    await crud.create_quiz(
        db_session,
        user_id=user_id,
        quiz_type="composition",
        question_ko="문장을 써보세요",
        sentence_en=None,
        quiz_data={"source_label": "진술 노드"},
        language="german",
        source_nodes=[stmt.id],
    )
    await db_session.commit()
    return stmt


@pytest.mark.asyncio
async def test_deleting_an_expression_removes_its_cloze_only(db_session, iso_user):
    stmt = await _statement_with_expression_and_quizzes(db_session, iso_user.id)

    out = await delete_node_expressions(
        stmt.id,
        NodeExpressionDeleteRequest(
            items=[NodeExpressionDeleteItem(language="german", expression="gut sein")]
        ),
        iso_user,
        db_session,
    )

    assert out["removed_count"] == 1
    assert out["quizzes_deleted"] == 1

    remaining = await get_node_expressions(iso_user.id, str(stmt.id), "german")
    assert [item["expression"] for item in remaining] == ["ins schwimmbad gehen"]

    quizzes = list((await db_session.execute(
        select(Quiz).where(Quiz.user_id == iso_user.id)
    )).scalars())
    survivors = sorted(
        (q.quiz_type, (q.quiz_data or {}).get("canonical_form") or "") for q in quizzes
    )
    assert survivors == [
        ("cloze", "ins Schwimmbad gehen"),
        ("composition", ""),
    ]


@pytest.mark.asyncio
async def test_deleting_several_expressions_at_once(db_session, iso_user):
    stmt = await _statement_with_expression_and_quizzes(db_session, iso_user.id)

    out = await delete_node_expressions(
        stmt.id,
        NodeExpressionDeleteRequest(
            items=[
                NodeExpressionDeleteItem(language="german", expression="gut sein"),
                NodeExpressionDeleteItem(
                    language="german", expression="ins Schwimmbad gehen"
                ),
            ]
        ),
        iso_user,
        db_session,
    )

    assert out["removed_count"] == 2
    assert out["quizzes_deleted"] == 2
    assert await get_node_expressions(iso_user.id, str(stmt.id), "german") == []


@pytest.mark.asyncio
async def test_deleting_an_unknown_expression_is_a_no_op(db_session, iso_user):
    stmt = await _statement_with_expression_and_quizzes(db_session, iso_user.id)

    out = await delete_node_expressions(
        stmt.id,
        NodeExpressionDeleteRequest(
            items=[NodeExpressionDeleteItem(language="german", expression="nicht da")]
        ),
        iso_user,
        db_session,
    )

    assert out["removed_count"] == 0
    assert out["quizzes_deleted"] == 0
    assert len(await get_node_expressions(iso_user.id, str(stmt.id), "german")) == 2
