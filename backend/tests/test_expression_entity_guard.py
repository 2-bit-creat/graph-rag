"""People's names must never become learning expressions.

A group-chat diary produced wordbook entries like ``es heißt eui-jun und
seung-hyun`` and ``euijun seunghyeon ist`` — the speakers' own names, romanized.
The graph already knows those names (speaker + MENTIONS identities), so the
rejection is deterministic rather than a plea to the model.
"""

from __future__ import annotations

import pytest

from app import crud
from app.expression_entity_guard import (
    EntityNameGuard,
    build_statement_entity_guard,
    romanization_variants,
)


def test_romanization_covers_the_spellings_names_actually_use():
    assert "uijun" in romanization_variants("의준")
    assert "euijun" in romanization_variants("의준")
    assert "seunghyeon" in romanization_variants("승현")
    assert "seunghyun" in romanization_variants("승현")
    assert "yeongho" in romanization_variants("영호")
    assert "youngho" in romanization_variants("영호")


def test_single_syllable_names_are_not_romanized():
    """"호" → "ho" would collide with ordinary words; the cure would be worse."""
    assert romanization_variants("호") == set()


def test_guard_rejects_the_expressions_from_the_bug_report():
    guard = EntityNameGuard(["박의준", "이승현", "이영호"])

    assert guard.target_reason("es heißt eui-jun und seung-hyun")
    assert guard.target_reason("euijun seunghyeon ist")
    assert guard.native_reason("의준이 승현이다")
    assert guard.native_reason("의준과 승현이라고 말한다")


def test_guard_leaves_real_expressions_alone():
    guard = EntityNameGuard(["박의준", "이승현", "이영호"])

    for expression, meaning in [
        ("gut sein", "좋다"),
        ("heißt, dass", "라고 한다"),
        ("ins Schwimmbad gehen", "수영장에 가다"),
        ("seine Meinung vertreten", "소신을 지키다"),
    ]:
        assert guard.reason(target=expression, native=meaning) is None


def test_guard_matches_whole_tokens_only():
    """A name hiding inside a longer word must not take the word down with it."""
    guard = EntityNameGuard(["민수"])  # minsu
    assert guard.target_reason("minsupply chain") is None


def test_self_speaker_is_not_treated_as_a_name():
    assert not EntityNameGuard(["나"])


@pytest.mark.asyncio
async def test_guard_is_built_from_the_statement_graph(db_session, iso_user):
    speaker = await crud._get_or_create_node(
        db_session, name="이영호", type_="Identity", user_id=iso_user.id
    )
    stmt = await crud._get_or_create_node(
        db_session, name="의준과 승현에 대한 언급", type_="Statement", user_id=iso_user.id
    )
    mentioned = await crud._get_or_create_node(
        db_session, name="박의준", type_="Identity", user_id=iso_user.id
    )
    await crud.create_edge(
        db_session, source_id=speaker.id, target_id=stmt.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    await crud.create_edge(
        db_session, source_id=stmt.id, target_id=mentioned.id,
        relation="MENTIONS", user_id=iso_user.id,
    )
    await db_session.commit()

    guard = await build_statement_entity_guard(db_session, iso_user.id, stmt.id)

    assert guard.native_reason("영호가 말했다")
    assert guard.target_reason("euijun ist gut")
    assert guard.reason(target="gut sein", native="좋다") is None
