"""Canonical node types and edge relations shared across graph builders.

Covers both the Semantic Chunk graph (2안: Chunk/Speaker/Vocab/Concept) and the
diary knowledge graph (정체성-진술-개념: Person|Source|Identity -> Statement -> Concept).
"""

from __future__ import annotations

NODE_CHUNK = "Chunk"
NODE_SPEAKER = "Speaker"
NODE_VOCAB = "Vocab"
NODE_CONCEPT = "Concept"

GRAPH_NODE_TYPES = frozenset({NODE_CHUNK, NODE_SPEAKER, NODE_VOCAB, NODE_CONCEPT})

REL_NEXT_TURN = "NEXT_TURN"
REL_SPOKE_BY = "SPOKE_BY"
REL_KEYWORDS = "KEYWORDS"

# 일기 지식그래프 (정체성-진술-개념) 관계
REL_SPOKE_OR_PUBLISHED = "SPOKE_OR_PUBLISHED"  # (Person|Source|Identity) -> (Statement)
REL_MENTIONS = "MENTIONS"  # (Statement) -> (Identity)
REL_CONTEXT = "CONTEXT"  # (Statement) -> (Concept)


def contains_relation(language_code: str) -> str:
    """e.g. EN -> CONTAINS_EN"""
    return f"CONTAINS_{language_code.strip().upper()}"
