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


# ─── Identity category (정체성 계층) ──────────────────────────────────────────
# The graph's top conceptual tier is 정체성–진술–개념 (Identity–Statement–Concept).
# There are exactly TWO stored identity types:
#
#   - Identity : any named being/thing that recurs and accumulates statements —
#                humans, pets, groups, companies-as-speakers. Resolved by
#                name/alias, never forked into duplicate Concepts.
#   - Source   : 외부 출처 귀속 head (매체·기관·책·AI). Anchors
#                SPOKE_OR_PUBLISHED just like Identity, but stays a distinct
#                category so a same-name Identity and Source never auto-merge.
#
# There is deliberately NO "Person" type and no is_human flag. "This identity is
# a real person" is not a type — it is a bound speaker_profiles row. Voice
# EMBEDDING binding is a per-confirmation user choice; most Identity nodes
# (반려동물·단체) simply never get one, and Source nodes are refused one by the
# automatic voice-linking path.
#
# Any identity in this category can be a segment's 화자 (speaker) — the
# 화자/speaker picker spans Identity ∪ Source.

IDENTITY_ENTITY_TYPE = "Identity"
SOURCE_ENTITY_TYPE = "Source"

_SOURCE_LIKE = frozenset({"source", "media", "publication", "출처"})

# Legacy/alternate spellings that must still classify as Identity. NOT deleted
# with the Person type: the backfill is not simultaneous with the code deploy,
# `entry.graph_staging` JSON still literally says "Person", stored ontology rows
# still carry "Speaker"/"화자", and older clients still send speaker_type
# "Person". This set is the compat layer — nothing outside this module needs to
# know it exists; callers use is_identity_type / canonical_identity_type.
_IDENTITY_LEGACY = frozenset(
    {"person", "individual", "human", "speaker", "화자", "character", "people"}
)

_IDENTITY_EXTRA = frozenset(
    {"identity", "animal", "pet", "organization", "group", "개체", "동물", "단체"}
)

_IDENTITY_LIKE = _IDENTITY_LEGACY | _IDENTITY_EXTRA


def is_source_like_type(type_: str | None) -> bool:
    """Source / media attribution types (외부 출처) — statement heads, not people."""
    return type_group_key(type_) in _SOURCE_LIKE


def is_identity_type(type_: str | None) -> bool:
    """정체성 카테고리 전체: Identity류 ∪ Source류.

    Mention-resolution / alias-matching scope, AND the 화자 (speaker) picker/link
    scope — any identity can be attributed as a segment's speaker.
    """
    key = type_group_key(type_)
    return key in _IDENTITY_LIKE or key in _SOURCE_LIKE


def identity_merge_group(type_: str | None) -> str:
    """Merge bucket within the identity category: "source" or "identity".

    This is where "a same-name Identity and Source never auto-merge" lives. Two
    identity nodes merge (or dedupe in the speaker picker) only when they share
    a bucket.
    """
    return "source" if is_source_like_type(type_) else "identity"


def identity_types_compatible(a: str | None, b: str | None) -> bool:
    """True when two identity types name the same kind of head."""
    return identity_merge_group(a) == identity_merge_group(b)


def canonical_identity_type(type_: str | None) -> str:
    """Map any identity-ish string onto a stored type: "Source" or "Identity".

    The single conversion funnel shared by claim head resolution, reclassify,
    update_node and the backfill — legacy "Person"/"Speaker"/"화자" all land on
    "Identity" here.
    """
    return SOURCE_ENTITY_TYPE if is_source_like_type(type_) else IDENTITY_ENTITY_TYPE
