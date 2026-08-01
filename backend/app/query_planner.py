"""Bounded LLM query planner for GraphRAG.

The planner interprets natural language, but it never receives database access.
It may only emit this module's small JSON DSL; the server validates and executes
the approved retrieval primitives itself.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import date, datetime
from typing import Literal
from zoneinfo import ZoneInfo

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .config import get_settings
from .rag import _get_client
from .temporal import parse_time_window


AnswerIntent = Literal[
    "episodic_recall", "entity_recall", "topic_search", "comparison", "summary", "learning"
]
Retriever = Literal["temporal_sql", "entity_exact", "lexical", "dense", "graph", "learning_state"]


class PlanTime(BaseModel):
    model_config = ConfigDict(extra="forbid")
    start: date | None = None
    end: date | None = None
    constraint: Literal["hard", "soft"] = "soft"
    confidence: float = Field(default=0.0, ge=0.0, le=1.0)


class PlanEntity(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=120)
    canonical_id: str | None = None
    role: Literal["speaker", "mentioned", "any"] = "any"


class LearningPlan(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: bool = False
    mode: Literal["none", "optional_followup"] = "none"


class SearchPlan(BaseModel):
    model_config = ConfigDict(extra="forbid")
    answer_intent: AnswerIntent = "topic_search"
    time: PlanTime | None = None
    entities: list[PlanEntity] = Field(default_factory=list, max_length=4)
    topics: list[str] = Field(default_factory=list, max_length=6)
    # Empty means "any status" — see _keep_empty_event_status.
    event_status: list[Literal["happened", "planned", "cancelled", "hypothetical", "unknown"]] = Field(
        default_factory=list, max_length=5
    )
    retrievers: list[Retriever] = Field(default_factory=lambda: ["dense", "graph"], max_length=6)
    fusion: Literal["none", "weighted", "rrf"] = "rrf"
    rerank: bool = False
    result_limit: int = Field(default=12, ge=1, le=20)
    learning: LearningPlan = Field(default_factory=LearningPlan)

    @field_validator("topics")
    @classmethod
    def _clean_topics(cls, value: list[str]) -> list[str]:
        return [item.strip() for item in value if item and item.strip()][:6]

    @field_validator("event_status", mode="before")
    @classmethod
    def _keep_empty_event_status(cls, value):
        """Empty (or omitted) means every status is allowed.

        This used to default to ``["happened"]``, on the theory that recall
        should describe completed events only. In practice it deleted honest
        answers: the extractor labels a statement by what its *content* is about,
        so a meeting spent planning next steps becomes "planned" and vanished
        from "어제 뭐 했지?" even though the meeting itself plainly happened.

        What that default was protecting against — a future plan surfacing as a
        past event — is handled by the event date instead, which
        resolve_event_temporal puts in the future for "내일 …". So the window
        decides what is in scope, and status is carried into the answer context
        (see graph_retrieval._format_package) to be described rather than hidden.
        A non-empty list still filters, for questions actually about a status.
        """
        return list(value or [])


def _strictify_schema(schema: dict) -> dict:
    """Meet OpenAI structured-output's strict-object requirements."""
    if isinstance(schema, dict):
        properties = schema.get("properties")
        if isinstance(properties, dict):
            schema["required"] = list(properties)
            schema["additionalProperties"] = False
        for value in schema.values():
            _strictify_schema(value)
    elif isinstance(schema, list):
        for value in schema:
            _strictify_schema(value)
    return schema


_PLAN_SCHEMA = {
    "type": "json_schema",
    "json_schema": {
        "name": "graph_search_plan",
        "strict": True,
        "schema": _strictify_schema(SearchPlan.model_json_schema()),
    },
}


