"""Keep people's names out of the extracted learning expressions.

A Statement's own graph already knows who it is about: the identity that spoke
it and every identity it MENTIONS. The expression extractor does not — it sees
only text, and a conversation full of names produced wordbook entries like
``es heißt eui-jun und seung-hyun`` ("의준과 승현이라고 말한다") and
``euijun seunghyeon ist``. Nobody learns vocabulary from their friends' names.

The model is asked to list proper names in ``context_entities`` and keep them
out of expressions, but that is a request, not a guarantee. This module is the
deterministic half:

* the **native** side is exact — the graph gives us "의준"/"승현" in Hangul and a
  Korean gloss that contains one of them is a name, not a meaning;
* the **target** side needs romanization, because "의준" reaches German as
  ``eui-jun`` or ``euijun`` and "승현" as ``seung-hyun`` or ``seunghyeon``. We
  generate the plausible spellings per syllable instead of guessing one.

Matching is by whole token (or two adjacent tokens joined, so ``eui-jun``
matches), never by substring — blocking a legitimate word because a name hides
inside it would be its own quality bug.
"""

from __future__ import annotations

import re
import uuid
from typing import Any, Iterable

_HANGUL_BASE = 0xAC00
_HANGUL_LAST = 0xD7A3

# Revised-Romanization letters, plus the alternates Korean names are actually
# spelled with in the wild (승 → seung/sung, 현 → hyeon/hyun, 의 → ui/eui).
_INITIALS: tuple[tuple[str, ...], ...] = (
    ("g", "k"), ("kk", "k"), ("n",), ("d", "t"), ("tt", "t"), ("r", "l"),
    ("m",), ("b", "p"), ("pp", "p"), ("s", "sh"), ("ss", "s"), ("",),
    ("j", "j"), ("jj", "j"), ("ch",), ("k",), ("t",), ("p",), ("h",),
)
_VOWELS: tuple[tuple[str, ...], ...] = (
    ("a",), ("ae", "e"), ("ya",), ("yae", "ye"), ("eo", "u", "o"), ("e", "ae"),
    # 영 is written yeong/young/yong; "you" + the ㅇ final gives "young".
    ("yeo", "yu", "yo", "you"), ("ye",), ("o", "oh"), ("wa",), ("wae", "we"),
    ("oe", "oi", "we"), ("yo", "you"), ("u", "oo"), ("wo", "weo"), ("we",),
    ("wi",), ("yu", "yoo"), ("eu", "u"), ("ui", "eui", "i", "ee"), ("i", "ee"),
)
_FINALS: tuple[tuple[str, ...], ...] = (
    ("",), ("k", "g"), ("k",), ("k",), ("n",), ("n",), ("n",), ("t", "d"),
    ("l", "r"), ("k",), ("m",), ("l",), ("l",), ("l",), ("p",), ("l",),
    ("m",), ("p", "b"), ("p",), ("t", "s"), ("t",), ("ng",), ("t",), ("t",),
    ("k",), ("t",), ("p",), ("t",),
)

# A name expands to a product of per-syllable spellings; two- and three-syllable
# names stay well under this, and the cap keeps a pathological input bounded.
_MAX_VARIANTS = 256

_LATIN_TOKEN_RE = re.compile(r"[A-Za-z]+")
_HANGUL_RE = re.compile(r"[가-힣]")


def _syllable_spellings(char: str) -> tuple[str, ...]:
    code = ord(char) - _HANGUL_BASE
    initial, rest = divmod(code, 588)
    vowel, final = divmod(rest, 28)
    out: list[str] = []
    for lead in _INITIALS[initial]:
        for mid in _VOWELS[vowel]:
            for tail in _FINALS[final]:
                spelling = f"{lead}{mid}{tail}"
                if spelling and spelling not in out:
                    out.append(spelling)
    return tuple(out)


