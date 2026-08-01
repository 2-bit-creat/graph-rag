from datetime import date, datetime

import pytest

from app import crud
from app.routers.kg_build import _claim_temporal_values
from app.temporal import resolve_event_temporal


def test_relative_event_time_uses_entry_anchor_not_node_creation_day():
    value = resolve_event_temporal(
        statement="어제 투자 보고서를 작성했다.",
        entry_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
        tz_name="Asia/Seoul",
        event_time_text="어제",
        event_status="happened",
        claimed_precision="relative",
        claimed_confidence=1.0,
    )
    assert value.occurred_at.isoformat() == "2026-07-29"
    assert value.start_at.isoformat() == "2026-07-29T00:00:00+09:00"
    assert value.end_at.isoformat() == "2026-07-30T00:00:00+09:00"
    assert value.status == "happened"


def test_no_explicit_time_is_recorded_day_fallback_with_lower_confidence():
    value = resolve_event_temporal(
        statement="투자 보고서를 작성했다.",
        entry_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
        tz_name="Asia/Seoul",
    )
    assert value.occurred_at.isoformat() == "2026-07-30"
    assert value.precision == "recorded_date"
    assert value.confidence == 0.6


def test_planned_event_keeps_status_out_of_default_past_recall_candidates():
    value = resolve_event_temporal(
        statement="내일 보고서를 작성할 예정이다.",
        entry_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
        tz_name="Asia/Seoul",
        event_time_text="내일",
        event_status="planned",
        claimed_precision="relative",
        claimed_confidence=1.0,
    )
    # The deterministic parser currently intentionally recognises only past and
    # present query windows. Planned status still protects this from happened-only
    # recall while future-expression support is added to the shared parser.
    assert value.status == "planned"


@pytest.mark.asyncio
async def test_yesterday_event_written_today_is_found_in_yesterday_window(db_session, iso_user):
    value = resolve_event_temporal(
        statement="어제 투자 보고서를 작성했다.",
        entry_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
        tz_name="Asia/Seoul",
        event_time_text="어제",
        event_status="happened",
        claimed_precision="relative",
        claimed_confidence=1.0,
    )
    node = await crud._get_or_create_node(
        db_session,
        name="투자 보고서 작성",
        type_="Statement",
        description='{"content":"어제 투자 보고서를 작성했다."}',
        user_id=iso_user.id,
        claim_key="event-yesterday-test",
        occurred_at=value.occurred_at,
        recorded_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
        event_start_at=value.start_at,
        event_end_at=value.end_at,
        temporal_precision=value.precision,
        temporal_confidence=value.confidence,
        temporal_source_text=value.source_text,
        temporal_anchor_at=value.anchor_at,
        event_status=value.status,
        event_timezone=value.timezone,
    )
    await db_session.commit()
    found = await crud.find_statements_by_time_window(
        db_session,
        iso_user.id,
        value.occurred_at,
        value.occurred_at,
        tz_name="Asia/Seoul",
    )
    assert [item.id for item in found] == [node.id]


# ─── Reviewer-confirmed event day ─────────────────────────────────────────────
# Text written in plain past tense ("친구가 이직한대") carries no signal about when
# it happened, so an entry drafted the morning after lands on the wrong day. The
# reviewer's answer is the only ground truth available, and it must win.


def test_date_override_beats_the_recorded_day_fallback():
    values = _claim_temporal_values(
        {"statement": "친구가 이직한대.", "event_date_override": "2026-07-28"},
        datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
    )
    assert values["occurred_at"].isoformat() == "2026-07-28"
    assert values["temporal_precision"] == "user_set"
    assert values["temporal_confidence"] == 1.0
    assert values["event_start_at"].isoformat() == "2026-07-28T00:00:00+09:00"
    assert values["event_end_at"].isoformat() == "2026-07-29T00:00:00+09:00"


def test_date_override_beats_an_explicit_relative_expression_too():
    values = _claim_temporal_values(
        {
            "statement": "어제 친구를 만났다.",
            "event_time_text": "어제",
            "temporal_precision": "relative",
            "temporal_confidence": 1.0,
            "event_date_override": date(2026, 7, 20),
        },
        datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
    )
    assert values["occurred_at"].isoformat() == "2026-07-20"
    assert values["temporal_precision"] == "user_set"


