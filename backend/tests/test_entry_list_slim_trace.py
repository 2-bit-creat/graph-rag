"""The entry list ships a trimmed pipeline trace.

Rendering the journal list only needs each step's name/error (the mobile
`journalTraceError` helper and the pipeline panel's offline fallback). The rest
of the trace — `flow_layout` geometry plus every step's raw LLM prompt and I/O —
made `pipeline_trace` 81% of the list response. It is dropped here; the full
trace still comes from GET /journal/entries/{id}/trace.
"""

from app.routers.journal import _slim_pipeline_trace


def _trace() -> dict:
    return {
        "run_id": "r1",
        "status": "graph_failed",
        "graph_status": "graph_failed",
        "flow_layout": {"nodes": [{"x": 1, "y": 2}] * 100},
        "steps": [
            {
                "step_id": "s1",
                "name": "transcribe",
                "type": "llm",
                "phase": "fast",
                "status": "ok",
                "error": None,
                "model": "whisper-1",
                "latency_ms": 1200,
                "started_at": "2026-08-08T00:00:00Z",
                "ended_at": "2026-08-08T00:00:01Z",
                "system_prompt": "x" * 5000,
                "input": "y" * 5000,
                "output": "z" * 5000,
                "artifacts": ["a.json"],
            },
            {
                "name": "kg_extract",
                "status": "failed",
                "error": "rate limited by provider",
                "system_prompt": "x" * 5000,
            },
        ],
    }


def test_drops_the_debug_bulk():
    slim = _slim_pipeline_trace(_trace())

    assert "flow_layout" not in slim
    for step in slim["steps"]:
        assert not {"system_prompt", "input", "output", "artifacts"} & step.keys()


def test_keeps_what_the_list_renders():
    slim = _slim_pipeline_trace(_trace())

    # The failure reason is the one thing the list actually surfaces.
    assert [s.get("error") for s in slim["steps"]][-1] == "rate limited by provider"
    assert [s["name"] for s in slim["steps"]] == ["transcribe", "kg_extract"]

    first = slim["steps"][0]
    assert first["status"] == "ok"
    assert first["latency_ms"] == 1200
    assert first["model"] == "whisper-1"

    # Top-level status fields drive the row's phase label.
    assert slim["status"] == "graph_failed"
    assert slim["graph_status"] == "graph_failed"
    assert slim["run_id"] == "r1"


def test_is_a_large_size_reduction():
    import json

    full = _trace()
    before = len(json.dumps(full))
    after = len(json.dumps(_slim_pipeline_trace(full)))

    assert after < before * 0.1
    # Slimming must not mutate the ORM-owned trace dict.
    assert "flow_layout" in full
    assert "system_prompt" in full["steps"][0]


def test_passes_through_non_dict_traces():
    assert _slim_pipeline_trace(None) is None
    assert _slim_pipeline_trace("not a dict") == "not a dict"
    assert _slim_pipeline_trace({"steps": None}) == {"steps": None}