_PLANNER_PROMPT = """You plan retrieval for a personal knowledge graph and language-learning app.
Return only JSON matching the supplied schema. You have NO database or tool access.
Choose only retrievers needed for the question:
- temporal_sql for event date/status filters
- entity_exact for a named person/source
- lexical for exact terms, titles, names, numbers
- dense for semantic topic matching
- graph for connected memory expansion
- learning_state only for an explicit learning/review request
Use hard time constraints only when the user explicitly asks for a period. A date supplied
by the system as LOCKED_TIME is authoritative: include it unchanged and never widen or move it.
Leave event_status empty unless the question is itself about an event's status ("what got
cancelled?", "what am I planning?"). "What did I do yesterday" is NOT such a question — a day's
record includes the plans and ideas discussed that day, so an empty list is correct there.
Keep result_limit at most 20. Set learning optional_followup only when an episodic memory answer
could naturally offer a short target-language practice card; never turn the main answer into a quiz."""


@dataclass(frozen=True)
class PlannedQuery:
    plan: SearchPlan
    status: Literal["ok", "fallback"]
    locked_time: tuple[date, date] | None
    raw_plan: dict | None = None
    error: str | None = None


def _fallback_plan(message: str, locked_time: tuple[date, date] | None) -> SearchPlan:
    # This is a safety fallback, not an intent classifier: retain the user text
    # as a lexical/dense query and only rely on a deterministic date when known.
    retrievers: list[Retriever] = ["lexical", "dense", "graph"]
    time = None
    if locked_time:
        start, end = locked_time
        time = PlanTime(start=start, end=end, constraint="hard", confidence=1.0)
        retrievers.insert(0, "temporal_sql")
    return SearchPlan(
        answer_intent="episodic_recall" if locked_time else "topic_search",
        time=time,
        topics=[message],
        retrievers=retrievers,
        learning=LearningPlan(enabled=bool(locked_time), mode="optional_followup" if locked_time else "none"),
    )


def _lock_time(plan: SearchPlan, locked: tuple[date, date] | None) -> SearchPlan:
    if locked is None:
        return plan
    start, end = locked
    plan.time = PlanTime(start=start, end=end, constraint="hard", confidence=1.0)
    if "temporal_sql" not in plan.retrievers:
        plan.retrievers.insert(0, "temporal_sql")
    return plan


async def create_search_plan(message: str, *, now: datetime, tz: ZoneInfo, client=None) -> PlannedQuery:
    """Interpret a natural language query with a bounded small-model plan.

    Deterministically recognised calendar language is supplied as an immutable
    lock; all other intent interpretation belongs to the planner model.
    """
    locked = parse_time_window(message, tz, now)
    payload = {
        "question": message,
        "timezone": str(tz),
        "now": now.isoformat(),
        "locked_time": (
            {"start": locked[0].isoformat(), "end": locked[1].isoformat(), "constraint": "hard"}
            if locked else None
        ),
    }
    try:
        settings = get_settings()
        response = await (client or _get_client()).chat.completions.create(
            model=settings.graph_chat_planner_model or settings.openai_model,
            messages=[
                {"role": "system", "content": _PLANNER_PROMPT},
                {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
            ],
            temperature=0,
            max_tokens=settings.graph_chat_planner_max_tokens,
            timeout=settings.openai_timeout_sec,
            response_format=_PLAN_SCHEMA,
        )
        raw = (response.choices[0].message.content or "{}").strip()
        parsed = json.loads(raw)
        plan = _lock_time(SearchPlan.model_validate(parsed), locked)
        # A pure temporal SQL plan has no need for embedding or reranking.
        if plan.retrievers == ["temporal_sql"]:
            plan.fusion = "none"
            plan.rerank = False
        return PlannedQuery(plan=plan, status="ok", locked_time=locked, raw_plan=parsed)
    except Exception as exc:  # planner is optional; retrieval must remain available
        return PlannedQuery(
            plan=_fallback_plan(message, locked),
            status="fallback",
            locked_time=locked,
            error=f"{type(exc).__name__}: {exc}",
        )
