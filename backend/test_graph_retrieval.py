"""Tests for the shared GraphRAG core: Context Package building + RRF rerank."""

import uuid
from datetime import UTC, date, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock

from app.graph_retrieval import (
    ContextPackage,
    _package_importance,
    build_final_prompt_context,
    rank_packages,
    statement_content,
)


def _node(
    *,
    type_="Statement",
    name="stmt",
    description=None,
    occurred_at=None,
    created_at=None,
    is_self=False,
    importance_score=0,
):
    return SimpleNamespace(
        id=uuid.uuid4(),
        type=type_,
        name=name,
        description=description,
        occurred_at=occurred_at,
        created_at=created_at or datetime.now(UTC),
        is_self=is_self,
        importance_score=importance_score,
    )


def _package(
    *,
    occurred_at=None,
    concepts=None,
    speaker=None,
    mentions=None,
    content="",
):
    stmt = _node(
        type_="Statement",
        name="title",
        description=f'{{"content": "{content}"}}' if content else None,
        occurred_at=occurred_at,
    )
    return ContextPackage(
        statement=stmt,
        speaker=speaker,
        concepts=concepts or [],
        mentions=mentions or [],
    )


def test_statement_content_reads_json_description():
    node = _node(description='{"content": "실제 문장입니다"}')
    assert statement_content(node) == "실제 문장입니다"


def test_statement_content_falls_back_to_name_when_no_description():
    node = _node(name="제목만 있음", description=None)
    assert statement_content(node) == "제목만 있음"


def test_package_importance_uses_max_not_sum():
    """A package with 3 low-importance concepts must not outrank a package with
    1 high-importance concept — sum would bias toward concept COUNT."""
    many_low = _package(
        concepts=[
            _node(type_="Concept", importance_score=1),
            _node(type_="Concept", importance_score=1),
            _node(type_="Concept", importance_score=1),
        ]
    )
    one_high = _package(concepts=[_node(type_="Concept", importance_score=5)])
    assert _package_importance(many_low) == 1
    assert _package_importance(one_high) == 5


async def test_rank_packages_recency_wins_with_no_other_signal():
    today = date.today()
    recent = _package(occurred_at=today, content="최근 진술")
    old = _package(occurred_at=today - timedelta(days=30), content="오래된 진술")
    session = AsyncMock()

    ranked = await rank_packages(session, [old, recent])

    assert ranked[0].id == recent.id
    assert ranked[1].id == old.id


async def test_rank_packages_soft_time_penalty_does_not_hard_exclude():
    """A package outside an explicit time window loses rank but is never dropped
    — a vaguely-timed question shouldn't lose a genuinely relevant memory."""
    today = date.today()
    window = (today - timedelta(days=2), today)
    inside = _package(occurred_at=today, content="창 안")
    outside = _package(occurred_at=today - timedelta(days=60), content="창 밖")
    session = AsyncMock()

    ranked = await rank_packages(session, [outside, inside], time_window=window)

    assert [p.id for p in ranked] == [inside.id, outside.id]
    assert outside in ranked  # never excluded, only demoted


async def test_rank_packages_importance_breaks_recency_tie():
    today = date.today()
    important = _package(
        occurred_at=today, concepts=[_node(type_="Concept", importance_score=5)]
    )
    unimportant = _package(
        occurred_at=today, concepts=[_node(type_="Concept", importance_score=0)]
    )
    session = AsyncMock()

    ranked = await rank_packages(session, [unimportant, important])

    assert ranked[0].id == important.id


def test_build_final_prompt_context_separates_concepts_and_mentions():
    """CONTEXT concepts and MENTIONS identities must render as distinct lines —
    conflating the two reintroduces the speaker/mentioned-person confusion bug."""
    speaker = _node(type_="Person", name="Seyeong", is_self=False)
    concept = _node(type_="Concept", name="Taiwanese")
    mentioned = _node(type_="Person", name="Cheolsu")
    pkg = _package(
        occurred_at=date(2025, 12, 15),
        speaker=speaker,
        concepts=[concept],
        mentions=[mentioned],
        content="Es ist nicht Thai, es ist Taiwanese.",
    )

    text = build_final_prompt_context([pkg], top_k=5)

    assert "화자: Seyeong" in text
    assert "연관 개념: Taiwanese" in text
    assert "언급된 인물: Cheolsu" in text
    # Mentioned person must not leak into the concepts line or vice versa.
    concept_line = next(l for l in text.splitlines() if l.startswith("- 연관 개념"))
    mention_line = next(l for l in text.splitlines() if l.startswith("- 언급된 인물"))
    assert "Cheolsu" not in concept_line
    assert "Taiwanese" not in mention_line


def test_build_final_prompt_context_self_speaker_labeled_나():
    pkg = _package(occurred_at=date.today(), speaker=_node(is_self=True, name="나"))
    text = build_final_prompt_context([pkg], top_k=5)
    assert "화자: 나" in text


def test_build_final_prompt_context_respects_top_k_cutoff():
    packages = [_package(occurred_at=date.today(), content=f"문장{i}") for i in range(5)]
    text = build_final_prompt_context(packages, top_k=2)
    assert text.count("기록 ") == 2
