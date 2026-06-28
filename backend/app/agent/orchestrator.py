"""Agent orchestrator: a small OpenAI tool-calling loop driven by a mode policy.

Modes are policies over the same tools:
- study:   tutor conversation; MAY call search_graph when helpful (tool_choice=auto)
- explore: GraphRAG search FORCED, then answer + node ids for UI navigation
- build:   deterministic ontology extraction into a staging proposal
"""

import json
import time
from typing import Literal

from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..rag import _get_client
from ..schemas import ChatMessage
from . import tools
from .trace import tracer

Mode = Literal["study", "explore", "build", "review", "roleplay"]

_MAX_ITERATIONS = 4

SYSTEM_PROMPTS: dict[str, str] = {
    "study": (
        "You are a friendly tutor helping the user learn a topic through "
        "follow-up questions. Answer clearly and conversationally. You have a "
        "search_graph tool that retrieves facts from the user's personal "
        "knowledge graph; call it when the user refers to something they may "
        "have saved before, otherwise just answer. Never invent graph facts."
    ),
    "explore": (
        "You are a knowledge-graph explorer. The user wants to find previously "
        "studied material. ALWAYS use the search_graph tool first, then answer "
        "using the retrieved facts and clearly mention which concepts were found. "
        "If nothing is found, say so."
    ),
    "review": (
        "You are an English tutor running a spaced-repetition review session. "
        "ALWAYS use search_graph first to pull the user's personal context "
        "(people, places, grammar patterns). Create concise review questions "
        "grounded in their real life journal entries."
    ),
    "roleplay": (
        "You are an English conversation partner for roleplay practice. "
        "ALWAYS use search_graph first to learn about the user's life "
        "(friends, favorite places, routines). Stay in character and use "
        "their personal context naturally."
    ),
}

SEARCH_TOOL_SCHEMA = {
    "type": "function",
    "function": {
        "name": "search_graph",
        "description": (
            "Search the user's personal knowledge graph (GraphRAG) for concepts "
            "and relationships relevant to a query. Returns serialized facts and "
            "the matching node ids."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query / topic to look up in the graph.",
                }
            },
            "required": ["query"],
        },
    },
}


def _assistant_toolcall_dict(msg) -> dict:
    return {
        "role": "assistant",
        "content": msg.content or "",
        "tool_calls": [
            {
                "id": tc.id,
                "type": "function",
                "function": {
                    "name": tc.function.name,
                    "arguments": tc.function.arguments,
                },
            }
            for tc in msg.tool_calls
        ],
    }


async def run_agent(
    session: AsyncSession, mode: Mode, messages: list[ChatMessage]
) -> dict:
    run_id = tracer.start_run(mode)
    try:
        if mode == "build":
            result = await _run_build(session, run_id, messages)
        else:
            result = await _run_chat(session, run_id, mode, messages)
        tracer.finish_run(run_id, status="done")
        result["run_id"] = run_id
        return result
    except Exception as exc:  # noqa: BLE001 - surface error in trace + response
        tracer.finish_run(run_id, status="error", error=str(exc))
        raise


async def _run_build(
    session: AsyncSession, run_id: str, messages: list[ChatMessage]
) -> dict:
    t0 = time.time()
    staging = await tools.generate_graph(session, messages)
    tracer.add_step(
        run_id,
        type="tool",
        name="generate_graph",
        input={"message_count": len(messages)},
        output={
            "node_count": len(staging.nodes),
            "edge_count": len(staging.edges),
        },
        latency_ms=int((time.time() - t0) * 1000),
    )
    return {"staging": staging.model_dump()}


async def _run_chat(
    session: AsyncSession, run_id: str, mode: Mode, messages: list[ChatMessage]
) -> dict:
    settings = get_settings()
    client = _get_client()

    convo: list[dict] = [{"role": "system", "content": SYSTEM_PROMPTS[mode]}]
    for m in messages:
        if m.content.strip():
            convo.append({"role": m.role, "content": m.content})

    cited: list[str] = []
    seen_cited: set[str] = set()
    tool_choice: object = (
        {"type": "function", "function": {"name": "search_graph"}}
        if mode in ("explore", "review", "roleplay")
        else "auto"
    )

    for _ in range(_MAX_ITERATIONS):
        t0 = time.time()
        resp = await client.chat.completions.create(
            model=settings.openai_model,
            messages=convo,
            tools=[SEARCH_TOOL_SCHEMA],
            tool_choice=tool_choice,
            temperature=0.3,
        )
        msg = resp.choices[0].message
        usage = resp.usage.total_tokens if resp.usage else 0
        tracer.add_step(
            run_id,
            type="llm",
            name=settings.openai_model,
            input={"messages": convo[-3:], "tool_choice": str(tool_choice)},
            output={
                "content": msg.content,
                "tool_calls": [tc.function.name for tc in (msg.tool_calls or [])],
            },
            latency_ms=int((time.time() - t0) * 1000),
            tokens=usage,
        )

        if msg.tool_calls:
            convo.append(_assistant_toolcall_dict(msg))
            for tc in msg.tool_calls:
                t1 = time.time()
                try:
                    args = json.loads(tc.function.arguments or "{}")
                except json.JSONDecodeError:
                    args = {}
                query = args.get("query", "")
                result = await tools.search_graph(session, query)
                for nid in result["seed_node_ids"] or result["node_ids"]:
                    if nid not in seen_cited:
                        seen_cited.add(nid)
                        cited.append(nid)
                tracer.add_step(
                    run_id,
                    type="tool",
                    name="search_graph",
                    input={"query": query},
                    output={
                        "facts_found": result["facts_found"],
                        "node_ids": result["node_ids"],
                    },
                    latency_ms=int((time.time() - t1) * 1000),
                )
                convo.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": json.dumps(result),
                    }
                )
            # After the (possibly forced) first call, let the model finish.
            tool_choice = "auto"
            continue

        return {"answer": msg.content or "", "cited_node_ids": cited}

    # Loop exhausted: ask once more without tools for a final answer.
    final = await client.chat.completions.create(
        model=settings.openai_model,
        messages=convo,
        temperature=0.3,
    )
    return {
        "answer": final.choices[0].message.content or "",
        "cited_node_ids": cited,
    }
