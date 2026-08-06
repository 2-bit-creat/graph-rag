"""Language-pack registry.

``target_pack(language)`` and ``native_quiz_pack(language)`` are the single
lookup points every quiz-generation gate should go through instead of an
inline ``if language == "english"`` branch. An unregistered language falls
back to the generic base pack (``coverage == "generic"``) and logs once —
loudly, not silently — so a 4th target language degrades visibly instead of
skipping every gate the way German and Korean used to.
"""

from __future__ import annotations

import logging
from functools import lru_cache

from .base import NativeQuizPack, TargetLanguagePack
from .english import EnglishNativePack, EnglishTargetPack
from .german import GermanTargetPack
from .korean import KoreanNativePack, KoreanTargetPack
from .pairs import PairRules, SourceGuardrail, pair_rules
from . import reasons

logger = logging.getLogger(__name__)

_TARGET_PACKS: dict[str, TargetLanguagePack] = {
    "english": EnglishTargetPack(),
    "german": GermanTargetPack(),
    "korean": KoreanTargetPack(),
}
_NATIVE_PACKS: dict[str, NativeQuizPack] = {
    "english": EnglishNativePack(),
    "korean": KoreanNativePack(),
}

_GENERIC_TARGET = TargetLanguagePack()
_GENERIC_NATIVE = NativeQuizPack()
_warned_generic: set[str] = set()


def target_pack(language: str | None) -> TargetLanguagePack:
    key = (language or "").strip().lower()
    pack = _TARGET_PACKS.get(key)
    if pack is not None:
        return pack
    if key not in _warned_generic:
        logger.warning(
            "No TargetLanguagePack registered for %r — falling back to the "
            "generic pack (coverage=generic). Quiz quality gates for this "
            "language will be looser than english/german/korean.",
            key,
        )
        _warned_generic.add(key)
    return _GENERIC_TARGET


def native_quiz_pack(language: str | None) -> NativeQuizPack:
    key = (language or "").strip().lower()
    return _NATIVE_PACKS.get(key, _GENERIC_NATIVE)


__all__ = [
    "TargetLanguagePack",
    "NativeQuizPack",
    "PairRules",
    "SourceGuardrail",
    "pair_rules",
    "target_pack",
    "native_quiz_pack",
    "reasons",
]
