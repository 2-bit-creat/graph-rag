"""_build_context must render SPOKE_OR_PUBLISHED speakers and MENTIONS targets as
natural language — never leave them as ambiguous raw triples the LLM has to
infer relation semantics from (the bug: a mentioned person got misattributed as
the speaker/date owner of a statement they never spoke)."""

from __future__ import annotations

import json

import pytest

from app import crud, graph_chat


async def _make_statement(db_session, iso_user, *, name: str, content: str) -> object:
    return await crud._get_or_create_node(
        db_session,
        name=name,
        type_="Statement",
        description=json.dumps({"context_type": "회의록", "content": content}),
        user_id=iso_user.id,
    )


@pytest.mark.asyncio
async def test_speaker_rendered_as_natural_language_with_date(db_session, iso_user):
    speaker = await crud._get_or_create_node(
        db_session, name="김태연상무님", type_="Person", user_id=iso_user.id
    )
    stmt = await _make_statement(
        db_session,
        iso_user,
        name="기업은행의 성장성 발굴 플랫폼",
        content="모형공학부 부장님이 기업은행이 CES2025에서 발표한 플랫폼에 꽂히셨다.",
    )
    mentioned = await crud._get_or_create_node(
        db_session, name="모형공학부 부장님", type_="Identity", user_id=iso_user.id
    )
    stmt.occurred_at = __import__("datetime").date(2026, 7, 9)
    await crud.create_edge(
        db_session, source_id=speaker.id, target_id=stmt.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    await crud.create_edge(
        db_session, source_id=stmt.id, target_id=mentioned.id,
        relation="MENTIONS", user_id=iso_user.id,
    )
    await db_session.commit()

    ranked = await graph_chat._build_context(db_session, iso_user.id, [speaker])
    ctx = ranked.text

    assert "화자: 김태연상무님" in ctx
    assert '모형공학부 부장님이 기업은행이' in ctx
    assert "2026-07-09" in ctx
    assert "언급된 인물: 모형공학부 부장님" in ctx
    # The raw ambiguous triple must not also appear once it's been rendered in
    # natural language — that duplication is exactly what let the LLM conflate
    # the mentioned person with the actual speaker.
    assert "-[SPOKE_OR_PUBLISHED]->" not in ctx
    assert "-[MENTIONS]->" not in ctx


@pytest.mark.asyncio
async def test_self_speaker_rendered_as_my_record(db_session, iso_user):
    self_node = await crud.get_or_create_self_node(db_session, iso_user.id)
    stmt = await _make_statement(
        db_session, iso_user, name="오늘 일기", content="오늘 산책을 다녀왔다."
    )
    await crud.create_edge(
        db_session, source_id=self_node.id, target_id=stmt.id,
        relation="SPOKE_OR_PUBLISHED", user_id=iso_user.id,
    )
    await db_session.commit()

    ranked = await graph_chat._build_context(db_session, iso_user.id, [self_node])
    ctx = ranked.text

    assert "화자: 나" in ctx
    assert '"오늘 산책을 다녀왔다."' in ctx


@pytest.mark.asyncio
async def test_statement_without_speaker_edge_renders_plain_content(db_session, iso_user):
    """No SPOKE_OR_PUBLISHED edge at all → falls back to the pre-existing bare
    content line (no false 'X의 말' attribution invented)."""
    identity = await crud._get_or_create_node(
        db_session, name="테스트정체성", type_="Identity", user_id=iso_user.id
    )
    stmt = await _make_statement(
        db_session, iso_user, name="무연결 진술", content="화자 없는 진술 내용"
    )
    await crud.create_edge(
        db_session, source_id=stmt.id, target_id=identity.id,
        relation="MENTIONS", user_id=iso_user.id,
    )
    await db_session.commit()

    ranked = await graph_chat._build_context(db_session, iso_user.id, [identity])
    ctx = ranked.text

    assert "화자 없는 진술 내용" in ctx
    assert "의 말:" not in ctx
