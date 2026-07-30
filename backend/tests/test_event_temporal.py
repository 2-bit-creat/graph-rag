from datetime import datetime

import pytest

from app import crud
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
