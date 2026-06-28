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
    assert "lightrag_vector" in ids
    assert "speaker_context_resolve" in ids
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


def test_layout_uses_latest_incremental_step():
    trace = {
        "steps": [
            {
                "step_id": "5",
                "name": "incremental_graph_pipeline",
                "type": "graph",
                "phase": "slow_path",
                "status": "running",
                "output": {},
                "input": {"transcript": "old"},
            },
            {
                "step_id": "6",
                "name": "incremental_graph_pipeline",
                "type": "graph",
                "phase": "slow_path",
                "status": "completed",
                "output": {
                    "mode": "preview",
                    "triple_count": 2,
                    "filtered_extract_count": 2,
                    "substeps": {"extract": 2, "vector_queries": 2, "merge_decisions": 2},
                    "triples": [{"source_name": "A", "relation": "r", "target_name": "B"}],
                    "entities": [{"name": "A", "type": "Entity", "action": "NEW", "candidates": []}],
                },
                "input": {"transcript": "new"},
                "artifacts": [
                    {
                        "name": "extract_triples.json",
                        "relative_path": "steps/6_incremental_graph_pipeline_extract_triples.json",
                        "media_type": "application/json",
                    }
                ],
            },
        ]
    }
    layout = build_flow_layout(trace)
    extract = next(n for n in layout["nodes"] if n["id"] == "lightrag_extract")
    assert extract["step_id"] == "6"
    assert extract["step"]["name"] == "lightrag_extract"
    assert extract["step"]["output"]["filtered_extract_count"] == 2
    review = next(n for n in layout["nodes"] if n["id"] == "graph_review_apply")
    assert review["status"] == "waiting_user"
    extract_view = extract["step"]
    assert extract_view["name"] == "lightrag_extract"
    assert "transcript" in (extract_view.get("input") or {})
    assert "triples" in (extract_view.get("output") or {})
    vector = next(n for n in layout["nodes"] if n["id"] == "lightrag_vector")
    assert vector["step"]["name"] == "lightrag_vector"
    assert vector["step"]["output"]["vector_queries"] == 2
    print("OK latest incremental step")


def test_layout_speaker_context_step():
    trace = {
        "steps": [
            {
                "step_id": "slow0",
                "name": "slow_path_start",
                "type": "policy",
                "phase": "slow_path",
                "status": "completed",
                "input": {},
                "output": {},
            },
            {
                "step_id": "sp1",
                "name": "speaker_context_resolve",
                "type": "graph",
                "phase": "slow_path",
                "status": "completed",
                "input": {"entry_id": "e1"},
                "output": {
                    "confirmed_speaker_count": 1,
                    "pre_confirmed_mappings": 1,
                    "confirmed_speakers": [
                        {
                            "person_name": "Alice",
                            "node_id": "n1",
                            "node_name": "Alice",
                        }
                    ],
                },
                "artifacts": [
                    {
                        "name": "speaker_context.json",
                        "relative_path": "steps/sp1_speaker_context.json",
                    }
                ],
            },
        ]
    }
    layout = build_flow_layout(trace)
    spk = next(n for n in layout["nodes"] if n["id"] == "speaker_context_resolve")
    assert spk["status"] == "completed"
    assert spk["step"]["output"]["confirmed_speaker_count"] == 1
    assert "speaker_context_resolve" in bp_ids(get_pipeline_blueprint())
    print("OK speaker context step")


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


def test_blueprint_has_manual_graph_nodes():
    bp = get_pipeline_blueprint()
    ids = {n["id"] for n in bp["nodes"]}
    assert "precision_text_ingest" in ids
    assert "manual_graph_trigger" in ids
    assert "manual_graph_staging" in ids
    assert "lightrag_extract" in ids
    assert "graph_review_apply" in ids
    print("OK blueprint manual graph nodes")


def test_layout_manual_graph_path():
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
                "name": "manual_graph_trigger",
                "type": "policy",
                "phase": "manual_graph_path",
                "status": "completed",
                "output": {},
                "input": {},
            },
            {
                "step_id": "4",
                "name": "speaker_context_resolve",
                "type": "graph",
                "phase": "manual_graph_path",
                "status": "completed",
                "output": {
                    "confirmed_speaker_count": 2,
                    "entry_source": "precision_text",
                    "confirmed_speakers": [{"person_name": "A"}],
                },
                "input": {},
            },
            {
                "step_id": "5",
                "name": "incremental_graph_pipeline",
                "type": "graph",
                "phase": "manual_graph_path",
                "status": "completed",
                "output": {
                    "mode": "manual_extract",
                    "filtered_extract_count": 2,
                    "triple_count": 2,
                    "substeps": {"extract": 2, "vector_queries": 1, "merge_decisions": 1},
                    "triples": [{"source_name": "A", "relation": "r", "target_name": "B"}],
                },
                "input": {"transcript": "dialogue"},
            },
            {
                "step_id": "6",
                "name": "manual_graph_staging",
                "type": "graph",
                "phase": "manual_graph_path",
                "status": "completed",
                "output": {"entity_count": 2, "mode": "manual"},
                "input": {},
            },
        ]
    }
    layout = flow_layout_for_trace(trace)
    by_id = {n["id"]: n for n in layout["nodes"]}
    assert by_id["precision_text_ingest"]["status"] == "completed"
    assert by_id["manual_graph_trigger"]["status"] == "completed"
    assert by_id["speaker_context_resolve"]["status"] == "completed"
    assert by_id["lightrag_extract"]["status"] == "completed"
    assert by_id["manual_graph_staging"]["status"] == "completed"
    assert by_id["slow_path_start"]["status"] == "skipped"
    assert by_id["lightrag_vector"]["status"] == "skipped"
    print("OK manual graph path layout")


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


def bp_ids(bp):
    return {n["id"] for n in bp["nodes"]}


if __name__ == "__main__":
    test_blueprint_has_branch_nodes()
    test_blueprint_has_manual_graph_nodes()
    test_blueprint_has_quiz_audio_node()
    test_layout_whisper_diar_branch()
    test_layout_uses_latest_incremental_step()
    test_layout_speaker_context_step()
    test_layout_manual_graph_path()
    test_text_journal_flow_layout()
    test_layout_quiz_audio_step()
