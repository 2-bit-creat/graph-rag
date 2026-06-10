"""Entity/relation extraction powered by LlamaIndex PropertyGraphIndex tooling.

We use a LlamaIndex LLM path extractor (`DynamicLLMPathExtractor`) to turn a
free-form chat message into knowledge-graph triples. The extracted triples are
then persisted into our own `nodes`/`edges` Postgres tables (the source of truth
for the React Flow visualization), which keeps full control over the schema while
still leveraging LlamaIndex's structured extraction.
"""

from dataclasses import dataclass
from functools import lru_cache

from llama_index.core.graph_stores.types import KG_NODES_KEY, KG_RELATIONS_KEY
from llama_index.core.indices.property_graph import DynamicLLMPathExtractor
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
def _get_extractor() -> DynamicLLMPathExtractor:
    settings = get_settings()
    llm = OpenAI(model=settings.openai_model, api_key=settings.openai_api_key)
    return DynamicLLMPathExtractor(
        llm=llm,
        max_triplets_per_chunk=10,
        num_workers=1,
    )


async def extract_triples(message: str) -> list[Triple]:
    """Extract (source, relation, target) triples from a chat message."""
    text = message.strip()
    if not text:
        return []

    extractor = _get_extractor()
    nodes = await extractor.acall([TextNode(text=text)])

    triples: list[Triple] = []
    for node in nodes:
        entities = {e.name: e for e in node.metadata.get(KG_NODES_KEY, [])}
        for rel in node.metadata.get(KG_RELATIONS_KEY, []):
            source = entities.get(rel.source_id)
            target = entities.get(rel.target_id)
            triples.append(
                Triple(
                    source=rel.source_id,
                    source_type=getattr(source, "label", "entity") or "entity",
                    relation=rel.label,
                    target=rel.target_id,
                    target_type=getattr(target, "label", "entity") or "entity",
                )
            )
    return triples
