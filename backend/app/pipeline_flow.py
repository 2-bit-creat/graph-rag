"""Journal pipeline flow blueprint + trace → 2D layout resolver.

The mobile Pipeline tab renders `flow_layout` from persisted traces.
When backend steps or branches change, update BLUEPRINT here only.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

BLUEPRINT_VERSION = 10


@dataclass(frozen=True)
class FlowBlueprintNode:
    id: str
    label: str
    step_type: str
    phase: str
    col: int
    row: int
    optional: bool = False
    branch_group: str | None = None
    match_names: tuple[str, ...] = ()
    io_hint: str = ""


@dataclass(frozen=True)
class FlowBlueprintEdge:
    source: str
    target: str
    label: str = "output"


# --- Canonical DAG (cols = time, rows = branches) --------------------------------

FAST_NODES: tuple[FlowBlueprintNode, ...] = (
    FlowBlueprintNode(
        "precision_text_ingest",
        "라벨링\n입력",
        "transform",
        "fast_path",
        0,
        0,
        branch_group="ingest",
        match_names=("precision_text_ingest",),
        io_hint="dialogue → segments",
    ),
    FlowBlueprintNode(
        "audio_ingest",
        "오디오\n수집",
        "storage",
        "fast_path",
        0,
        2,
        branch_group="ingest",
        match_names=("audio_ingest",),
        io_hint="bytes → storage_key",
    ),
    FlowBlueprintNode(
        "audio_vad_trim",
        "무음\n제거",
        "transform",
        "fast_path",
        1,
        2,
        match_names=("audio_vad_trim",),
        io_hint="wav → trimmed wav",
    ),
    FlowBlueprintNode(
        "speaker_diarize",
        "화자\n분리",
        "transform",
        "fast_path",
        2,
        2,
        match_names=("speaker_diarize",),
        io_hint="audio → segments",
    ),
    FlowBlueprintNode(
        "speaker_voice_memory",
        "음성\n메모리",
        "embed",
        "fast_path",
        3,
        1,
        optional=True,
        match_names=("speaker_voice_memory",),
        io_hint="segments → profiles",
    ),
    FlowBlueprintNode(
        "whisper_stt_diar",
        "Deepgram\nSTT",
        "api",
        "fast_path",
        3,
        2,
        branch_group="stt",
        match_names=("whisper_stt",),
        io_hint="diarized text",
    ),
    FlowBlueprintNode(
        "whisper_stt_api",
        "Whisper\nSTT",
        "api",
        "fast_path",
        3,
        3,
        branch_group="stt",
        match_names=("whisper_stt",),
        io_hint="audio → transcript",
    ),
    FlowBlueprintNode(
        "gpt_cleanup_translate",
        "GPT\n정제·번역",
        "llm",
        "fast_path",
        4,
        1,
        match_names=("gpt_cleanup_translate",),
        io_hint="ko → clean + en",
    ),
    FlowBlueprintNode(
        "fast_path_complete",
        "정제\n완료",
        "policy",
        "fast_path",
        5,
        1,
        match_names=("fast_path_complete",),
        io_hint="status=ready",
    ),
)

# Graph path — matches the current Statement/Concept architecture (kg_build.py):
# an LLM draft step, then a human-reviewed commit. There is no more "auto" vs
# "manual" branch — every entry goes through draft → review (client-side) → apply.
GRAPH_NODES: tuple[FlowBlueprintNode, ...] = (
    FlowBlueprintNode(
        "statement_graph_draft",
        "그래프\n드래프트",
        "llm",
        "slow_path",
        0,
        0,
        match_names=("statement_graph_draft",),
        io_hint="transcript → claims 초안",
    ),
    FlowBlueprintNode(
        "graph_apply",
        "검토·확정\n커밋",
        "graph",
        "slow_path",
        1,
        0,
        match_names=("graph_apply",),
        io_hint="검토된 claims → DB",
    ),
)

QUIZ_NODES: tuple[FlowBlueprintNode, ...] = (
    FlowBlueprintNode(
        "quiz_manual_trigger",
        "퀴즈\n시작",
        "policy",
        "quiz_path",
        0,
        0,
        optional=True,
        match_names=("quiz_manual_trigger",),
        io_hint="생성/자동충전 + 언어",
    ),
    FlowBlueprintNode(
        "quiz_level_load",
        "레벨\n로드",
        "policy",
        "quiz_path",
        1,
        0,
        match_names=("quiz_level_load",),
        io_hint="settings + current_level",
    ),
    FlowBlueprintNode(
        "quiz_source_fetch",
        "소스\n수집",
        "graph",
        "quiz_path",
        2,
        0,
        # bundle_seed_select / composition_seed_select are the current bundle-path
        # equivalents; graph_context_resolve is the legacy vocab-quiz variant.
        match_names=(
            "quiz_source_fetch",
            "bundle_seed_select",
            "composition_seed_select",
            "graph_context_resolve",
        ),
        io_hint="Statement 시드 회전 (언어별)",
    ),
    FlowBlueprintNode(
        "quiz_llm_generate",
        "GPT\n번들",
        "llm",
        "quiz_path",
        3,
        0,
        match_names=(
            "quiz_llm_generate",
            "bundle_llm_generate",
            "composition_drill_llm_generate",
        ),
        io_hint="1콜 → 4유형 (gpt-4o-mini)",
    ),
    FlowBlueprintNode(
        "quiz_validate",
        "검증",
        "policy",
        "quiz_path",
        4,
        0,
        optional=True,
        match_names=("quiz_validate",),
        io_hint="schema + blank/order (번들 내부)",
    ),
    FlowBlueprintNode(
        "quiz_enqueue_new",
        "신규큐\n적재",
        "storage",
        "quiz_path",
        5,
        0,
        match_names=("quiz_enqueue_new", "composition_quiz_persist"),
        io_hint="4유형 → 언어별 큐",
    ),
    FlowBlueprintNode(
        "quiz_audio_tts",
        "Edge-TTS\n음성",
        "api",
        "quiz_path",
        6,
        0,
        optional=True,
        match_names=("quiz_audio_tts",),
        io_hint="sentence_en → mp3 (선택)",
    ),
    FlowBlueprintNode(
        "quiz_queue_pick",
        "큐\n출제",
        "policy",
        "quiz_path",
        7,
        0,
        optional=True,
        match_names=("quiz_queue_pick",),
        io_hint="7:3 per type",
    ),
    FlowBlueprintNode(
        "quiz_sm2_update",
        "SM-2\n갱신",
        "policy",
        "quiz_path",
        8,
        0,
        optional=True,
        match_names=("quiz_sm2_update",),
        io_hint="answer → next_review",
    ),
)

QUIZ_EDGES: tuple[FlowBlueprintEdge, ...] = (
    FlowBlueprintEdge("quiz_manual_trigger", "quiz_level_load", "trigger"),
    FlowBlueprintEdge("quiz_level_load", "quiz_source_fetch", "level"),
    FlowBlueprintEdge("quiz_source_fetch", "quiz_llm_generate", "context"),
    FlowBlueprintEdge("quiz_llm_generate", "quiz_validate", "raw"),
    FlowBlueprintEdge("quiz_validate", "quiz_enqueue_new", "validated"),
    FlowBlueprintEdge("quiz_enqueue_new", "quiz_audio_tts", "quiz_id"),
    FlowBlueprintEdge("quiz_audio_tts", "quiz_queue_pick", "audio"),
    FlowBlueprintEdge("quiz_queue_pick", "quiz_sm2_update", "session"),
)

QUIZ_BRIDGE_EDGE = FlowBlueprintEdge("fast_path_complete", "quiz_manual_trigger", "수동 퀴즈")

GRAPH_EDGES: tuple[FlowBlueprintEdge, ...] = (
    FlowBlueprintEdge("statement_graph_draft", "graph_apply", "사용자 검토 후 확정"),
)

TEXT_FAST_NODE_IDS = frozenset(
    {"precision_text_ingest", "gpt_cleanup_translate", "fast_path_complete"}
)

TEXT_FAST_EDGES: tuple[FlowBlueprintEdge, ...] = (
    FlowBlueprintEdge("precision_text_ingest", "gpt_cleanup_translate", "labeled"),
    FlowBlueprintEdge("gpt_cleanup_translate", "fast_path_complete", "json"),
)

BRIDGE_EDGE = FlowBlueprintEdge("fast_path_complete", "statement_graph_draft", "그래프 생성 버튼")

FAST_EDGES: tuple[FlowBlueprintEdge, ...] = (
    FlowBlueprintEdge("precision_text_ingest", "gpt_cleanup_translate", "labeled"),
    FlowBlueprintEdge("audio_ingest", "audio_vad_trim", "file"),
    FlowBlueprintEdge("audio_vad_trim", "speaker_diarize", "audio"),
    FlowBlueprintEdge("speaker_diarize", "speaker_voice_memory", "segments"),
    FlowBlueprintEdge("speaker_diarize", "whisper_stt_diar", "transcript"),
    FlowBlueprintEdge("speaker_diarize", "whisper_stt_api", "audio"),
    FlowBlueprintEdge("speaker_voice_memory", "gpt_cleanup_translate", "profiles"),
    FlowBlueprintEdge("whisper_stt_diar", "gpt_cleanup_translate", "text"),
    FlowBlueprintEdge("whisper_stt_api", "gpt_cleanup_translate", "text"),
    FlowBlueprintEdge("gpt_cleanup_translate", "fast_path_complete", "json"),
)


def get_pipeline_blueprint() -> dict[str, Any]:
    """Static blueprint for docs / frontend fallback."""
    return {
        "version": BLUEPRINT_VERSION,
        "nodes": [
            _node_dict(n)
            for n in (*FAST_NODES, *GRAPH_NODES, *QUIZ_NODES)
        ],
        "edges": [
            _edge_dict(e)
            for e in (
                *FAST_EDGES,
                *GRAPH_EDGES,
                BRIDGE_EDGE,
                QUIZ_BRIDGE_EDGE,
                *QUIZ_EDGES,
            )
        ],
    }


def build_flow_layout(trace: dict[str, Any]) -> dict[str, Any]:
    """Map executed trace steps onto the 2D blueprint."""
    steps = []
    for raw in trace.get("steps") or []:
        if not isinstance(raw, dict):
            continue
        step = dict(raw)
        if (
            step.get("name") == "incremental_graph_pipeline"
            and step.get("status") == "running"
        ):
            step["status"] = "error"
            step["error"] = step.get("error") or "interrupted (never finished)"
        steps.append(step)
    step_by_name: dict[str, list[dict]] = {}
    for raw in steps:
        name = raw.get("name") or ""
        step_by_name.setdefault(name, []).append(raw)

    layout_nodes: list[dict[str, Any]] = []
    layout_edges: list[dict[str, Any]] = []

    # --- Fast path branch resolution -----------------------------------------
    voice_ran = _has_step(step_by_name, "speaker_voice_memory")
    whisper = _first_step(step_by_name, "whisper_stt")
    whisper_branch = _whisper_branch(whisper)
    ingest_branch = _ingest_branch(step_by_name)

    for bp in FAST_NODES:
        step = _resolve_step(
            bp,
            step_by_name,
            whisper_branch=whisper_branch,
            ingest_branch=ingest_branch,
        )
        status = _node_status(
            bp,
            step,
            voice_ran=voice_ran,
            whisper_branch=whisper_branch,
            ingest_branch=ingest_branch,
        )
        layout_nodes.append(
            _layout_node(bp, step, status, row_offset=0, phase_label="Fast Path")
        )

    for edge in FAST_EDGES:
        layout_edges.append(_layout_edge(edge, layout_nodes, optional_skip=True))

    graph_row_offset = 4
    _append_graph_path_layout(
        steps,
        step_by_name,
        layout_nodes,
        layout_edges,
        row_offset=graph_row_offset,
        phase_label="Graph Path",
    )

    # --- Quiz path -----------------------------------------------------------
    quiz_row_offset = 12
    quiz_started = _has_quiz_step(step_by_name)

    for bp in QUIZ_NODES:
        step = _first_step(step_by_name, bp.id) if bp.match_names else None
        if step is None and bp.match_names:
            for name in bp.match_names:
                step = _first_step(step_by_name, name)
                if step is not None:
                    break
        status = _quiz_node_status(bp, step, quiz_started=quiz_started)
        layout_nodes.append(
            _layout_node(
                bp,
                step,
                status,
                row_offset=quiz_row_offset,
                phase_label="Quiz Path",
            )
        )

    for edge in QUIZ_EDGES:
        layout_edges.append(_layout_edge(edge, layout_nodes, optional_skip=True))

    quiz_bridge = _layout_edge(QUIZ_BRIDGE_EDGE, layout_nodes, optional_skip=False)
    quiz_bridge["active"] = quiz_started
    quiz_bridge["dashed"] = True
    layout_edges.append(quiz_bridge)

    return {
        "version": BLUEPRINT_VERSION,
        "nodes": layout_nodes,
        "edges": layout_edges,
        "phases": [
            {"id": "fast_path", "label": "입력·정제", "row_offset": 0},
            {"id": "graph_path", "label": "Graph Path", "row_offset": graph_row_offset},
            {"id": "quiz_path", "label": "Quiz Path", "row_offset": quiz_row_offset},
        ],
    }


def is_precision_text_trace(trace: dict[str, Any]) -> bool:
    if trace.get("entry_source") == "precision_text":
        return True
    for raw in trace.get("steps") or []:
        if isinstance(raw, dict) and raw.get("name") == "precision_text_ingest":
            return True
    return False


def flow_layout_for_trace(trace: dict[str, Any]) -> dict[str, Any]:
    """Pick text-only or full voice layout based on entry source."""
    if is_precision_text_trace(trace):
        return build_text_journal_flow_layout(trace)
    return build_flow_layout(trace)


def build_text_journal_flow_layout(trace: dict[str, Any]) -> dict[str, Any]:
    """Text ingest + unified graph path — no audio nodes."""
    steps = [s for s in (trace.get("steps") or []) if isinstance(s, dict)]
    step_by_name: dict[str, list[dict]] = {}
    for raw in steps:
        name = raw.get("name") or ""
        step_by_name.setdefault(name, []).append(raw)

    layout_nodes: list[dict[str, Any]] = []
    layout_edges: list[dict[str, Any]] = []

    text_fast_nodes = [n for n in FAST_NODES if n.id in TEXT_FAST_NODE_IDS]
    for bp in text_fast_nodes:
        step = _first_step(step_by_name, bp.match_names[0]) if bp.match_names else None
        status = "completed" if step and step.get("status") != "error" else (
            "error" if step and step.get("status") == "error" else "pending"
        )
        layout_nodes.append(
            _layout_node(bp, step, status, row_offset=0, phase_label="입력·정제")
        )

    for edge in TEXT_FAST_EDGES:
        layout_edges.append(_layout_edge(edge, layout_nodes, optional_skip=False))

    graph_row_offset = 2
    _append_graph_path_layout(
        steps,
        step_by_name,
        layout_nodes,
        layout_edges,
        row_offset=graph_row_offset,
        phase_label="Graph Path",
    )

    return {
        "version": BLUEPRINT_VERSION,
        "nodes": layout_nodes,
        "edges": layout_edges,
        "phases": [
            {"id": "fast_path", "label": "입력·정제", "row_offset": 0},
            {"id": "graph_path", "label": "Graph Path", "row_offset": graph_row_offset},
        ],
        "entry_source": "precision_text",
    }


def build_quiz_only_flow_layout(trace: dict[str, Any]) -> dict[str, Any]:
    """Quiz Path blueprint only — for problem-generation hub."""
    steps = [s for s in (trace.get("steps") or []) if isinstance(s, dict)]
    step_by_name: dict[str, list[dict]] = {}
    for raw in steps:
        name = raw.get("name") or ""
        step_by_name.setdefault(name, []).append(raw)

    layout_nodes: list[dict[str, Any]] = []
    layout_edges: list[dict[str, Any]] = []
    quiz_started = _has_quiz_step(step_by_name)

    for bp in QUIZ_NODES:
        step = _first_step(step_by_name, bp.id) if bp.match_names else None
        if step is None and bp.match_names:
            for name in bp.match_names:
                step = _first_step(step_by_name, name)
                if step is not None:
                    break
        status = _quiz_node_status(bp, step, quiz_started=quiz_started)
        layout_nodes.append(
            _layout_node(bp, step, status, row_offset=0, phase_label="Quiz Path")
        )

    for edge in QUIZ_EDGES:
        layout_edges.append(_layout_edge(edge, layout_nodes, optional_skip=True))

    return {
        "version": BLUEPRINT_VERSION,
        "nodes": layout_nodes,
        "edges": layout_edges,
        "phases": [{"id": "quiz_path", "label": "Quiz Path", "row_offset": 0}],
    }


# --- Helpers -------------------------------------------------------------------


def _ingest_branch(step_by_name: dict[str, list[dict]]) -> str | None:
    if _has_step(step_by_name, "precision_text_ingest"):
        return "precision_text_ingest"
    if _has_step(step_by_name, "audio_ingest"):
        return "audio_ingest"
    if _has_step(step_by_name, "audio_vad_trim") or _has_step(step_by_name, "speaker_diarize"):
        return "audio_ingest"
    return None


def _append_graph_path_layout(
    steps: list[dict],
    step_by_name: dict[str, list[dict]],
    layout_nodes: list[dict[str, Any]],
    layout_edges: list[dict[str, Any]],
    *,
    row_offset: int,
    phase_label: str,
) -> None:
    """Graph path: draft(LLM) → apply(commit). No auto/manual branch anymore —
    every entry goes through the same HITL draft → review → apply flow."""
    draft_step = _latest_step(step_by_name, "statement_graph_draft")
    apply_step = _latest_step(step_by_name, "graph_apply")
    graph_started = draft_step is not None

    for bp in GRAPH_NODES:
        step = draft_step if bp.id == "statement_graph_draft" else apply_step
        status = _graph_node_status(bp, step, graph_started=graph_started)
        layout_nodes.append(
            _layout_node(bp, step, status, row_offset=row_offset, phase_label=phase_label)
        )

    for edge in GRAPH_EDGES:
        layout_edges.append(_layout_edge(edge, layout_nodes, optional_skip=True))

    bridge = _layout_edge(BRIDGE_EDGE, layout_nodes, optional_skip=False)
    bridge["active"] = graph_started
    bridge["dashed"] = True
    layout_edges.append(bridge)


def _graph_node_status(
    bp: FlowBlueprintNode,
    step: dict | None,
    *,
    graph_started: bool,
) -> str:
    if not graph_started:
        return "pending"
    if step is None:
        # Draft ran but apply hasn't happened yet — waiting on the user's review.
        return "waiting_user" if bp.id == "graph_apply" else "pending"
    return "error" if step.get("status") == "error" else "completed"


def _has_quiz_step(step_by_name: dict[str, list[dict]]) -> bool:
    quiz_names = {
        "quiz_manual_trigger",
        "quiz_level_load",
        "quiz_source_fetch",
        "graph_context_resolve",
        "quiz_llm_generate",
        "quiz_validate",
        "quiz_enqueue_new",
        "quiz_audio_tts",
        "quiz_queue_pick",
        "quiz_sm2_update",
    }
    return any(step_by_name.get(n) for n in quiz_names)


def _quiz_node_status(
    bp: FlowBlueprintNode,
    step: dict | None,
    *,
    quiz_started: bool,
) -> str:
    if not quiz_started:
        return "pending"
    if step is None:
        return "skipped" if bp.optional else "pending"
    if step.get("status") == "error":
        return "error"
    return "completed"


def _node_dict(n: FlowBlueprintNode) -> dict[str, Any]:
    return {
        "id": n.id,
        "label": n.label,
        "type": n.step_type,
        "phase": n.phase,
        "col": n.col,
        "row": n.row,
        "optional": n.optional,
        "branch_group": n.branch_group,
        "match_names": list(n.match_names),
        "io_hint": n.io_hint,
    }


def _edge_dict(e: FlowBlueprintEdge) -> dict[str, Any]:
    return {"source": e.source, "target": e.target, "label": e.label}


def _has_step(step_by_name: dict[str, list[dict]], name: str) -> bool:
    return bool(step_by_name.get(name))


def _first_step(step_by_name: dict[str, list[dict]], name: str) -> dict | None:
    items = step_by_name.get(name) or []
    return items[0] if items else None


def _latest_step(step_by_name: dict[str, list[dict]], name: str) -> dict | None:
    """Prefer the latest completed/error step; fall back to last if still running."""
    items = step_by_name.get(name) or []
    for raw in reversed(items):
        if raw.get("status") in ("completed", "error"):
            return raw
    return items[-1] if items else None


def _whisper_branch(whisper: dict | None) -> str | None:
    if whisper is None:
        return None
    out = whisper.get("output") or {}
    if out.get("skipped") or out.get("source") == "diarization":
        return "whisper_stt_diar"
    return "whisper_stt_api"


def _resolve_step(
    bp: FlowBlueprintNode,
    step_by_name: dict[str, list[dict]],
    *,
    whisper_branch: str | None,
    ingest_branch: str | None = None,
) -> dict | None:
    if bp.branch_group == "ingest":
        if ingest_branch != bp.id:
            return None
        if bp.id == "precision_text_ingest":
            return _first_step(step_by_name, "precision_text_ingest")
        return _first_step(step_by_name, "audio_ingest") or _first_step(
            step_by_name, "audio_vad_trim"
        )
    if bp.branch_group == "stt":
        if whisper_branch != bp.id:
            return None
        return _first_step(step_by_name, "whisper_stt")
    if not bp.match_names:
        return None
    for name in bp.match_names:
        hit = _first_step(step_by_name, name)
        if hit is not None:
            return hit
    return None


def _node_status(
    bp: FlowBlueprintNode,
    step: dict | None,
    *,
    voice_ran: bool,
    whisper_branch: str | None,
    ingest_branch: str | None = None,
) -> str:
    if bp.branch_group == "ingest":
        if ingest_branch is None:
            return "pending"
        return "completed" if ingest_branch == bp.id else "skipped"
    if bp.branch_group == "stt":
        if whisper_branch is None:
            return "pending"
        return "completed" if whisper_branch == bp.id else "skipped"
    if bp.id == "speaker_voice_memory":
        if step is not None:
            return "completed" if step.get("status") != "error" else "error"
        return "skipped"

    if step is None:
        if bp.id in {
            "audio_vad_trim",
            "speaker_diarize",
            "speaker_voice_memory",
            "whisper_stt_diar",
            "whisper_stt_api",
        } and ingest_branch == "precision_text_ingest":
            return "skipped"
        return "pending"
    if step.get("status") == "error":
        return "error"
    return "completed"


def _build_step_view(
    bp: FlowBlueprintNode,
    raw: dict | None,
    *,
    status: str,
) -> dict[str, Any] | None:
    """Per-blueprint-node I/O slice for the pipeline inspector modal."""
    label = bp.label.replace("\n", " ")
    if raw is None:
        if status == "skipped":
            return {
                "name": bp.id,
                "label": label,
                "type": bp.step_type,
                "status": "skipped",
                "io_hint": bp.io_hint,
            }
        if status == "pending":
            return {
                "name": bp.id,
                "label": label,
                "type": bp.step_type,
                "status": "pending",
                "io_hint": bp.io_hint,
            }
        return None

    if bp.id == "graph_apply":
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": raw.get("input") or {},
            "output": {**out, "note": "검토된 claims를 Person→Statement→Concept 그래프로 커밋"},
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "precision_text_ingest":
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": raw.get("input") or {},
            "output": {
                "segment_count": out.get("segment_count"),
                "transcript_preview": out.get("transcript_preview"),
                "note": "사용자 라벨링 대화 → transcript_segments",
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "quiz_level_load":
        inp = raw.get("input") or {}
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": inp,
            "output": {
                "current_level": out.get("current_level"),
                "target_level": out.get("target_level"),
                "cefr_label": out.get("cefr_label"),
                "level_window": out.get("level_window"),
                "settings": inp.get("settings"),
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "quiz_source_fetch" and raw.get("name") == "graph_context_resolve":
        # Vocab-quiz variant (generate_quiz_item?vocab_node_id) — different
        # output shape than the seed/2-hop picker below.
        inp = raw.get("input") or {}
        out = raw.get("output") or {}
        return {
            "name": "graph_context_resolve",
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": {"vocab_node_id": inp.get("vocab_node_id")},
            "output": {
                "vocab_lemma": out.get("vocab_lemma"),
                "speaker_name": out.get("speaker_name"),
                "context_turns": out.get("context_turns"),
                "formatted_dialogue_preview": out.get("formatted_dialogue_preview"),
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "quiz_source_fetch":
        inp = raw.get("input") or {}
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": {
                "settings": inp.get("settings"),
                "entry_id": inp.get("entry_id"),
            },
            "output": {
                "seed_count": out.get("seed_count"),
                "seed_nodes": out.get("seed_nodes"),
                "selected_nodes": out.get("selected_nodes"),
                "pick_breakdown": out.get("pick_breakdown"),
                "candidate_count": out.get("candidate_count"),
                "graph_context_length": out.get("graph_context_length"),
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "quiz_llm_generate":
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "model": raw.get("model"),
            "system_prompt": raw.get("system_prompt"),
            "input": raw.get("input") or {},
            "output": {
                "difficulty_level": out.get("difficulty_level"),
                "quiz_type": out.get("quiz_type"),
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "quiz_validate":
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": raw.get("input") or {},
            "output": {
                "valid": out.get("valid"),
                "difficulty_level": out.get("difficulty_level"),
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "quiz_enqueue_new":
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": raw.get("input") or {},
            "output": {
                "quiz_id": out.get("quiz_id"),
                "difficulty_level": out.get("difficulty_level"),
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.id == "quiz_audio_tts":
        inp = raw.get("input") or {}
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "input": {
                "quiz_id": inp.get("quiz_id"),
                "sentence_en": inp.get("sentence_en"),
            },
            "output": {
                "audio_url": out.get("audio_url"),
                "available": out.get("available"),
            },
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    if bp.branch_group == "stt":
        inp = raw.get("input") or {}
        out = raw.get("output") or {}
        return {
            "name": bp.id,
            "label": label,
            "type": bp.step_type,
            "step_id": raw.get("step_id"),
            "latency_ms": raw.get("latency_ms"),
            "status": raw.get("status"),
            "model": raw.get("model"),
            "input": inp,
            "output": out,
            "error": raw.get("error"),
            "artifacts": raw.get("artifacts") or [],
        }

    view = {
        "name": bp.id,
        "label": label,
        "type": bp.step_type,
        "step_id": raw.get("step_id"),
        "latency_ms": raw.get("latency_ms"),
        "status": raw.get("status"),
        "model": raw.get("model"),
        "system_prompt": raw.get("system_prompt"),
        "input": raw.get("input") or {},
        "output": raw.get("output") or {},
        "error": raw.get("error"),
        "artifacts": raw.get("artifacts") or [],
    }
    if bp.id == "fast_path_complete":
        view["output"] = {
            **(view["output"] if isinstance(view["output"], dict) else {}),
            "note": "정제 완료 — '지식 그래프 생성' 버튼으로 그래프 드래프트 시작",
        }
    return view


def _layout_node(
    bp: FlowBlueprintNode,
    step: dict | None,
    status: str,
    *,
    row_offset: int,
    phase_label: str,
) -> dict[str, Any]:
    step_view = _build_step_view(bp, step, status=status)
    return {
        "id": bp.id,
        "label": bp.label,
        "type": bp.step_type,
        "phase": bp.phase,
        "phase_label": phase_label,
        "col": bp.col,
        "row": bp.row + row_offset,
        "optional": bp.optional,
        "branch_group": bp.branch_group,
        "io_hint": bp.io_hint,
        "status": status,
        "step_id": step.get("step_id") if step else None,
        "step_name": step.get("name") if step else None,
        "latency_ms": step.get("latency_ms") if step else None,
        "input_preview": _preview(step_view.get("input") if step_view else None),
        "output_preview": _preview(step_view.get("output") if step_view else None),
        "step": step_view,
    }


def _layout_edge(
    edge: FlowBlueprintEdge,
    nodes: list[dict[str, Any]],
    *,
    optional_skip: bool,
) -> dict[str, Any]:
    by_id = {n["id"]: n for n in nodes}
    src = by_id.get(edge.source)
    tgt = by_id.get(edge.target)
    active = True
    if optional_skip and src and tgt:
        if src["status"] == "skipped" or tgt["status"] == "skipped":
            active = False
        if src["status"] == "pending" or tgt["status"] == "pending":
            active = False
    return {
        "source": edge.source,
        "target": edge.target,
        "label": edge.label,
        "active": active,
    }


def _preview(value: Any, max_len: int = 80) -> str:
    if value is None:
        return ""
    if isinstance(value, dict):
        if not value:
            return ""
        parts = [f"{k}={_preview(v, 24)}" for k, v in list(value.items())[:4]]
        text = ", ".join(parts)
    elif isinstance(value, list):
        text = f"[{len(value)} items]"
    else:
        text = str(value)
    text = text.replace("\n", " ")
    return text if len(text) <= max_len else f"{text[: max_len - 1]}…"
