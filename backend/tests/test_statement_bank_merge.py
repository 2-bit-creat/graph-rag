"""Statement bank merges a lemma shared across nodes into one entry.

Two speakers sharing a concept (말차) each extract "matcha" from their own
Statement node. The bank should surface ONE merged "matcha" with both origins;
deleting a graph node drops just that origin, and the vocab-card delete clears
all origins so the merged entry doesn't reappear.
"""

from __future__ import annotations

import uuid

import pytest

from app import node_expression_store as store


@pytest.fixture
def user_id(tmp_path, monkeypatch) -> uuid.UUID:
    class _S:
        upload_dir = str(tmp_path)

    monkeypatch.setattr(store, "get_settings", lambda: _S())
    return uuid.uuid4()


async def _seed_two_speaker_matcha(uid: uuid.UUID) -> None:
    # Speaker A's statement extracts matcha (+ to make).
    await store.save_node_expressions(
        uid, "node-a", "english",
        [
            {"expression": "matcha", "meaning_ko": "말차", "example_en": "I love matcha.", "cefr": "B1"},
            {"expression": "to make", "meaning_ko": "만들다", "example_en": "I make it.", "cefr": "A2"},
        ],
        node_name="말차 만들기",
    )
    # Speaker B's statement also extracts matcha (+ to drink).
    await store.save_node_expressions(
        uid, "node-b", "english",
        [
            {"expression": "matcha", "meaning_ko": "말차", "example_en": "I drink matcha daily.", "cefr": "B1"},
            {"expression": "to drink", "meaning_ko": "마시다", "example_en": "I drink tea.", "cefr": "A2"},
        ],
        node_name="말차 마시기 계획",
    )


@pytest.mark.asyncio
async def test_lemma_merges_across_nodes(user_id):
    await _seed_two_speaker_matcha(user_id)

    bank = await store.get_statement_bank_for_language(user_id, "english")
    by_word = {e["expression"]: e for e in bank}

    # matcha collapses to one entry with both origins; to make/to drink stay separate.
    assert set(by_word) == {"matcha", "to make", "to drink"}
    matcha = by_word["matcha"]
    origin_nodes = {o["node_id"] for o in matcha["origins"]}
    assert origin_nodes == {"node-a", "node-b"}
    # Distinct examples from both origins are preserved.
    examples = {o["example"] for o in matcha["origins"]}
    assert examples == {"I love matcha.", "I drink matcha daily."}
    # Back-compat: representative single-origin fields still present.
    assert matcha["source_node_id"] in {"node-a", "node-b"}


@pytest.mark.asyncio
async def test_delete_one_node_drops_only_its_origin(user_id):
    await _seed_two_speaker_matcha(user_id)

    # Deleting node A's copy (as a graph-node deletion would) leaves node B's.
    removed = await store.delete_node_expression(user_id, "node-a", "english", "matcha")
    assert removed is True

    bank = await store.get_statement_bank_for_language(user_id, "english")
    matcha = next(e for e in bank if e["expression"] == "matcha")
    assert [o["node_id"] for o in matcha["origins"]] == ["node-b"]


@pytest.mark.asyncio
async def test_delete_all_origins_removes_entry(user_id):
    await _seed_two_speaker_matcha(user_id)

    count = await store.delete_expression_all_origins(user_id, "english", "matcha")
    assert count == 2  # one copy per origin node

    bank = await store.get_statement_bank_for_language(user_id, "english")
    assert all(e["expression"] != "matcha" for e in bank)
    # Other expressions are untouched.
    assert {e["expression"] for e in bank} == {"to make", "to drink"}


@pytest.mark.asyncio
async def test_quiz_pick_dedupes_shared_lemma(user_id):
    # Only matcha exists, shared across two nodes — must still be pickable exactly once.
    await store.save_node_expressions(
        user_id, "node-a", "english",
        [{"expression": "matcha", "meaning_ko": "말차", "example_en": "x", "cefr": "B1"}],
        node_name="A",
    )
    await store.save_node_expressions(
        user_id, "node-b", "english",
        [{"expression": "matcha", "meaning_ko": "말차", "example_en": "y", "cefr": "B1"}],
        node_name="B",
    )
    picked = await store.pick_random_expression_for_quiz(user_id, "english", target_level=50)
    assert picked is not None
    assert picked["expression"] == "matcha"