def test_absent_or_unparsable_override_falls_back_to_inference():
    anchor = datetime.fromisoformat("2026-07-30T10:15:00+09:00")
    for override in (None, "", "not-a-date"):
        values = _claim_temporal_values(
            {"statement": "친구가 이직한대.", "event_date_override": override},
            anchor,
        )
        assert values["occurred_at"].isoformat() == "2026-07-30", override
        assert values["temporal_precision"] == "recorded_date", override


def test_override_preserves_non_default_event_status():
    values = _claim_temporal_values(
        {
            "statement": "출장을 갈 예정이었다.",
            "event_status": "cancelled",
            "event_date_override": "2026-07-25",
        },
        datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
    )
    assert values["event_status"] == "cancelled"
    assert values["occurred_at"].isoformat() == "2026-07-25"


# ─── Post-commit correction from the graph inspector ──────────────────────────


@pytest.mark.asyncio
async def test_manual_event_date_overwrites_a_guessed_day_and_is_retained(
    db_session, iso_user
):
    from sqlalchemy import select

    from app.models import TemporalBackfillAudit
    from app.temporal_backfill import apply_manual_event_date

    node = await crud._get_or_create_node(
        db_session,
        name="친구 이직 소식",
        type_="Statement",
        description='{"content":"친구가 이직한대."}',
        user_id=iso_user.id,
        claim_key="manual-date-test",
        occurred_at=date(2026, 7, 30),
        recorded_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
        temporal_precision="recorded_date",
        temporal_confidence=0.6,
        temporal_source_text=None,
    )
    await db_session.commit()

    changed = apply_manual_event_date(
        db_session, node, date(2026, 7, 28), timezone_name="Asia/Seoul"
    )
    await db_session.commit()

    assert changed is True
    assert node.occurred_at.isoformat() == "2026-07-28"
    assert node.temporal_precision == "user_set"
    assert node.temporal_confidence == 1.0
    assert node.event_start_at.isoformat() == "2026-07-28T00:00:00+09:00"
    assert node.event_end_at.isoformat() == "2026-07-29T00:00:00+09:00"

    audits = (
        await db_session.execute(
            select(TemporalBackfillAudit).where(
                TemporalBackfillAudit.node_id == node.id
            )
        )
    ).scalars().all()
    assert len(audits) == 1
    assert audits[0].before["occurred_at"] == "2026-07-30"
    assert audits[0].after["occurred_at"] == "2026-07-28"
    assert audits[0].run_key == "manual-edit"


@pytest.mark.asyncio
async def test_setting_the_same_day_twice_adds_no_second_audit_row(
    db_session, iso_user
):
    from app.temporal_backfill import apply_manual_event_date

    node = await crud._get_or_create_node(
        db_session,
        name="반복 편집",
        type_="Statement",
        description='{"content":"같은 날짜를 다시 지정한다."}',
        user_id=iso_user.id,
        claim_key="manual-date-idempotent",
        occurred_at=date(2026, 7, 30),
        recorded_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
        temporal_precision="recorded_date",
        temporal_confidence=0.6,
    )
    await db_session.commit()

    assert apply_manual_event_date(
        db_session, node, date(2026, 7, 28), timezone_name="Asia/Seoul"
    ) is True
    await db_session.commit()
    assert apply_manual_event_date(
        db_session, node, date(2026, 7, 28), timezone_name="Asia/Seoul"
    ) is False


@pytest.mark.asyncio
async def test_backfill_never_recomputes_a_user_confirmed_day(db_session, iso_user):
    """The automatic pass would re-read the same text that lacked the date."""
    from app.models import JournalEntry, JournalGraphLink
    from app.temporal_backfill import backfill_statement_event_times

    entry = JournalEntry(
        user_id=iso_user.id,
        transcript_native="친구가 이직한대.",
        created_at=datetime.fromisoformat("2026-07-30T10:15:00+09:00"),
    )
    db_session.add(entry)
    await db_session.flush()

    node = await crud._get_or_create_node(
        db_session,
        name="사용자 확정 날짜",
        type_="Statement",
        description='{"content":"친구가 이직한대."}',
        user_id=iso_user.id,
        claim_key="user-set-guard",
        occurred_at=date(2026, 7, 28),
        recorded_at=entry.created_at,
        temporal_precision="user_set",
        temporal_confidence=1.0,
    )
    db_session.add(
        JournalGraphLink(journal_entry_id=entry.id, node_id=node.id)
    )
    await db_session.commit()

    await backfill_statement_event_times(
        db_session, iso_user.id, timezone_name="Asia/Seoul"
    )
    await db_session.refresh(node)

    assert node.occurred_at.isoformat() == "2026-07-28"
    assert node.temporal_precision == "user_set"
