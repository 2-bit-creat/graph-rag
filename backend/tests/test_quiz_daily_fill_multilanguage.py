from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from sqlalchemy import func, select

from app import crud, quiz_batch
from app.models import Node, Quiz


@pytest.mark.asyncio
async def test_daily_fill_explores_every_source_for_each_language(
    db_session, iso_user, monkeypatch
) -> None:
    iso_user.target_languages = ["english", "german"]
    # One slot per Statement. The daily goal is an inventory target and
    # ``fill_daily_batch`` stops at the deficit, so a target below the source
    # count would cap the fill before the last source ever contributes — and the
    # assertions below would be measuring the cap, not per-language coverage.
    iso_user.daily_cloze_target = 3
    iso_user.daily_composition_target = 1
    for index in range(3):
        db_session.add(Node(
            user_id=iso_user.id,
            name=f"statement-{index}",
            type="Statement",
            description=json.dumps({"content": f"결과 {index}을 비교하고 검증했다."}),
        ))
    await db_session.commit()

    calls: list[tuple[str, str]] = []

    async def fake_material(session, user, *, node_id, language, **kwargs):
        calls.append((language, str(node_id)))
        composition = await crud.create_quiz(
            session,
            user_id=user.id,
            quiz_type="composition",
            question_ko=f"{language}-{node_id}-composition",
            quiz_data={"language": language},
            difficulty_level=20,
            queue_kind="new",
            language=language,
            source_nodes=[node_id],
        )
        return SimpleNamespace(expression_count=1), [composition], {"steps": []}

    async def fake_materialize(session, user, *, node_id, language, **kwargs):
        cloze = await crud.create_quiz(
            session,
            user_id=user.id,
            quiz_type="cloze",
            question_ko=f"{language}-{node_id}-cloze",
            sentence_en="I compared the result.",
            quiz_data={"language": language, "blank": "compared", "prompt_en": "I ___ the result."},
            difficulty_level=20,
            queue_kind="new",
            language=language,
            source_nodes=[node_id],
        )
        return [cloze], {"steps": []}

    monkeypatch.setattr(quiz_batch, "ensure_learning_material", fake_material)
    monkeypatch.setattr(quiz_batch, "materialize_node_expressions", fake_materialize)

    result = await quiz_batch.fill_user_daily_batches(db_session, iso_user)

    assert len([call for call in calls if call[0] == "english"]) == 3
    assert len([call for call in calls if call[0] == "german"]) == 3
    assert result["english"]["cloze"] == 3
    assert result["german"]["cloze"] == 3
    rows = (await db_session.execute(
        select(Quiz.language, Quiz.quiz_type, func.count())
        .where(Quiz.user_id == iso_user.id, Quiz.queue_kind == "new")
        .group_by(Quiz.language, Quiz.quiz_type)
    )).all()
    counts = {(language, quiz_type): count for language, quiz_type, count in rows}
    assert counts[("english", "cloze")] == 3
    assert counts[("german", "cloze")] == 3
