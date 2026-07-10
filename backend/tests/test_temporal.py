"""Temporal parsing, time-window retrieval, and graph-chat integration."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock
from zoneinfo import ZoneInfo

import pytest

from app import crud, graph_chat
from app.models import JournalEntry, JournalGraphLink, Node
from app.routers.kg_build import _parse_occurred_at, _persist_claims
from app.temporal import format_time_window_label, parse_time_window

KST = ZoneInfo("Asia/Seoul")


def _now_kst(y: int, m: int, d: int, hour: int = 12) -> datetime:
    return datetime(y, m, d, hour, 0, 0, tzinfo=KST)


def _utc_dt(y: int, m: int, d: int, hour: int = 3) -> datetime:
    """UTC instant that maps to the given KST calendar date at noon KST."""
    return datetime(y, m, d, hour, 0, 0, tzinfo=timezone.utc)


async def _stmt_with_link(
    db_session,
    user_id: uuid.UUID,
    *,
    content: str,
    occurred_at: date | None = None,
    entry_created_at: datetime | None = None,
    node_created_at: datetime | None = None,
) -> tuple[Node, JournalEntry]:
    entry = JournalEntry(
        user_id=user_id,
        status="done",
        source_type="개인일기",
        transcript_clean_ko=content,
        created_at=entry_created_at or _utc_dt(2026, 7, 9),
    )
    db_session.add(entry)
    await db_session.flush()

    desc = '{"context_type": "개인일기", "content": "' + content + '"}'
    node = Node(
        user_id=user_id,
        name=content[:20],
        type="Statement",
        description=desc,
        occurred_at=occurred_at,
    )
    if node_created_at is not None:
        node.created_at = node_created_at
    db_session.add(node)
    await db_session.flush()
    db_session.add(
        JournalGraphLink(journal_entry_id=entry.id, node_id=node.id)
    )
    await db_session.commit()
    await db_session.refresh(node)
    await db_session.refresh(entry)
    return node, entry


# ── parse_time_window ─────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "text,expected",
    [
        ("오늘 내가 뭐 했지?", (date(2026, 7, 9), date(2026, 7, 9))),
        ("어제 뭐 했어?", (date(2026, 7, 8), date(2026, 7, 8))),
        ("그저께 기억나?", (date(2026, 7, 7), date(2026, 7, 7))),
        ("지난주에 뭐 했지?", (date(2026, 6, 29), date(2026, 7, 5))),
        ("3일 전 일정", (date(2026, 7, 6), date(2026, 7, 6))),
        ("2026-07-03 기록", (date(2026, 7, 3), date(2026, 7, 3))),
        ("7월 3일에 갔다", (date(2026, 7, 3), date(2026, 7, 3))),
        ("이번 달 요약", (date(2026, 7, 1), date(2026, 7, 31))),
        ("마야가 누구야?", None),
    ],
)
def test_parse_time_window(text: str, expected):
    now = _now_kst(2026, 7, 9)
    assert parse_time_window(text, KST, now) == expected


def test_parse_time_window_kst_midnight_boundary():
    # 2026-07-09 00:30 KST is still "오늘"
    now = datetime(2026, 7, 9, 0, 30, tzinfo=KST)
    assert parse_time_window("오늘", KST, now) == (date(2026, 7, 9), date(2026, 7, 9))


def test_format_time_window_label_today():
    now = _now_kst(2026, 7, 9)
    label = format_time_window_label(
        date(2026, 7, 9), date(2026, 7, 9), "오늘 뭐 했지", KST, now
    )
    assert label == "요청 기간: 2026-07-09 (오늘)"


# ── find_statements_by_time_window ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_find_statements_occurred_at_hit(db_session, iso_user):
    node, _ = await _stmt_with_link(
        db_session,
        iso_user.id,
        content="제주도 여행",
        occurred_at=date(2026, 6, 30),
        entry_created_at=_utc_dt(2026, 7, 9),
    )
    hits = await crud.find_statements_by_time_window(
        db_session, iso_user.id, date(2026, 6, 30), date(2026, 6, 30)
    )
    assert [n.id for n in hits] == [node.id]


@pytest.mark.asyncio
async def test_find_statements_entry_created_fallback(db_session, iso_user):
    node, _ = await _stmt_with_link(
        db_session,
        iso_user.id,
        content="오늘 코딩함",
        occurred_at=None,
        entry_created_at=_utc_dt(2026, 7, 9, hour=3),
    )
    hits = await crud.find_statements_by_time_window(
        db_session, iso_user.id, date(2026, 7, 9), date(2026, 7, 9)
    )
    assert [n.id for n in hits] == [node.id]


@pytest.mark.asyncio
async def test_find_statements_excludes_outside_window(db_session, iso_user):
    await _stmt_with_link(
        db_session,
        iso_user.id,
        content="옛날 일",
        occurred_at=date(2026, 1, 1),
        entry_created_at=_utc_dt(2026, 1, 1),
    )
    hits = await crud.find_statements_by_time_window(
        db_session, iso_user.id, date(2026, 7, 9), date(2026, 7, 9)
    )
    assert hits == []


@pytest.mark.asyncio
async def test_find_statements_limit_and_sort(db_session, iso_user):
    older, _ = await _stmt_with_link(
        db_session,
        iso_user.id,
        content="먼저",
        occurred_at=date(2026, 7, 8),
        entry_created_at=_utc_dt(2026, 7, 8),
    )
    newer, _ = await _stmt_with_link(
        db_session,
        iso_user.id,
        content="나중",
        occurred_at=date(2026, 7, 9),
        entry_created_at=_utc_dt(2026, 7, 9),
    )
    hits = await crud.find_statements_by_time_window(
        db_session,
        iso_user.id,
        date(2026, 7, 1),
        date(2026, 7, 31),
        limit=1,
    )
    assert len(hits) == 1
    assert hits[0].id == newer.id
    assert newer.id != older.id


# ── graph_chat temporal integration ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_graph_chat_today_without_embedding_seeds(db_session, iso_user, monkeypatch):
    node, _ = await _stmt_with_link(
        db_session,
        iso_user.id,
        content="오늘 회의 준비함",
        entry_created_at=_utc_dt(2026, 7, 9, hour=3),
    )

    captured: dict = {}

    async def fake_create(**kwargs):
        captured["messages"] = kwargs["messages"]
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content="회의 준비했지"))],
            usage=SimpleNamespace(
                prompt_tokens=10,
                completion_tokens=2,
                total_tokens=12,
                prompt_tokens_details=SimpleNamespace(cached_tokens=0),
            ),
        )

    client = SimpleNamespace(
        chat=SimpleNamespace(
            completions=SimpleNamespace(create=fake_create)
        )
    )
    monkeypatch.setattr(graph_chat, "_get_client", lambda: client)
    monkeypatch.setattr(graph_chat, "_retrieve_seeds", AsyncMock(return_value=[]))
    monkeypatch.setattr(
        graph_chat,
        "ensure_statement_embeddings",
        AsyncMock(),
    )
    monkeypatch.setattr(
        graph_chat,
        "backfill_alias_embeddings",
        AsyncMock(),
    )
    monkeypatch.setattr(
        graph_chat,
        "user_has_alias_embeddings",
        AsyncMock(return_value=True),
    )

    fixed_now = _now_kst(2026, 7, 9)
    monkeypatch.setattr(graph_chat, "datetime", type(
        "DT",
        (),
        {"now": staticmethod(lambda tz=None: fixed_now)},
    ))

    result = await graph_chat.graph_chat_answer(
        db_session,
        iso_user,
        "오늘 내가 뭐 했지?",
        [],
    )

    ctx = captured["messages"][-2]["content"]
    assert "요청 기간: 2026-07-09 (오늘)" in ctx
    assert "회의 준비" in ctx
    assert str(node.id) in result.referenced_node_ids


@pytest.mark.asyncio
async def test_graph_chat_temporal_embedding_dedup(db_session, iso_user, monkeypatch):
    node, _ = await _stmt_with_link(
        db_session,
        iso_user.id,
        content="오늘 산책",
        entry_created_at=_utc_dt(2026, 7, 9),
    )

    async def fake_create(**kwargs):
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content="ok"))],
            usage=SimpleNamespace(
                prompt_tokens=1,
                completion_tokens=1,
                total_tokens=2,
                prompt_tokens_details=SimpleNamespace(cached_tokens=0),
            ),
        )

    client = SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=fake_create))
    )
    monkeypatch.setattr(graph_chat, "_get_client", lambda: client)
    monkeypatch.setattr(graph_chat, "_retrieve_seeds", AsyncMock(return_value=[node]))
    monkeypatch.setattr(graph_chat, "ensure_statement_embeddings", AsyncMock())
    monkeypatch.setattr(graph_chat, "backfill_alias_embeddings", AsyncMock())
    monkeypatch.setattr(
        graph_chat, "user_has_alias_embeddings", AsyncMock(return_value=True)
    )
    fixed_now = _now_kst(2026, 7, 9)
    monkeypatch.setattr(graph_chat, "datetime", type(
        "DT",
        (),
        {"now": staticmethod(lambda tz=None: fixed_now)},
    ))

    result = await graph_chat.graph_chat_answer(
        db_session, iso_user, "오늘 뭐 했지?", []
    )
    assert result.referenced_node_ids.count(str(node.id)) == 1


@pytest.mark.asyncio
async def test_build_context_prefers_occurred_at_prefix(db_session, iso_user):
    node = await crud._get_or_create_node(
        db_session,
        name="제주 여행",
        type_="Statement",
        description='{"context_type":"개인일기","content":"제주도 갔다"}',
        user_id=iso_user.id,
    )
    node.occurred_at = date(2026, 6, 30)
    node.created_at = _utc_dt(2026, 7, 9)
    await db_session.commit()

    ctx = await graph_chat._build_context(db_session, iso_user.id, [node])
    assert "[2026-06-30]" in ctx


# ── extraction occurred_at ────────────────────────────────────────────────────


def test_parse_occurred_at_valid_and_invalid():
    assert _parse_occurred_at("2026-06-30") == date(2026, 6, 30)
    assert _parse_occurred_at("not-a-date") is None
    assert _parse_occurred_at(None) is None


@pytest.mark.asyncio
async def test_persist_claims_stores_occurred_at(db_session, iso_user):
    claims = [{
        "speaker": "나",
        "title": "제주 여행",
        "statement": "지난주에 제주도에 갔다",
        "when": "2026-06-30",
        "concepts": [{"name": "제주도", "importance": 4, "kind": "concept"}],
    }]
    await _persist_claims(db_session, iso_user.id, claims, "개인일기")
    await db_session.commit()

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    stmt = next(n for n in nodes if n.type == "Statement")
    assert stmt.occurred_at == date(2026, 6, 30)


@pytest.mark.asyncio
async def test_persist_claims_ignores_bad_when(db_session, iso_user):
    claims = [{
        "speaker": "나",
        "title": "일상",
        "statement": "평범한 하루",
        "when": "어제쯤",
        "concepts": [{"name": "일상", "importance": 3, "kind": "concept"}],
    }]
    await _persist_claims(db_session, iso_user.id, claims, "개인일기")
    await db_session.commit()

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    stmt = next(n for n in nodes if n.type == "Statement")
    assert stmt.occurred_at is None