def romanization_variants(name: str) -> set[str]:
    """Plausible latin spellings of a Hangul name (empty for non-Hangul input).

    Single-syllable names are skipped: their spellings ("ho", "min") are short
    enough to collide with ordinary target-language words, and the cure would be
    worse than the disease.
    """
    syllables = [ch for ch in (name or "") if _HANGUL_BASE <= ord(ch) <= _HANGUL_LAST]
    if len(syllables) < 2 or len(syllables) != len((name or "").strip()):
        return set()
    variants: set[str] = {""}
    for char in syllables:
        spellings = _syllable_spellings(char)
        variants = {
            prefix + spelling for prefix in variants for spelling in spellings
        }
        if len(variants) > _MAX_VARIANTS:
            variants = set(sorted(variants)[:_MAX_VARIANTS])
    return {value for value in variants if len(value) >= 3}


def _given_name(name: str) -> str:
    """The part a Korean full name is usually shortened to (surname dropped)."""
    stripped = (name or "").strip()
    if len(stripped) == 3 and all(
        _HANGUL_BASE <= ord(ch) <= _HANGUL_LAST for ch in stripped
    ):
        return stripped[1:]
    return ""


class EntityNameGuard:
    """Blocks expressions that are really a person's (or source's) name.

    Built from names the graph knows for one Statement — its speaker, everyone
    it mentions, and their aliases — so it never depends on the model correctly
    declaring them.
    """

    def __init__(self, names: Iterable[str]) -> None:
        self.native: set[str] = set()
        self.romanized: set[str] = set()
        for raw in names:
            name = (raw or "").strip()
            if len(name) < 2:
                continue
            self.native.add(name)
            self.romanized |= romanization_variants(name)
            given = _given_name(name)
            if given:
                self.native.add(given)
                self.romanized |= romanization_variants(given)
        # Latin-script names (an English handle, a brand) match directly.
        self.romanized |= {
            name.lower()
            for name in self.native
            if len(name) >= 3 and not _HANGUL_RE.search(name)
        }

    def __bool__(self) -> bool:
        return bool(self.native or self.romanized)

    def target_reason(self, text: str) -> str | None:
        """Whether a target-language expression contains one of the names."""
        if not self.romanized or not text:
            return None
        tokens = [match.lower() for match in _LATIN_TOKEN_RE.findall(text)]
        joined = [a + b for a, b in zip(tokens, tokens[1:])]
        for candidate in (*tokens, *joined):
            if candidate in self.romanized:
                return f"expression contains the name {candidate!r}"
        return None

    def native_reason(self, text: str) -> str | None:
        """Whether a native-language gloss names one of them.

        A dictionary meaning does not contain a specific person's name; when it
        does, the "expression" is a fact about that person ("의준이 승현이다"),
        which belongs in the graph and not in a wordbook.
        """
        if not self.native or not text:
            return None
        for name in self.native:
            if _HANGUL_RE.search(name) and name in text:
                return f"meaning names {name!r}"
        return None

    def reason(self, *, target: str = "", native: str = "") -> str | None:
        return self.target_reason(target) or self.native_reason(native)


def _node_names(node: Any) -> list[str]:
    names = [str(getattr(node, "name", "") or "")]
    aliases = getattr(node, "aliases", None)
    if isinstance(aliases, list):
        names.extend(str(value) for value in aliases if value)
    return names


async def build_statement_entity_guard(
    session: Any,
    user_id: uuid.UUID,
    statement_id: uuid.UUID,
) -> EntityNameGuard:
    """Names the graph knows for one Statement: its speaker + everyone mentioned."""
    from . import crud

    names: list[str] = []
    try:
        speakers = await crud.get_speakers_for_statements(
            session, user_id, {statement_id}
        )
        mentions = await crud.get_mentions_for_statements(
            session, user_id, {statement_id}, limit_per_statement=20
        )
    except Exception:  # a missing neighbour must never block quiz generation
        return EntityNameGuard([])

    speaker = speakers.get(statement_id)
    if speaker is not None:
        names.extend(_node_names(speaker))
    for node in mentions.get(statement_id) or []:
        names.extend(_node_names(node))
    # "나"/self is the learner, not a name that can leak into an expression.
    return EntityNameGuard(name for name in names if name.strip() != "나")
