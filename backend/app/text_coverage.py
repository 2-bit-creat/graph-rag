"""Native-language text splitting and coverage measurement.

These two helpers started life inside ``quiz_bundle`` to stop a planner from
quietly summarising a Statement it was asked to split. The knowledge-graph
extractor needs exactly the same guarantee for exactly the same reason — an LLM
asked to "clean up" a diary entry will happily return only its first sentence —
so they live here, importable by both without dragging the whole quiz stack
(language packs, TTS, OpenAI client) into the extraction path.

``quiz_bundle`` re-exports both under their original private names, so its
existing call sites are unchanged.
"""

from __future__ import annotations

import re

__all__ = ["split_statement_units", "native_ngram_coverage"]


def split_statement_units(text: str) -> list[str]:
    """Split a native-language passage into units without inventing text."""
    cleaned = re.sub(r"[ \t]+", " ", (text or "").strip())
    if not cleaned:
        return []
    units = [
        part.strip()
        for part in re.split(r"(?<=[.!?。！？])\s+|[\r\n]+", cleaned)
        if part.strip()
    ]
    # A long diary sentence often carries two independently teachable actions
    # separated by a comma even though it has only one final period.
    if len(units) == 1 and len(re.sub(r"\s+", "", cleaned)) >= 45 and "," in cleaned:
        comma_units = [part.strip() for part in cleaned.split(",") if part.strip()]
        if 2 <= len(comma_units) <= 4 and all(
            len(re.sub(r"\s+", "", part)) >= 12 for part in comma_units
        ):
            units = comma_units
    return units or [cleaned]


def native_ngram_coverage(source: str, candidate: str, *, size: int = 2) -> float:
    """Approximate semantic preservation without pretending to translate.

    Korean inflection changes only a small tail, while dropping a proposition
    removes many character n-grams. This catches planner summaries such as
    omitting "travel schedule" from a longer source span.
    """
    def compact(value: str) -> str:
        return "".join(re.findall(r"[A-Za-z0-9가-힣]", value.casefold()))

    left = compact(source)
    right = compact(candidate)
    if not left:
        return 1.0
    if len(left) < size:
        return 1.0 if left in right else 0.0
    source_grams = {left[index:index + size] for index in range(len(left) - size + 1)}
    candidate_grams = {right[index:index + size] for index in range(max(0, len(right) - size + 1))}
    return len(source_grams & candidate_grams) / max(1, len(source_grams))
