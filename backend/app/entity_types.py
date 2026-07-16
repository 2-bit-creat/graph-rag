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
# NOT person-like: Source nodes never merge with Person identities of the same
# name (see is_person_like_type) — they anchor SPOKE_OR_PUBLISHED edges just like
# Person, but as a distinct category. They DO appear in the 화자 (speaker) picker
# alongside every other identity type — any recurring identity can be attributed
# as a segment's speaker, not just people (e.g. "기업은행" publishing a
# statement). Voice EMBEDDING binding is a per-confirmation user choice, not a
# type-based gate — most Source identities simply won't have one.
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
# statements — resolved by name/alias, never forked into duplicate Concepts. Any
# identity in this whole category can be a segment's 화자 (speaker) — the
# 화자/speaker picker spans Person ∪ Source ∪ Identity. Its stored subtypes stay
# distinct because they gate MERGE behavior, not picker visibility:
#   - Person   : humans — same-name Person/Source pairs never merge into one node.
#   - Source   : 매체·기관·AI attribution heads — same rule, other direction.
#   - Identity : everything else with a persistent identity (반려동물·단체 등),
#                promoted to Person the moment it's confirmed to have a voice.

IDENTITY_ENTITY_TYPE = "Identity"

_IDENTITY_EXTRA = frozenset(
    {"identity", "animal", "pet", "organization", "group", "개체", "동물", "단체"}
)


def is_identity_type(type_: str | None) -> bool:
    """정체성 카테고리 전체: Person류 ∪ Source류 ∪ Identity류.

    Mention-resolution / alias-matching scope, AND the 화자 (speaker) picker/link
    scope — any identity can be attributed as a segment's speaker. Voice
    EMBEDDING binding itself isn't type-gated either; it's just that most
    non-Person identities won't realistically have a recorded voice.
    """
    key = type_group_key(type_)
    return key in _PERSON_LIKE or key in _SOURCE_LIKE or key in _IDENTITY_EXTRA
