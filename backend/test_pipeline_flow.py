"""Pipeline flow layout unit checks."""

from app.pipeline_flow import (
    build_flow_layout,
    build_text_journal_flow_layout,
    flow_layout_for_trace,
    get_pipeline_blueprint,
)


def test_blueprint_has_branch_nodes():
    bp = get_pipeline_blueprint()
    ids = {n["id"] for n in bp["nodes"]}
    assert "whisper_stt_diar" in ids
    assert "whisper_stt_api" in ids
    assert "statement_graph_draft" in ids
    assert "graph_apply" in ids
    print("OK blueprint branch nodes")


def test_layout_whisper_diar_branch():
    trace = {
        "steps": [
            {
                "step_id": "1",
                "name": "whisper_stt",
                "type": "api",
                "phase": "fast_path",
                "status": "completed",
                "output": {"source": "diarization", "skipped": True},
                "input": {},
            }
        ]
    }
    layout = build_flow_layout(trace)
    by_id = {n["id"]: n for n in layout["nodes"]}
    assert by_id["whisper_stt_diar"]["status"] == "completed"
    assert by_id["whisper_stt_api"]["status"] == "skipped"
    print("OK whisper diar branch")


def test_layout_graph_draft_only_waits_for_apply():
    trace = {
        "steps": [
            {
                "step_id": "5",
                "name": "statement_graph_draft",
                "type": "llm",
                "phase": "slow_path",
                "status": "completed",
                "model": "gpt-4o-mini",
                "system_prompt": "You are a knowledge graph assistant...",
                "output": {
                    "claims": [{"speaker": "나", "title": "말차", "statement": "..."}],
                    "context_type": "개인일기",
                    "speaker_count": 1,
                },
                "input": {"entry_id": "e1", "user_prompt": "Fixed speaker: 나..."},
            },
        ]
    }
    layout = build_flow_layout(trace)
    draft = next(n for n in layout["nodes"] if n["id"] == "statement_graph_draft")
    assert draft["status"] == "completed"
    assert draft["step"]["system_prompt"] is not None
    assert draft["step"]["output"]["claims"][0]["speaker"] == "나"
    apply_node = next(n for n in layout["nodes"] if n["id"] == "graph_apply")
    assert apply_node["status"] == "waiting_user"
    print("OK graph draft waits for apply")


def test_layout_graph_apply_step():
    trace = {
        "steps": [
            {
                "step_id": "5",
                "name": "statement_graph_draft",
                "type": "llm",
                "phase": "slow_path",
                "status": "completed",
                "output": {"claims": [], "context_type": "개인일기", "speaker_count": 1},
                "input": {"entry_id": "e1"},
            },
            {
                "step_id": "6",
                "name": "graph_apply",
                "type": "graph",
                "phase": "slow_path",
                "status": "completed",
                "output": {"statement_count": 1, "concept_count": 2, "node_count": 4, "edge_count": 3},
                "input": {"claim_count": 1, "context_type": "개인일기", "user_edited": False},
            },
        ]
    }
    layout = build_flow_layout(trace)
    apply_node = next(n for n in layout["nodes"] if n["id"] == "graph_apply")
    assert apply_node["status"] == "completed"
    assert apply_node["step"]["output"]["node_count"] == 4
    print("OK graph apply step")


def test_blueprint_has_quiz_audio_node():
    bp = get_pipeline_blueprint()
    ids = {n["id"] for n in bp["nodes"]}
    assert "quiz_audio_tts" in ids
    print("OK quiz audio blueprint node")


