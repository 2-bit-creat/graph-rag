"""crud.find_statements_by_speaker — Statements this identity actually
SPOKE_OR_PUBLISHED (never ones that merely MENTION it)."""

from __future__ import annotations

import json

import pytest

from app import crud


def _unit_vec(dim: int = 1536, hot: int = 0) -> list[float]:
    v = [0.0] * dim
    v[hot] = 1.0
    return v


def _near(hot: int = 0) -> list[float]:
    v = _unit_vec(hot=hot)
    v[(hot + 1) % len(v)] = 0.05
    return v


async def _stmt(db_session, iso_user, *, name: str, content: str):
    return await crud._get_or_create_node(
        db_session,
        name=name,
        type_="Statement",
        description=json.dumps({"context_type": "회의록", "content": content}),
        user_id=iso_user.id,
    )


@pytest.mark.asyncio
async def test_only_spoke_or_published_statements_returned(db_session, iso_user):
    speaker = await crud._get_or_create_node(
        db_session, name="하승목연구원", type_="Person", user_id=iso_user.id
    )
    other = await crud._get_or_create_node(
        db_session, name="다른화자", type_="Person", user_id=iso_user.id
    )
    spoke = await _stmt(db_session, iso_user, name="발언1", content="내가 한 말")
    mentioned_only = await _stmt(db_session, iso_user, name="발언2", content="언급만 된 문장")
    other_spoke = await _stmt(db_session, iso_user, name="발언3", content="다른 사람 말")

    await crud.create_edge(
        db_session, source_id=speaker.id, target_id=spoke.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    await crud.create_edge(
        db_session, source_id=mentioned_only.id, target_id=speaker.id,
        relation="MENTIONS", user_id=iso_user.id,
    )
    await crud.create_edge(
        db_session, source_id=other.id, target_id=other_spoke.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    await db_session.commit()

    results = await crud.find_statements_by_speaker(db_session, iso_user.id, speaker.id)
    ids = {n.id for n in results}
    assert ids == {spoke.id}


@pytest.mark.asyncio
async def test_deleted_statement_excluded(db_session, iso_user):
    speaker = await crud._get_or_create_node(
        db_session, name="화자", type_="Person", user_id=iso_user.id
    )
    stmt = await _stmt(db_session, iso_user, name="삭제될진술", content="곧 지워짐")
    await crud.create_edge(
        db_session, source_id=speaker.id, target_id=stmt.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    from datetime import UTC, datetime
    stmt.deleted_at = datetime.now(UTC)
    await db_session.commit()

    results = await crud.find_statements_by_speaker(db_session, iso_user.id, speaker.id)
    assert results == []


@pytest.mark.asyncio
async def test_limit_is_respected(db_session, iso_user):
    speaker = await crud._get_or_create_node(
        db_session, name="다변가", type_="Person", user_id=iso_user.id
    )
    for i in range(5):
        stmt = await _stmt(db_session, iso_user, name=f"진술{i}", content=f"내용 {i}")
        await crud.create_edge(
            db_session, source_id=speaker.id, target_id=stmt.id,
            relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
        )
    await db_session.commit()

    results = await crud.find_statements_by_speaker(
        db_session, iso_user.id, speaker.id, limit=2
    )
    assert len(results) == 2


@pytest.mark.asyncio
async def test_query_embedding_orders_by_topical_relevance(db_session, iso_user):
    speaker = await crud._get_or_create_node(
        db_session, name="화자", type_="Person", user_id=iso_user.id
    )
    near = await _stmt(db_session, iso_user, name="관련진술", content="성장성 모형 관련 질문")
    near.name_embedding = _unit_vec(hot=3)
    far = await _stmt(db_session, iso_user, name="무관진술", content="점심 메뉴 얘기")
    far.name_embedding = _unit_vec(hot=9)
    for n in (near, far):
        await crud.create_edge(
            db_session, source_id=speaker.id, target_id=n.id,
            relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
        )
    await db_session.commit()

    results = await crud.find_statements_by_speaker(
        db_session, iso_user.id, speaker.id, query_embedding=_near(hot=3)
    )
    assert results[0].id == near.id
