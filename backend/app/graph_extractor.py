"""Entity/relation extraction powered by LlamaIndex PropertyGraphIndex tooling.

`generate_triples` uses a `SchemaLLMPathExtractor` configured from the active
(user-editable) ontology, so extraction follows the defined node/relation types.
If the ontology is empty we fall back to a free-form `DynamicLLMPathExtractor`.
The extracted triples are persisted into our own `nodes`/`edges` Postgres tables
(the source of truth for the React Flow visualization).
"""

from dataclasses import dataclass
from functools import lru_cache
from typing import Literal

from llama_index.core.graph_stores.types import KG_NODES_KEY, KG_RELATIONS_KEY
from llama_index.core.indices.property_graph import (
    DynamicLLMPathExtractor,
    SchemaLLMPathExtractor,
)
from llama_index.core.schema import TextNode
from llama_index.llms.openai import OpenAI

from .config import get_settings


@dataclass
class Triple:
    source: str
    source_type: str
    relation: str
    target: str
    target_type: str


@lru_cache
def _get_llm() -> OpenAI:
    settings = get_settings()
    return OpenAI(model=settings.openai_model, api_key=settings.openai_api_key)


@lru_cache
def _get_dynamic_extractor() -> DynamicLLMPathExtractor:
    return DynamicLLMPathExtractor(
        llm=_get_llm(), max_triplets_per_chunk=20, num_workers=1
    )


@lru_cache
def _get_schema_extractor(
    entities: tuple[str, ...], relations: tuple[str, ...]
) -> SchemaLLMPathExtractor:
    # Literal[("A", "B")] is equivalent to Literal["A", "B"].
    entity_type = Literal[entities]  # type: ignore[valid-type]
    relation_type = Literal[relations]  # type: ignore[valid-type]
    validation_schema = {e: list(relations) for e in entities}
    return SchemaLLMPathExtractor(
        llm=_get_llm(),
        possible_entities=entity_type,
        possible_relations=relation_type,
        kg_validation_schema=validation_schema,
        strict=False,  # follow the ontology but allow useful suggestions
        max_triplets_per_chunk=20,
        num_workers=1,
    )


def _nodes_to_triples(nodes) -> list[Triple]:
    triples: list[Triple] = []
    for node in nodes:
        entities = {e.name: e for e in node.metadata.get(KG_NODES_KEY, [])}
        for rel in node.metadata.get(KG_RELATIONS_KEY, []):
            source = entities.get(rel.source_id)
            target = entities.get(rel.target_id)
            triples.append(
                Triple(
                    source=rel.source_id,
                    source_type=getattr(source, "label", "Concept") or "Concept",
                    relation=rel.label,
                    target=rel.target_id,
                    target_type=getattr(target, "label", "Concept") or "Concept",
                )
            )
    return triples


async def generate_triples(
    text: str,
    entity_types: list[str] | None = None,
    relation_types: list[str] | None = None,
) -> list[Triple]:
    """Extract ontology-aligned triples from conversation text."""
    text = (text or "").strip()
    if not text:
        return []

    if entity_types and relation_types:
        extractor = _get_schema_extractor(
            tuple(entity_types), tuple(relation_types)
        )
    else:
        extractor = _get_dynamic_extractor()

    nodes = await extractor.acall([TextNode(text=text)])
    return _nodes_to_triples(nodes)
