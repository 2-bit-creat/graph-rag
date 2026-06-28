"""Tests for pipeline flow quiz nodes."""

from app.pipeline_flow import (
    BLUEPRINT_VERSION,
    QUIZ_NODES,
    _build_step_view,
    build_flow_layout,
    get_pipeline_blueprint,
)


def test_blueprint_has_quiz_nodes():
    bp = get_pipeline_blueprint()
    assert bp["version"] == BLUEPRINT_VERSION
    ids = {n["id"] for n in bp["nodes"]}
    for node in QUIZ_NODES:
        assert node.id in ids
    assert "flow_layout" not in bp  # added by debug endpoint only


def test_flow_layout_quiz_steps():
    trace = {
        "steps": [
            {
                "step_id": "1",
                "name": "quiz_manual_trigger",
                "type": "policy",
                "phase": "quiz_path",
                "status": "completed",
                "started_at": "2026-01-01T00:00:00+00:00",
                "ended_at": "2026-01-01T00:00:01+00:00",
                "input": {"quiz_type": "cloze"},
                "output": {"trigger": "manual"},
            },
            {
                "step_id": "2",
                "name": "quiz_level_load",
                "type": "policy",
                "phase": "quiz_path",
                "status": "completed",
                "started_at": "2026-01-01T00:00:01+00:00",
                "ended_at": "2026-01-01T00:00:02+00:00",
                "input": {
                    "settings": {"quiz_max_nodes": 10, "quiz_max_hops": 2},
                    "level_window": [32, 38],
                },
                "output": {"current_level": 35, "cefr_label": "A2", "level_window": [32, 38]},
            },
        ]
    }
    layout = build_flow_layout(trace)
    quiz_nodes = [n for n in layout["nodes"] if n.get("phase") == "quiz_path"]
    assert len(quiz_nodes) >= len(QUIZ_NODES)
    completed = [n for n in quiz_nodes if n["status"] == "completed"]
    assert any(n["id"] == "quiz_manual_trigger" for n in completed)


def test_step_view_quiz_level_load():
    bp = next(n for n in QUIZ_NODES if n.id == "quiz_level_load")
    raw = {
        "input": {"settings": {"quiz_max_nodes": 10}, "level_window": [30, 36]},
        "output": {"current_level": 33, "cefr_label": "A2"},
        "status": "completed",
    }
    view = _build_step_view(bp, raw, status="completed")
    assert view is not None
    assert view["output"]["settings"]["quiz_max_nodes"] == 10
    assert view["output"]["current_level"] == 33


def test_step_view_quiz_source_fetch():
    bp = next(n for n in QUIZ_NODES if n.id == "quiz_source_fetch")
    raw = {
        "input": {"settings": {"quiz_max_hops": 2}, "entry_id": "abc"},
        "output": {
            "seed_count": 2,
            "pick_breakdown": {"recency": 7, "random": 3, "seed": 0},
            "selected_nodes": [{"name": "Cheolsu"}],
        },
        "status": "completed",
    }
    view = _build_step_view(bp, raw, status="completed")
    assert view is not None
    assert view["output"]["pick_breakdown"]["recency"] == 7
    assert view["output"]["selected_nodes"][0]["name"] == "Cheolsu"


def test_empty_trace_layout_has_quiz_path():
    layout = build_flow_layout({"steps": [], "status": "pending"})
    quiz_nodes = [n for n in layout["nodes"] if n.get("phase") == "quiz_path"]
    assert len(quiz_nodes) >= len(QUIZ_NODES)
    assert all(n["status"] == "pending" for n in quiz_nodes)
