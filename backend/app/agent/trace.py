"""In-memory ring buffer of agent runs, for the developer Agent Flow page.

Single-process (single uvicorn worker) assumption keeps this simple. Nothing
here is persisted; only the most recent `MAXLEN` runs are kept.
"""

import time
import uuid
from collections import deque
from dataclasses import asdict, dataclass, field

MAXLEN = 50
_MAX_FIELD_CHARS = 4000


def _truncate(value):
    """Keep trace payloads small and JSON-safe."""
    if isinstance(value, str):
        return value if len(value) <= _MAX_FIELD_CHARS else value[:_MAX_FIELD_CHARS] + "…"
    if isinstance(value, dict):
        return {k: _truncate(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_truncate(v) for v in value[:50]]
    return value


@dataclass
class AgentStep:
    order: int
    type: str  # "llm" | "tool"
    name: str
    input: dict
    output: dict
    latency_ms: int
    tokens: int = 0
    ts: float = field(default_factory=time.time)


@dataclass
class AgentRun:
    id: str
    mode: str
    created_at: float = field(default_factory=time.time)
    status: str = "running"  # running | done | error
    latency_ms: int = 0
    total_tokens: int = 0
    error: str | None = None
    steps: list[AgentStep] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)

    def summary(self) -> dict:
        return {
            "id": self.id,
            "mode": self.mode,
            "created_at": self.created_at,
            "status": self.status,
            "latency_ms": self.latency_ms,
            "total_tokens": self.total_tokens,
            "step_count": len(self.steps),
        }


class TraceStore:
    def __init__(self, maxlen: int = MAXLEN) -> None:
        self._runs: deque[AgentRun] = deque(maxlen=maxlen)
        self._by_id: dict[str, AgentRun] = {}

    def start_run(self, mode: str) -> str:
        run = AgentRun(id=uuid.uuid4().hex, mode=mode)
        if len(self._runs) == self._runs.maxlen and self._runs:
            evicted = self._runs[0]
            self._by_id.pop(evicted.id, None)
        self._runs.append(run)
        self._by_id[run.id] = run
        return run.id

    def add_step(
        self,
        run_id: str,
        *,
        type: str,
        name: str,
        input: dict,
        output: dict,
        latency_ms: int,
        tokens: int = 0,
    ) -> None:
        run = self._by_id.get(run_id)
        if run is None:
            return
        run.steps.append(
            AgentStep(
                order=len(run.steps),
                type=type,
                name=name,
                input=_truncate(input),
                output=_truncate(output),
                latency_ms=latency_ms,
                tokens=tokens,
            )
        )
        run.total_tokens += tokens

    def finish_run(
        self, run_id: str, *, status: str = "done", error: str | None = None
    ) -> None:
        run = self._by_id.get(run_id)
        if run is None:
            return
        run.status = status
        run.error = error
        run.latency_ms = int((time.time() - run.created_at) * 1000)

    def get(self, run_id: str) -> AgentRun | None:
        return self._by_id.get(run_id)

    def latest(self) -> AgentRun | None:
        return self._runs[-1] if self._runs else None

    def list_summaries(self) -> list[dict]:
        return [r.summary() for r in reversed(self._runs)]


tracer = TraceStore()
