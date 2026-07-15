"""Deterministic (non-LLM) surface-name matching against identity nodes.

Shared by graph_chat (speaker-exact seeding) and kg_build (homonym-aware mention
resolution) so both sides normalize names the same way. Pure functions only — no
DB access, no embeddings, no LLM calls.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .models import Node

# Longest-first so "연구원님" matches before the shorter "연구원"/"님".
_TITLE_SUFFIXES: tuple[str, ...] = (
    "연구원님", "선생님", "부장님", "상무님", "과장님", "차장님", "대리님",
    "팀장님", "실장님", "이사님", "대표님", "사장님", "전무님", "교수님", "박사님",
    "연구원", "부장", "상무", "과장", "차장", "대리", "팀장", "실장",
    "이사", "대표", "사장", "전무", "교수", "박사", "선배", "후배",
    "님", "씨", "군", "양",
)

# Trailing particles/postpositions that may follow a name in natural Korean
# text — stripped only for span expansion, never required for a match.
# Longest-first so multi-char particles match before their single-char prefix.
_PARTICLE_SUFFIXES: tuple[str, ...] = (
    "께서는", "한테는", "에게는", "께서", "이가", "이는", "이랑", "한테", "에게",
    "에서", "으로", "부터", "까지", "이", "가", "은", "는", "을", "를", "도",
    "만", "로", "과", "와", "께", "랑",
)

# Bare 1-char pronouns that would otherwise false-positive on every message
# (e.g. the user's own self node is often literally named "나").
_STOPLIST: frozenset[str] = frozenset({"나", "저", "너", "내", "제"})


def norm_compact(s: str | None) -> str:
    """Lowercase and strip ALL whitespace (so "하승목 연구원" == "하승목연구원")."""
    return re.sub(r"\s+", "", (s or "").lower())


def strip_title(compact: str) -> str:
    """Remove one trailing title/honorific suffix, only if the remaining base
    is still >= 2 chars (so a 2-char name isn't hollowed out by a false suffix
    match, e.g. "김대표" staying intact if stripping "표" made no sense — here we
    only strip whole known suffixes so this mainly guards very short names)."""
    for suf in _TITLE_SUFFIXES:
        if compact.endswith(suf) and len(compact) - len(suf) >= 2:
            return compact[: -len(suf)]
    return compact


def base_name_key(s: str | None) -> str:
    """Normalized identity key: compacted + title stripped. Two surface forms
    that only differ by whitespace or an honorific suffix share this key."""
    return strip_title(norm_compact(s))


@dataclass
class NameMatch:
    node: Node
    surface: str  # matched substring as it appears in the original message
    start: int
    end: int


def _surface_forms(node: Node) -> list[str]:
    from .crud import node_alias_keys  # local import: avoid crud<->name_match cycle

    forms = {node.name, *node_alias_keys(node)}
    return [f for f in forms if isinstance(f, str) and f.strip()]


_TITLE_ALT = "|".join(re.escape(t) for t in _TITLE_SUFFIXES)
_PARTICLE_ALT = "|".join(re.escape(p) for p in _PARTICLE_SUFFIXES)


def _is_word_boundary(message: str, idx: int) -> bool:
    """True if position idx (end of a match) is at a word boundary — end of
    string, or followed by whitespace/punctuation rather than a Hangul syllable
    that would make the match a substring of a longer, unrelated word."""
    if idx >= len(message):
        return True
    ch = message[idx]
    return not ("가" <= ch <= "힣")  # not a Hangul syllable


def scan_identity_mentions(message: str, identities: list[Node]) -> list[NameMatch]:
    """Find identity nodes whose name/alias is literally present in ``message``,
    tolerating whitespace variants and an optional trailing title/particle.

    Deterministic, zero LLM/embedding calls. One match per node (first/longest
    span); overlapping candidate spans keep the longer, more literal one.
    """
    candidates: list[tuple[NameMatch, bool]] = []  # (match, consumed_title)
    for node in identities:
        for surface in _surface_forms(node):
            compact = norm_compact(surface)
            if len(compact) < 2 or compact in _STOPLIST:
                continue
            # Match the surface char-by-char allowing whitespace between any
            # two chars (so "하승목 연구원" matches "하승목연구원" in either
            # spacing), then optionally consume a title suffix and/or a
            # particle/postposition for span purposes only.
            char_pattern = r"\s*".join(re.escape(ch) for ch in compact)
            pattern = (
                rf"{char_pattern}(?P<title>\s*(?:{_TITLE_ALT}))?(?P<particle>{_PARTICLE_ALT})?"
            )
            for m in re.finditer(pattern, message, re.IGNORECASE):
                consumed_title = m.group("title") is not None
                consumed_particle = m.group("particle") is not None
                # A bare literal match (no recognized title/particle attached)
                # is only trusted at a real word boundary — short (<=2 char)
                # names are the highest false-positive risk (e.g. "민수" inside
                # "민수기"). Longer bare names and any title/particle-terminated
                # match are accepted even when immediately followed by more
                # Hangul (Korean postpositions routinely attach without a
                # space and we can't enumerate every one of them).
                if (
                    not consumed_title
                    and not consumed_particle
                    and len(compact) <= 2
                    and not _is_word_boundary(message, m.end())
                ):
                    continue
                candidates.append(
                    (
                        NameMatch(
                            node=node, surface=m.group(0), start=m.start(), end=m.end()
                        ),
                        consumed_title,
                    )
                )
                break  # one match per (node, surface) is enough

    # Resolve overlaps: longer spans win; among equal-length spans, prefer the
    # one that didn't need to "borrow" a title suffix (a node whose own name
    # literally covers the text beats one that merely looks similar once an
    # honorific is optimistically appended). Keep at most one match per node.
    candidates.sort(key=lambda c: (c[0].start, -(c[0].end - c[0].start), c[1]))
    picked: list[NameMatch] = []
    seen_nodes: set = set()
    occupied: list[tuple[int, int]] = []
    for match, _consumed_title in candidates:
        if match.node.id in seen_nodes:
            continue
        if any(not (match.end <= s or match.start >= e) for s, e in occupied):
            continue
        picked.append(match)
        seen_nodes.add(match.node.id)
        occupied.append((match.start, match.end))
    return picked
