"""LangChain-style pipeline tracer — persists steps + artifacts to debug_runs/."""

from __future__ import annotations

import json
import shutil
import uuid
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .config import get_settings
from .json_util import dumps_json, json_safe
from .pipeline_flow import flow_layout_for_trace


@dataclass
class ArtifactRef:
    name: str
    relative_path: str
    media_type: str = "text/plain"


@dataclass
class PipelineStep:
    step_id: str
    name: str
    type: str  # storage | api | llm | graph | embed | policy
    phase: str  # fast_path | slow_path | manual_graph_path | quiz_path
    started_at: str
    ended_at: str | None = None
    latency_ms: int | None = None
    status: str = "running"
    model: str | None = None
    system_prompt: str | None = None
    input: dict[str, Any] = field(default_factory=dict)
    output: dict[str, Any] = field(default_factory=dict)
    error: str | None = None
    artifacts: list[ArtifactRef] = field(default_factory=list)


@dataclass
class PipelineRun:
    run_id: str
    entry_id: str
    started_at: str
    completed_at: str | None = None
    status: str = "running"
    debug_dir: str = ""
    current_phase: str = "fast_path"
    timing: dict[str, int] = field(default_factory=dict)
    steps: list[PipelineStep] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def _step_from_dict(data: dict) -> PipelineStep:
    artifacts = [ArtifactRef(**a) for a in data.get("artifacts", [])]
    return PipelineStep(
        step_id=data["step_id"],
        name=data["name"],
        type=data["type"],
        phase=data.get("phase", "fast_path"),
        started_at=data["started_at"],
        ended_at=data.get("ended_at"),
        latency_ms=data.get("latency_ms"),
        status=data.get("status", "completed"),
        model=data.get("model"),
        system_prompt=data.get("system_prompt"),
        input=data.get("input") or {},
        output=data.get("output") or {},
        error=data.get("error"),
        artifacts=artifacts,
    )


def _run_from_dict(data: dict) -> PipelineRun:
    steps = [_step_from_dict(s) for s in data.get("steps", [])]
    return PipelineRun(
        run_id=data["run_id"],
        entry_id=data["entry_id"],
        started_at=data["started_at"],
        completed_at=data.get("completed_at"),
        status=data.get("status", "running"),
        debug_dir=data.get("debug_dir", ""),
        current_phase=data.get("current_phase", "fast_path"),
        timing=data.get("timing") or {},
        steps=steps,
    )


class PipelineTracer:
    def __init__(self, entry_id: uuid.UUID, *, resume: dict | None = None) -> None:
        settings = get_settings()
        self.entry_id = entry_id
        self.root = Path(settings.debug_runs_dir) / str(entry_id)
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "audio").mkdir(exist_ok=True)
        (self.root / "steps").mkdir(exist_ok=True)

        if resume:
            self.run_id = resume["run_id"]
            self.run = _run_from_dict(resume)
        else:
            self.run_id = str(uuid.uuid4())
            self.run = PipelineRun(
                run_id=self.run_id,
                entry_id=str(entry_id),
                started_at=_now_iso(),
                debug_dir=self.debug_dir_relative,
            )

    @classmethod
    def resume(cls, entry_id: uuid.UUID, trace: dict | None) -> PipelineTracer:
        if trace:
            return cls(entry_id, resume=trace)
        trace_path = Path(get_settings().debug_runs_dir) / str(entry_id) / "trace.json"
        if trace_path.is_file():
            return cls(entry_id, resume=json.loads(trace_path.read_text(encoding="utf-8")))
        return cls(entry_id)

    @property
    def debug_dir_relative(self) -> str:
        return f"debug_runs/{self.entry_id}"

    def begin_step(
        self,
        name: str,
        type_: str,
        *,
        phase: str | None = None,
        model: str | None = None,
        system_prompt: str | None = None,
        input_data: dict | None = None,
    ) -> PipelineStep:
        self.close_stale_running_steps({name})
        active_phase = phase or self.run.current_phase
        step = PipelineStep(
            step_id=f"{len(self.run.steps) + 1}",
            name=name,
            type=type_,
            phase=active_phase,
            started_at=_now_iso(),
            model=model,
            system_prompt=system_prompt,
            input=input_data or {},
        )
        self.run.steps.append(step)
        return step

    def close_stale_running_steps(self, names: set[str] | None = None) -> None:
        """Mark orphaned running steps as error (e.g. uvicorn reload mid-pipeline)."""
        allowed = names or {"incremental_graph_pipeline"}
        for step in self.run.steps:
            if step.name in allowed and step.status == "running":
                step.status = "error"
                step.error = step.error or "interrupted (server reload or crash before finish)"
                step.ended_at = _now_iso()

    def finish_step(
        self,
        step: PipelineStep,
        *,
        output: dict | None = None,
        error: str | None = None,
        artifacts: list[tuple[str, str | dict, str]] | None = None,
    ) -> None:
        step.ended_at = _now_iso()
        started = datetime.fromisoformat(step.started_at)
        ended = datetime.fromisoformat(step.ended_at)
        step.latency_ms = int((ended - started).total_seconds() * 1000)
        step.status = "error" if error else "completed"
        step.output = output or {}
        step.error = error
        if artifacts:
            for art_name, content, media in artifacts:
                rel = f"steps/{step.step_id}_{step.name}_{art_name}"
                path = self.root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                if media.startswith("application/json"):
                    path.write_text(
                        dumps_json(content, ensure_ascii=False, indent=2),
                        encoding="utf-8",
                    )
                elif isinstance(content, bytes):
                    path.write_bytes(content)
                else:
                    path.write_text(str(content), encoding="utf-8")
                step.artifacts.append(
                    ArtifactRef(name=art_name, relative_path=rel, media_type=media)
                )

    def save_audio_bytes(self, data: bytes, filename: str) -> ArtifactRef:
        ext = Path(filename).suffix or ".wav"
        dest_rel = f"audio/original{ext}"
        dest = self.root / dest_rel
        dest.write_bytes(data)
        return ArtifactRef(name=filename, relative_path=dest_rel, media_type="audio/*")

    def _compute_timing(self) -> dict[str, int]:
        timing: dict[str, int] = {"fast_path_ms": 0, "slow_path_ms": 0, "total_ms": 0}
        for step in self.run.steps:
            if step.latency_ms is None:
                continue
            key = f"{step.phase}_ms"
            timing[key] = timing.get(key, 0) + step.latency_ms
            timing["total_ms"] += step.latency_ms
        return timing

    def finish_fast(self) -> dict:
        self.run.current_phase = "fast_path"
        self.run.timing = self._compute_timing()
        self.run.status = "fast_path_done"
        return self._persist()

    def finish(self, status: str = "completed") -> dict:
        self.run.completed_at = _now_iso()
        self.run.status = status
        self.run.timing = self._compute_timing()
        return self._persist()

    def checkpoint(self) -> dict:
        """Persist in-progress trace (e.g. before background graph apply)."""
        self.run.timing = self._compute_timing()
        return self._persist()

    def _persist(self) -> dict:
        data = json_safe(self.run.to_dict())
        data["flow_layout"] = flow_layout_for_trace(data)
        trace_path = self.root / "trace.json"
        trace_path.write_text(
            dumps_json(data, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        return data


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()
