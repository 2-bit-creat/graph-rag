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


def is_person_like_type(type_: str | None) -> bool:
    """Person / Individual / speaker-like types — same identity for merge."""
    return type_group_key(type_) in _PERSON_LIKE
