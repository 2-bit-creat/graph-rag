from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

from app import query_planner


@pytest.mark.asyncio
async def test_planner_locks_deterministic_yesterday_even_if_model_disagrees(monkeypatch):
    response = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content='''{
          "answer_intent":"topic_search", "time":null, "entities":[], "topics":["보고서"],
          "event_status":["happened"], "retrievers":["dense"], "fusion":"rrf",
          "rerank":false, "result_limit":12,
          "learning":{"enabled":true,"mode":"optional_followup"}
        }'''))]
    )
    client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=None)))

    async def fake_create(**_kwargs):
        return response

    client.chat.completions.create = fake_create
    monkeypatch.setattr(query_planner, "_get_client", lambda: client)

    planned = await query_planner.create_search_plan(
        "어제 보고서 관련해서 뭐했지?",
        now=datetime.fromisoformat("2026-07-30T10:00:00+09:00"),
        tz=ZoneInfo("Asia/Seoul"),
    )
    assert planned.status == "ok"
    assert planned.plan.time.start.isoformat() == "2026-07-29"
    assert planned.plan.time.constraint == "hard"
    assert "temporal_sql" in planned.plan.retrievers


@pytest.mark.asyncio
async def test_planner_failure_returns_bounded_safe_fallback(monkeypatch):
    monkeypatch.setattr(query_planner, "_get_client", lambda: (_ for _ in ()).throw(RuntimeError("down")))
    planned = await query_planner.create_search_plan(
        "어제 뭐했지?",
        now=datetime.fromisoformat("2026-07-30T10:00:00+09:00"),
        tz=ZoneInfo("Asia/Seoul"),
    )
    assert planned.status == "fallback"
    assert planned.plan.time.constraint == "hard"
    assert planned.plan.result_limit <= 20


def test_empty_event_status_keeps_completed_event_default():
    """A required-but-empty LLM array must not erase temporal candidates."""
    plan = query_planner.SearchPlan.model_validate(
        {
            "answer_intent": "episodic_recall",
            "time": None,
            "entities": [],
            "topics": [],
            "event_status": [],
            "retrievers": ["temporal_sql"],
            "fusion": "none",
            "rerank": False,
            "result_limit": 12,
            "learning": {"enabled": False, "mode": "none"},
        }
    )
    assert plan.event_status == ["happened"]
