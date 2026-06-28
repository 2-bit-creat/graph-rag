"""Canonical node types and edge relations for Semantic Chunk graph (2안)."""

from __future__ import annotations

NODE_CHUNK = "Chunk"
NODE_SPEAKER = "Speaker"
NODE_VOCAB = "Vocab"
NODE_CONCEPT = "Concept"

GRAPH_NODE_TYPES = frozenset({NODE_CHUNK, NODE_SPEAKER, NODE_VOCAB, NODE_CONCEPT})

REL_NEXT_TURN = "NEXT_TURN"
REL_SPOKE_BY = "SPOKE_BY"
REL_KEYWORDS = "KEYWORDS"


def contains_relation(language_code: str) -> str:
    """e.g. EN -> CONTAINS_EN"""
    return f"CONTAINS_{language_code.strip().upper()}"
