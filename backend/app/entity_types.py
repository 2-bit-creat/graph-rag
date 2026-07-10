"""Open-domain entity type normalization (no fixed enum — consistent PascalCase storage)."""

from __future__ import annotations

import re


def normalize_entity_type(type_: str | None, *, fallback: str = "Entity") -> str:
    """Collapse PERSON/Person/person → Person; job_title → JobTitle."""
    raw = (type_ or "").strip()
    if not raw:
        return fallback
    parts = [p for p in re.split(r"[\s_\-]+", raw) if p]
    if not parts:
        return fallback
    return "".join(p[:1].upper() + p[1:].lower() for p in parts)


def type_group_key(type_: str | None) -> str:
    return normalize_entity_type(type_).lower()


_PERSON_LIKE = frozenset(
    {"person", "individual", "human", "speaker", "화자", "character", "people"}
)

# Attribution head for pasted/external content (매체·기관·AI·책 등). Deliberately
# NOT person-like: Source nodes must never appear in voice/speaker pickers or be
# merged with Person identities — they only anchor SPOKE_OR_PUBLISHED edges.
SOURCE_ENTITY_TYPE = "Source"

_SOURCE_LIKE = frozenset({"source", "media", "publication", "출처"})


def is_person_like_type(type_: str | None) -> bool:
    """Person / Individual / speaker-like types — same identity for merge."""
    return type_group_key(type_) in _PERSON_LIKE


def is_source_like_type(type_: str | None) -> bool:
    """Source / media attribution types (외부 출처) — statement heads, not people."""
    return type_group_key(type_) in _SOURCE_LIKE


# ─── Identity category (정체성 계층) ──────────────────────────────────────────
# The graph's top conceptual tier is 정체성–진술–개념 (Identity–Statement–Concept).
# "Identity" is the CATEGORY: any named being/thing that recurs and accumulates
# statements — resolved by name/alias, never forked into duplicate Concepts.
# Its stored subtypes stay distinct because they gate different behavior:
#   - Person   : humans — the only voice-linkable subtype (speaker pickers).
#   - Source   : 매체·기관·AI attribution heads — deliberately excluded from pickers.
#   - Identity : everything else with a persistent identity (반려동물·단체 등).

IDENTITY_ENTITY_TYPE = "Identity"

_IDENTITY_EXTRA = frozenset(
    {"identity", "animal", "pet", "organization", "group", "개체", "동물", "단체"}
)


def is_identity_type(type_: str | None) -> bool:
    """정체성 카테고리 전체: Person류 ∪ Source류 ∪ Identity류.

    Mention-resolution / alias-matching scope. NOT a voice gate — voice linking
    stays restricted to is_person_like_type.
    """
    key = type_group_key(type_)
    return key in _PERSON_LIKE or key in _SOURCE_LIKE or key in _IDENTITY_EXTRA