def test_layout_quiz_audio_step():
    trace = {
        "steps": [
            {
                "step_id": "q1",
                "name": "quiz_manual_trigger",
                "type": "policy",
                "phase": "quiz_path",
                "status": "completed",
                "input": {},
                "output": {},
            },
            {
                "step_id": "q6",
                "name": "quiz_audio_tts",
                "type": "api",
                "phase": "quiz_path",
                "status": "completed",
                "input": {"quiz_id": "abc", "sentence_en": "Hello"},
                "output": {"audio_url": "/static/audio/abc.mp3", "available": True},
            },
        ]
    }
    layout = build_flow_layout(trace)
    node = next(n for n in layout["nodes"] if n["id"] == "quiz_audio_tts")
    assert node["status"] == "completed"
    assert node["step"]["output"]["audio_url"] == "/static/audio/abc.mp3"
    print("OK quiz audio layout step")


def test_blueprint_has_graph_path_nodes():
    bp = get_pipeline_blueprint()
    ids = {n["id"] for n in bp["nodes"]}
    assert "precision_text_ingest" in ids
    assert "statement_graph_draft" in ids
    assert "graph_apply" in ids
    print("OK blueprint graph path nodes")


def test_layout_precision_text_graph_path():
    trace = {
        "entry_source": "precision_text",
        "steps": [
            {
                "step_id": "1",
                "name": "precision_text_ingest",
                "type": "transform",
                "phase": "fast_path",
                "status": "completed",
                "output": {"segment_count": 2},
                "input": {},
            },
            {
                "step_id": "2",
                "name": "gpt_cleanup_translate",
                "type": "llm",
                "phase": "fast_path",
                "status": "completed",
                "output": {},
                "input": {},
            },
            {
                "step_id": "3",
                "name": "statement_graph_draft",
                "type": "llm",
                "phase": "slow_path",
                "status": "completed",
                "output": {"claims": [{"speaker": "A", "statement": "..."}], "context_type": "대화"},
                "input": {"entry_id": "e1"},
            },
            {
                "step_id": "4",
                "name": "graph_apply",
                "type": "graph",
                "phase": "slow_path",
                "status": "completed",
                "output": {"node_count": 3, "edge_count": 2},
                "input": {"claim_count": 1},
            },
        ]
    }
    layout = flow_layout_for_trace(trace)
    by_id = {n["id"]: n for n in layout["nodes"]}
    assert by_id["precision_text_ingest"]["status"] == "completed"
    assert by_id["statement_graph_draft"]["status"] == "completed"
    assert by_id["graph_apply"]["status"] == "completed"
    print("OK precision text graph path layout")


def test_text_journal_flow_layout():
    trace = {
        "entry_source": "precision_text",
        "steps": [
            {
                "step_id": "1",
                "name": "precision_text_ingest",
                "type": "transform",
                "phase": "fast_path",
                "status": "completed",
                "output": {"segment_count": 2},
                "input": {"line_count": 2},
            },
            {
                "step_id": "2",
                "name": "gpt_cleanup_translate",
                "type": "llm",
                "phase": "fast_path",
                "status": "completed",
                "input": {"transcript_ko": "x"},
                "output": {"translation_en": "hello"},
            },
            {
                "step_id": "3",
                "name": "fast_path_complete",
                "type": "policy",
                "phase": "fast_path",
                "status": "completed",
                "output": {},
                "input": {},
            },
        ],
    }
    layout = flow_layout_for_trace(trace)
    ids = {n["id"] for n in layout["nodes"]}
    assert "precision_text_ingest" in ids
    assert "audio_ingest" not in ids
    assert layout["entry_source"] == "precision_text"
    ingest = next(n for n in layout["nodes"] if n["id"] == "precision_text_ingest")
    assert ingest["step"] is not None
    assert ingest["step"]["input"]["line_count"] == 2
    print("OK text journal flow layout")


if __name__ == "__main__":
    test_blueprint_has_branch_nodes()
    test_blueprint_has_graph_path_nodes()
    test_blueprint_has_quiz_audio_node()
    test_layout_whisper_diar_branch()
    test_layout_graph_draft_only_waits_for_apply()
    test_layout_graph_apply_step()
    test_layout_precision_text_graph_path()
    test_text_journal_flow_layout()
    test_layout_quiz_audio_step()
