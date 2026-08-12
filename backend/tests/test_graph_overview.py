"""Meta questions about the graph must be answerable.

"내 그래프에 뭐가 있어?" is one of the two suggestion chips a brand-new chat
offers, and it used to answer "그래프에 대한 기억은 없는데…" every single time:
a question about the collection is similar to no memory in it, so every
embedding retriever returned nothing and the prompt fell back to its
no-context placeholder. These aggregates are what answers it instead.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timezone

import pytest

from app.graph_overview import build_graph_overview, safe_graph_overview
from app.graph_schema import REL_CONTEXT, REL_SPOKE_OR_PUBLISHED
from app.models import Edge, Node
from app.query_planner import SearchPlan


def _node(user_id, name, node_type, **kw) -> Node:
    return Node(
        id=uuid.uuid4(), user_id=user_id, name=name, type=node_type,
        created_at=datetime.now(timezone.utc), **kw
    )


def _edge(user_id, source, target, relation) -> Edge:
    return Edge(
        id=uuid.uuid4(), user_id=user_id,
        source_id=source.id, target_id=target.id, relation=relation,
    )


@pytest.fixture
async def seeded(db_session, iso_user):
    """Two statements from 나, one from 제니, sharing one popular concept."""
    me = _node(iso_user.id, "나", "Person")
    jenny = _node(iso_user.id, "제니", "Person")
    interview = _node(iso_user.id, "면접", "Concept")
    dinner = _node(iso_user.id, "저녁", "Concept")
    s1 = _node(iso_user.id, "면접 준비", "Statement", occurred_at=date(2026, 1, 5))
    s2 = _node(iso_user.id, "면접 후기", "Statement", occurred_at=date(2026, 3, 9))
    s3 = _node(iso_user.id, "저녁 약속", "Statement", occurred_at=date(2026, 2, 1))
    db_session.add_all([me, jenny, interview, dinner, s1, s2, s3])
    await db_session.flush()
    db_session.add_all([
        _edge(iso_user.id, me, s1, REL_SPOKE_OR_PUBLISHED),
        _edge(iso_user.id, me, s2, REL_SPOKE_OR_PUBLISHED),
        _edge(iso_user.id, jenny, s3, REL_SPOKE_OR_PUBLISHED),
        _edge(iso_user.id, s1, interview, REL_CONTEXT),
        _edge(iso_user.id, s2, interview, REL_CONTEXT),
        _edge(iso_user.id, s3, dinner, REL_CONTEXT),
    ])
    await db_session.flush()
    return {"me": me, "jenny": jenny, "interview": interview, "s1": s1, "s3": s3}


@pytest.mark.asyncio
async def test_overview_answers_what_is_in_my_graph(db_session, iso_user, seeded) -> None:
    text = await build_graph_overview(db_session, iso_user.id)
    assert text, "an empty summary is the bug this exists to fix"
    assert "전체 노드 7개" in text
    assert "진술 3개" in text and "개념 2개" in text and "정체성 2개" in text
    # The most-used concept leads, which is what "자주 말한 주제" asks for.
    assert "면접(2)" in text
    assert text.index("면접(2)") < text.index("저녁(1)")
    assert "나(2)" in text and "제니(1)" in text
    assert "2026-01-05 ~ 2026-03-09" in text


@pytest.mark.asyncio
async def test_trashed_nodes_are_not_counted(db_session, iso_user, seeded) -> None:
    """A memory in the trash must stop showing up in the user's totals."""
    seeded["s3"].deleted_at = datetime.now(timezone.utc)
    await db_session.flush()
    text = await build_graph_overview(db_session, iso_user.id)
    assert "진술 2개" in text
    assert "2026-01-05 ~ 2026-03-09" in text


@pytest.mark.asyncio
async def test_another_users_graph_never_leaks(db_session, iso_user, seeded) -> None:
    stranger = uuid.uuid4()
    assert await build_graph_overview(db_session, stranger) == ""


@pytest.mark.asyncio
async def test_empty_graph_returns_nothing_to_say(db_session, iso_user) -> None:
    """No graph yet is not the same as a graph worth summarising — the model
    should fall through to its ordinary "nothing recorded yet" reply."""
    assert await build_graph_overview(db_session, iso_user.id) == ""


@pytest.mark.asyncio
async def test_failure_degrades_to_empty(monkeypatch, db_session, iso_user) -> None:
    """The overview is an enhancement; it must never cost the user an answer."""
    async def boom(*args, **kwargs):
        raise RuntimeError("db gone")

    monkeypatch.setattr("app.graph_overview._counts_by_type", boom)
    assert await safe_graph_overview(db_session, iso_user.id) == ""


def test_planner_accepts_the_new_retriever() -> None:
    plan = SearchPlan.model_validate({"retrievers": ["graph_overview"]})
    assert plan.retrievers == ["graph_overview"]
