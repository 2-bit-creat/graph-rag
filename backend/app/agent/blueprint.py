"""Agent flow blueprints for the admin / developer UI.

Exposes canonical mode pipelines and the configuration attached to each step
(system prompts, tool schemas, model settings, etc.).
"""

from ..config import get_settings
from ..ontology_classifier import CLASSIFIER_SYSTEM_PROMPT, TYPE_DESCRIPTIONS
from .orchestrator import (
    SEARCH_TOOL_SCHEMA,
    SYSTEM_PROMPTS,
    _MAX_ITERATIONS,
)

# Node kinds drive styling in the React Flow admin page.
NODE_KINDS = ("input", "prompt", "llm", "tool", "policy", "transform", "output")


def _cfg(
    key: str,
    *,
    title: str,
    kind: str,
    description: str,
    content: str | None = None,
    fields: dict | None = None,
) -> dict:
    item: dict = {
        "key": key,
        "title": title,
        "kind": kind,
        "description": description,
    }
    if content is not None:
        item["content"] = content
    if fields:
        item["fields"] = fields
    return item


def _build_shared_configs(settings) -> dict[str, dict]:
    configs: dict[str, dict] = {}

    for mode, prompt in SYSTEM_PROMPTS.items():
        configs[f"system_prompt.{mode}"] = _cfg(
            f"system_prompt.{mode}",
            title=f"System prompt ({mode})",
            kind="prompt",
            description="OpenAI system message prepended to the chat loop.",
            content=prompt,
        )

    configs["tool.search_graph"] = _cfg(
        "tool.search_graph",
        title="search_graph tool schema",
        kind="tool",
        description="Function schema passed to the OpenAI tools API.",
        content=None,
        fields={"schema": SEARCH_TOOL_SCHEMA},
    )

    configs["settings.chat_llm"] = _cfg(
        "settings.chat_llm",
        title="Chat LLM settings",
        kind="setting",
        description="Used by study and explore modes in _run_chat().",
        fields={
            "model": settings.openai_model,
            "temperature": 0.3,
            "max_iterations": _MAX_ITERATIONS,
            "tools": ["search_graph"],
        },
    )

    configs["policy.tool_choice.study"] = _cfg(
        "policy.tool_choice.study",
        title="Tool choice policy (study)",
        kind="policy",
        description="Model decides whether to call search_graph (tool_choice=auto).",
        content="auto — optional search_graph when the user refers to saved material.",
    )

    configs["policy.tool_choice.explore"] = _cfg(
        "policy.tool_choice.explore",
        title="Tool choice policy (explore)",
        kind="policy",
        description="First LLM call forces search_graph; subsequent calls use auto.",
        content='First call: {"type":"function","function":{"name":"search_graph"}} → then auto',
    )

    configs["tool.generate_graph"] = _cfg(
        "tool.generate_graph",
        title="generate_graph pipeline",
        kind="tool",
        description=(
            "Deterministic build-mode pipeline (no chat loop). "
            "Journal graph uses semantic-chunk ingest (Chunk · Speaker · Vocab · Concept)."
        ),
        fields={
            "steps": [
                "Join user/assistant messages into conversation text",
                "Load ontology from database",
                "generate_triples() via LlamaIndex SchemaLLMPathExtractor",
                "refine_entity_types() LLM type correction pass",
                "_triples_to_staging() → StagingGraph",
            ],
            "journal_slow_path": "run_graph_ingest_pipeline (Statement graph build via kg_build)",
        },
    )

    configs["graph.incremental_pipeline"] = _cfg(
        "graph.incremental_pipeline",
        title="LightRAG incremental graph pipeline",
        kind="llm",
        description="Journal GraphRAG slow path: triple extract, pgvector merge, weighted edges.",
        fields={
            "step1_model": settings.openai_model,
            "step3_model": settings.openai_premium_model,
            "embedding_model": "text-embedding-3-small",
            "vector_max_distance": 0.3,
            "vector_top_k": 3,
            "pre_confirmed_bypass": "Skip MERGE decision when Fast Path supplies pre_confirmed_node_id",
        },
    )

    configs["extractor.schema"] = _cfg(
        "extractor.schema",
        title="SchemaLLMPathExtractor",
        kind="llm",
        description=(
            "LlamaIndex property-graph extractor constrained by the active ontology. "
            "Prompts are internal to LlamaIndex; entity/relation types come from the DB."
        ),
        fields={
            "extractor": "SchemaLLMPathExtractor",
            "fallback": "DynamicLLMPathExtractor (when ontology is empty)",
            "max_triplets_per_chunk": 20,
            "strict": False,
            "model": settings.openai_model,
        },
    )

    configs["classifier.system"] = _cfg(
        "classifier.system",
        title="Entity type classifier — system prompt",
        kind="prompt",
        description="Post-extraction pass that fixes mis-tagged entities (e.g. job title ≠ Person).",
        content=CLASSIFIER_SYSTEM_PROMPT,
    )

    configs["classifier.types"] = _cfg(
        "classifier.types",
        title="Entity type descriptions (fallback)",
        kind="setting",
        description="Used when ontology rows lack a description field.",
        fields={"TYPE_DESCRIPTIONS": TYPE_DESCRIPTIONS},
    )

    configs["classifier.settings"] = _cfg(
        "classifier.settings",
        title="Entity type classifier — LLM settings",
        kind="setting",
        description="OpenAI call inside refine_entity_types().",
        fields={
            "model": settings.openai_model,
            "temperature": 0,
            "response_format": "json_object",
        },
    )

    configs["output.study"] = _cfg(
        "output.study",
        title="Study mode output",
        kind="output",
        description="Returned to the client after the chat loop completes.",
        fields={"answer": "string", "cited_node_ids": "string[]"},
    )

    configs["output.explore"] = _cfg(
        "output.explore",
        title="Explore mode output",
        kind="output",
        description="Same shape as study; UI highlights cited graph nodes.",
        fields={"answer": "string", "cited_node_ids": "string[]"},
    )

    configs["output.build"] = _cfg(
        "output.build",
        title="Build mode output",
        kind="output",
        description="Staging proposal for user review — no chat answer.",
        fields={"staging": "StagingGraph (nodes + edges)"},
    )

    return configs


