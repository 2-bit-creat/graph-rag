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
# There is exactly ONE stored identity type, "Identity" — 외부 출처 귀속 head
# (매체·기관·책·AI, formerly a distinct "Source" type) is now just an Identity
# node with its `is_source` column set. Both still anchor SPOKE_OR_PUBLISHED and
# both are valid 화자/speaker picks, but the flag keeps them in separate merge
# buckets so a same-name Identity and Source never auto-merge — see
# identity_merge_group / identity_types_compatible, which take the flag
# directly rather than a type string.
#
# There is deliberately NO "Person" type and no is_human flag either. "This
# identity is a real person" is not a type — it is a bound speaker_profiles
# row. Voice EMBEDDING binding is a per-confirmation user choice; most Identity
# nodes (반려동물·단체) simply never get one, and is_source nodes are refused
# one by the automatic voice-linking path.
#
# Any identity in this category can be a segment's 화자 (speaker) — the
# 화자/speaker picker spans plain Identity ∪ is_source Identity.

IDENTITY_ENTITY_TYPE = "Identity"
# No longer a value ever written to Node.type — kept only as a recognizable
# legacy input token (old clients, stored graph_staging JSON, older DB rows
# not yet touched by the db.py backfill) that is_source_like_type still has to
# classify into the `is_source` flag.
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


def identity_merge_group(is_source: bool) -> str:
    """Merge bucket within the identity category: "source" or "identity".

    This is where "a same-name Identity and Source never auto-merge" lives. Two
    identity nodes merge (or dedupe in the speaker picker) only when they share
    a bucket.
    """
    return "source" if is_source else "identity"


def identity_types_compatible(a_is_source: bool, b_is_source: bool) -> bool:
    """True when two identity heads belong to the same merge bucket."""
    return identity_merge_group(a_is_source) == identity_merge_group(b_is_source)


def canonical_identity_type(type_: str | None) -> str:
    """Map any identity-ish string onto the single stored identity type.

    The single conversion funnel shared by claim head resolution, reclassify,
    update_node and the backfill — legacy "Person"/"Speaker"/"화자"/"Source"/
    "media" all land on "Identity" here. The Identity/Source distinction is no
    longer a type string — see resolve_is_source for the companion flag.
    """
    return IDENTITY_ENTITY_TYPE


def resolve_is_source(type_: str | None, *, default: bool = False) -> bool:
    """Whether a raw type/label string names a Source-like head.

    Companion to canonical_identity_type: call both when persisting a head
    node's type and is_source flag from a raw string (extraction output, a
    reclassify request, a legacy stored value). `default` lets a caller carry
    forward an existing node's current flag when the raw string is empty/None
    rather than silently clearing it.
    """
    if type_ is None or not str(type_).strip():
        return default
    return is_source_like_type(type_)
