from __future__ import annotations

import uuid

import pytest

from app import crud
from app.quiz_generation_runs import create_generation_run


@pytest.mark.asyncio
async def test_generation_run_builds_node_language_cartesian_product(
    db_session, iso_user
) -> None:
    iso_user.target_languages = ["english", "german"]
    first = await crud._get_or_create_node(
        db_session,
        name=f"run-first-{uuid.uuid4()}",
        type_="Statement",
        description='{"content":"첫 번째 테스트 문장은 충분히 길다."}',
        user_id=iso_user.id,
    )
    second = await crud._get_or_create_node(
        db_session,
        name=f"run-second-{uuid.uuid4()}",
        type_="Statement",
        description='{"content":"두 번째 테스트 문장도 충분히 길다."}',
        user_id=iso_user.id,
    )
    await db_session.commit()

    run, created = await create_generation_run(
        db_session,
        iso_user,
        node_ids=[first.id, second.id],
        languages=["english", "german"],
        idempotency_key=f"test-{uuid.uuid4()}",
    )

    assert created is True
    assert run.total_count == 4
    assert {
        (item["node_id"], item["language"]) for item in run.items
    } == {
        (str(first.id), "english"),
        (str(first.id), "german"),
        (str(second.id), "english"),
        (str(second.id), "german"),
    }
    assert all(item["status"] == "queued" for item in run.items)


@pytest.mark.asyncio
async def test_generation_run_is_idempotent(db_session, iso_user) -> None:
    node = await crud._get_or_create_node(
        db_session,
        name=f"run-idempotent-{uuid.uuid4()}",
        type_="Statement",
        description='{"content":"중복 요청 검증을 위한 충분히 긴 문장이다."}',
        user_id=iso_user.id,
    )
    await db_session.commit()
    key = f"test-{uuid.uuid4()}"

    first, first_created = await create_generation_run(
        db_session,
        iso_user,
        node_ids=[node.id],
        languages=["english"],
        idempotency_key=key,
    )
    second, second_created = await create_generation_run(
        db_session,
        iso_user,
        node_ids=[node.id],
        languages=["english"],
        idempotency_key=key,
    )

    assert first_created is True
    assert second_created is False
    assert second.id == first.id


@pytest.mark.asyncio
async def test_generation_run_rejects_inactive_language(
    db_session, iso_user
) -> None:
    iso_user.target_languages = ["english"]
    node = await crud._get_or_create_node(
        db_session,
        name=f"run-language-{uuid.uuid4()}",
        type_="Statement",
        description='{"content":"비활성 언어 요청 검증을 위한 문장이다."}',
        user_id=iso_user.id,
    )
    await db_session.commit()

    with pytest.raises(ValueError, match="비활성 Target 언어"):
        await create_generation_run(
            db_session,
            iso_user,
            node_ids=[node.id],
            languages=["german"],
            idempotency_key=f"test-{uuid.uuid4()}",
        )
