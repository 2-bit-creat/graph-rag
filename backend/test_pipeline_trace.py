"""Pipeline trace unit checks (no API key required for structure)."""

import uuid

from app.pipeline_trace import PipelineTracer


def test_tracer_phases_and_timing():
    entry_id = uuid.uuid4()
    tracer = PipelineTracer(entry_id)

    s1 = tracer.begin_step("audio", "storage", phase="fast_path")
    tracer.finish_step(s1, output={"ok": True})

    s2 = tracer.begin_step("stt", "api", phase="fast_path")
    tracer.finish_step(s2, output={"text": "hello"})

    fast = tracer.finish_fast()
    assert fast["status"] == "fast_path_done"
    assert fast["current_phase"] == "fast_path"
    assert fast["timing"]["fast_path_ms"] >= 0

    resumed = PipelineTracer.resume(entry_id, fast)
    s3 = resumed.begin_step("graph", "graph", phase="slow_path")
    resumed.finish_step(s3, output={"nodes": 1})

    done = resumed.finish("completed")
    assert done["timing"]["total_ms"] >= 0
    assert len(done["steps"]) == 3
    print("OK pipeline trace phases/timing")


if __name__ == "__main__":
    test_tracer_phases_and_timing()