def _mode_flow(mode: str) -> dict:
    if mode == "study":
        return {
            "id": "study",
            "description": "Tutor conversation; search_graph is optional.",
            "nodes": [
                {"id": "input", "label": "User messages", "kind": "input"},
                {
                    "id": "system",
                    "label": "System prompt",
                    "kind": "prompt",
                    "config_key": "system_prompt.study",
                },
                {
                    "id": "llm",
                    "label": "LLM + tools",
                    "kind": "llm",
                    "config_key": "settings.chat_llm",
                },
                {
                    "id": "policy",
                    "label": "tool_choice",
                    "kind": "policy",
                    "config_key": "policy.tool_choice.study",
                },
                {
                    "id": "search",
                    "label": "search_graph",
                    "kind": "tool",
                    "config_key": "tool.search_graph",
                },
                {
                    "id": "llm2",
                    "label": "LLM answer",
                    "kind": "llm",
                    "config_key": "settings.chat_llm",
                },
                {
                    "id": "output",
                    "label": "Response",
                    "kind": "output",
                    "config_key": "output.study",
                },
            ],
            "edges": [
                {"source": "input", "target": "system"},
                {"source": "system", "target": "llm"},
                {"source": "llm", "target": "policy", "label": "policy"},
                {"source": "policy", "target": "search", "label": "if tool call"},
                {"source": "search", "target": "llm2"},
                {"source": "llm2", "target": "output"},
                {"source": "llm", "target": "output", "label": "direct answer", "dashed": True},
            ],
        }

    if mode == "explore":
        return {
            "id": "explore",
            "description": "Forced GraphRAG search, then answer with cited nodes.",
            "nodes": [
                {"id": "input", "label": "User messages", "kind": "input"},
                {
                    "id": "system",
                    "label": "System prompt",
                    "kind": "prompt",
                    "config_key": "system_prompt.explore",
                },
                {
                    "id": "llm",
                    "label": "LLM (forced tool)",
                    "kind": "llm",
                    "config_key": "settings.chat_llm",
                },
                {
                    "id": "policy",
                    "label": "tool_choice",
                    "kind": "policy",
                    "config_key": "policy.tool_choice.explore",
                },
                {
                    "id": "search",
                    "label": "search_graph",
                    "kind": "tool",
                    "config_key": "tool.search_graph",
                },
                {
                    "id": "llm2",
                    "label": "LLM answer",
                    "kind": "llm",
                    "config_key": "settings.chat_llm",
                },
                {
                    "id": "output",
                    "label": "Response + highlights",
                    "kind": "output",
                    "config_key": "output.explore",
                },
            ],
            "edges": [
                {"source": "input", "target": "system"},
                {"source": "system", "target": "llm"},
                {"source": "llm", "target": "policy"},
                {"source": "policy", "target": "search", "label": "forced"},
                {"source": "search", "target": "llm2", "label": "tool result"},
                {"source": "llm2", "target": "output"},
            ],
        }

    # build
    return {
        "id": "build",
        "description": "Extract triples from conversation → staging graph proposal.",
        "nodes": [
            {"id": "input", "label": "User messages", "kind": "input"},
            {
                "id": "join",
                "label": "Join conversation",
                "kind": "transform",
            },
            {
                "id": "ontology",
                "label": "Load ontology",
                "kind": "transform",
            },
            {
                "id": "extract",
                "label": "generate_triples",
                "kind": "llm",
                "config_key": "extractor.schema",
            },
            {
                "id": "classify",
                "label": "refine_entity_types",
                "kind": "llm",
                "config_key": "classifier.system",
            },
            {
                "id": "staging",
                "label": "Staging graph",
                "kind": "transform",
                "config_key": "tool.generate_graph",
            },
            {
                "id": "output",
                "label": "Staging output",
                "kind": "output",
                "config_key": "output.build",
            },
        ],
        "edges": [
            {"source": "input", "target": "join"},
            {"source": "join", "target": "ontology"},
            {"source": "ontology", "target": "extract"},
            {"source": "extract", "target": "classify"},
            {"source": "classify", "target": "staging"},
            {"source": "staging", "target": "output"},
        ],
    }


def get_agent_blueprint() -> dict:
    settings = get_settings()
    configs = _build_shared_configs(settings)
    return {
        "model": settings.openai_model,
        "modes": [_mode_flow("study"), _mode_flow("explore"), _mode_flow("build")],
        "configs": configs,
    }
