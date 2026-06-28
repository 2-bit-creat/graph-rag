"""Tests for quiz graph subgraph selection (no pytest required)."""

import uuid
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock, patch

from app.quiz_graph_selector import (
    QuizGraphSelection,
    _format_context,
    _recency_score,
    select_quiz_subgraph,
)
from app.quiz_presenter import quiz_queue_item_dict
from app.quiz_settings import quiz_selection_settings


def test_recency_score_recent_higher():
    now = datetime.now(UTC)
    recent = _recency_score(now - timedelta(hours=1))
    old = _recency_score(now - timedelta(days=30))
    assert recent > old


def test_format_context():
    nodes = [{"name": "Cheolsu", "type": "Person"}]
    edges = [{"source": "Cheolsu", "relation": "met_at", "target": "Starbucks"}]
    text = _format_context(nodes, edges)
    assert "Cheolsu" in text
    assert "met_at" in text


def test_quiz_selection_settings_snapshot():
    cfg = quiz_selection_settings(35)
    assert cfg["quiz_max_nodes"] == 10
    assert cfg["quiz_max_hops"] == 2
    assert cfg["quiz_recency_weight"] == 0.7
    assert cfg["level_window"]


def test_presenter_target_node_from_quiz_data():
    from types import SimpleNamespace

    quiz = SimpleNamespace(
        id=uuid.uuid4(),
        quiz_type="cloze",
        queue_kind="new",
        difficulty_level=20,
        source_nodes=None,
        question_ko="Q",
        sentence_en="I like coffee.",
        quiz_data={"blank": "coffee", "prompt_en": "I like ____."},
        next_review_at=None,
        repetitions=0,
        times_correct=0,
        times_wrong=0,
        created_at=datetime.now(UTC),
        associated_entry_id=None,
    )
    out = quiz_queue_item_dict(quiz, {})
    assert out["target_node"] == "coffee"
    assert "____" in out["context_sentence"]


async def _test_select_respects_max_nodes():
    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()
    now = datetime.now(UTC)

    seeds = []
    candidates = {}
    for i in range(20):
        nid = uuid.uuid4()
        node = MagicMock()
        node.id = nid
        node.name = f"Node{i}"
        node.type = "Topic"
        node.created_at = now - timedelta(days=i)
        candidates[nid] = node
        if i < 2:
            seeds.append((node, now))

    async def mock_list_seeds(session, eid):
        return seeds

    async def mock_neighborhood(session, uid, seed_ids, depth=2):
        return set(candidates.keys())

    with patch("app.quiz_graph_selector.list_entry_graph_seed_nodes", mock_list_seeds):
        with patch("app.crud.get_neighborhood", mock_neighborhood):
            session = AsyncMock()
            session.execute = AsyncMock(
                return_value=MagicMock(
                    scalars=MagicMock(
                        return_value=MagicMock(all=MagicMock(return_value=list(candidates.values())))
                    )
                )
            )
            with patch("app.quiz_graph_selector.get_edges_for_nodes", AsyncMock(return_value=[])):
                selection = await select_quiz_subgraph(
                    session, user_id, entry_id, "I met Cheolsu at Starbucks."
                )

    assert isinstance(selection, QuizGraphSelection)
    assert len(selection.selected_nodes) <= 10
    total_picked = sum(selection.pick_breakdown.values())
    assert total_picked == len(selection.selected_nodes)
    print("OK select_respects_max_nodes")


async def _test_empty_graph_fallback():
    user_id = uuid.uuid4()
    entry_id = uuid.uuid4()

    with patch("app.quiz_graph_selector.list_entry_graph_seed_nodes", AsyncMock(return_value=[])):
        with patch(
            "app.quiz_graph_selector._fallback_seed_nodes",
            AsyncMock(return_value=[]),
        ):
            session = AsyncMock()
            selection = await select_quiz_subgraph(session, user_id, entry_id, "hello")

    assert selection.candidate_count == 0
    assert "journal" in selection.context_text.lower()
    print("OK empty_graph_fallback")


def main():
    test_recency_score_recent_higher()
    test_format_context()
    test_quiz_selection_settings_snapshot()
    test_presenter_target_node_from_quiz_data()
    import asyncio

    asyncio.run(_test_select_respects_max_nodes())
    asyncio.run(_test_empty_graph_fallback())
    print("All quiz graph selector tests passed.")


if __name__ == "__main__":
    main()
