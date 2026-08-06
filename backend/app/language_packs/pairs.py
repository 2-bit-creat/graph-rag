"""Pair-specific source-fidelity guardrails and prompt notes.

Some rules depend on the (native, target) PAIR, not on either language
alone — the clearest example is the Korean '자세히'/'더 자세히' distinction: it
is a rule about translating FROM Korean INTO English, not a property of
English or Korean in isolation. Before this module existed, that rule lived
inline in ``quiz_bundle.py`` gated by ``if language == "english"``, which
silently assumed native=korean (the only native language wired up before the
3-pair restriction) and would have fired nonsensically for any other native
language sharing an english target.

``PAIR_RULES`` is keyed by ``(native, target)`` and mirrors
``languages.SUPPORTED_PAIRS`` — a 4th pair gets its own entry here the same
way it gets its own language pack.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable

_NORMALIZER = Callable[[str], str]


@dataclass(frozen=True)
class SourceGuardrail:
    """One source-fidelity rule: what NOT to invent when the source text
    matches ``source_re`` but not the stronger, explicitly-licensed
    ``licensed_re``.

    ``normalize_target``/``normalize_native`` are optional deterministic
    fixups applied to already-generated plan segments (see
    ``_apply_pair_normalizations`` in ``quiz_bundle.py``). They exist only
    for the one pattern that has a confidently-correct mechanical rewrite
    (Korean 자세히 -> English closely/close); a pair without a specific
    normalizer relies on the prompt note (``note``) alone, since guessing at
    a rewrite regex without real generation data to validate it against
    risks introducing a new bug rather than fixing one.
    """

    code: str
    source_re: re.Pattern[str]
    licensed_re: re.Pattern[str] | None = None
    note: str = ""
    licensed_note: str | None = None
    normalize_target: _NORMALIZER | None = None
    normalize_native: _NORMALIZER | None = None

    def licensed(self, source_text: str) -> bool:
        return bool(self.licensed_re and self.licensed_re.search(source_text))


@dataclass(frozen=True)
class PairRules:
    native: str
    target: str
    guardrails: tuple[SourceGuardrail, ...] = ()
    prompt_notes: str = ""


# -- (korean, english): the original 자세히/더 자세히 guardrail, unchanged ------

_KO_DETAIL_RE = re.compile(r"자세(?:히|하게)")
_KO_DETAIL_LICENSED_RE = re.compile(r"(?:더|더욱|한층|좀\s*더|이전보다|전보다)\s*(?:자세|상세)")


def _en_detail_normalize_target(value: str) -> str:
    normalized = re.sub(
        r"\bmore\s+closely\b", "closely",
        re.sub(r"\ba\s+closer\s+look\b", "a close look", value, flags=re.I),
        flags=re.I,
    )
    return re.sub(r"\bcloser\b", "close", normalized, flags=re.I)


def _ko_detail_normalize_native(value: str) -> str:
    return value.replace("더 자세히", "자세히")


_KO_EN_DETAIL_GUARDRAIL = SourceGuardrail(
    code="comparative_detail",
    source_re=_KO_DETAIL_RE,
    licensed_re=_KO_DETAIL_LICENSED_RE,
    note=(
        "The source says 자세히, NOT 더 자세히. Use 'closely' or 'a close look'; "
        "NEVER use 'closer' or 'more closely'."
    ),
    licensed_note=(
        "The source explicitly says 더 자세히: preserve the comparative meaning "
        "with 'more closely' or 'a closer look'."
    ),
    normalize_target=_en_detail_normalize_target,
    normalize_native=_ko_detail_normalize_native,
)

# -- (korean, german): the same distinction, German comparatives -------------
# genauer/näher ("more precisely/closer") vs genau/nah ("precisely/close").
# No auto-normalizer yet — German comparative morphology (schwach/stark
# declension endings on the adjective) makes a confident mechanical rewrite
# harder to get right than English's invariant "more closely"/"closely";
# the prompt note is enforced by the plan-QA reviewer instead until eval data
# justifies a specific regex.

_KO_EN_DETAIL_GUARDRAIL_DE = SourceGuardrail(
    code="comparative_detail",
    source_re=_KO_DETAIL_RE,
    licensed_re=_KO_DETAIL_LICENSED_RE,
    note=(
        "The source says 자세히, NOT 더 자세히. Use 'genau' or 'genau ansehen'; "
        "NEVER use the comparative 'genauer' or 'näher'."
    ),
    licensed_note=(
        "The source explicitly says 더 자세히: preserve the comparative meaning "
        "with 'genauer' or 'näher'."
    ),
)

# -- (english, korean): soft vs strong obligation -----------------------------
# English "should"/"ought to" is advice, not a rule; only "must"/"have to"/
# "need to" license Korean's strong obligation ending -어야 한다. Getting this
# backwards is a common calque error in the opposite (ko->en) direction's
# rubric too, so this is the en->ko mirror of the same "don't invent
# intensity" principle, on a different axis (modality instead of comparison).

_EN_SOFT_MODAL_RE = re.compile(r"\b(?:should|ought to)\b", re.IGNORECASE)
_EN_STRONG_MODAL_RE = re.compile(r"\b(?:must|have to|has to|need to|needs to)\b", re.IGNORECASE)

_EN_KO_MODAL_GUARDRAIL = SourceGuardrail(
    code="modal_strength",
    source_re=_EN_SOFT_MODAL_RE,
    licensed_re=_EN_STRONG_MODAL_RE,
    note=(
        "The source says 'should'/'ought to' (soft advice), NOT 'must'/'have to'. "
        "Use a suggestion form like '-는 게 좋다' or '-어야 할 것 같다'; "
        "NEVER the strong obligation ending '-어야 한다'."
    ),
    licensed_note=(
        "The source explicitly says 'must'/'have to'/'need to': the strong "
        "obligation ending '-어야 한다' is licensed here."
    ),
)

PAIR_RULES: dict[tuple[str, str], PairRules] = {
    ("korean", "english"): PairRules(
        native="korean", target="english", guardrails=(_KO_EN_DETAIL_GUARDRAIL,)
    ),
    ("korean", "german"): PairRules(
        native="korean", target="german", guardrails=(_KO_EN_DETAIL_GUARDRAIL_DE,)
    ),
    ("english", "korean"): PairRules(
        native="english", target="korean", guardrails=(_EN_KO_MODAL_GUARDRAIL,)
    ),
}

_EMPTY = PairRules(native="", target="")


def pair_rules(native: str | None, target: str | None) -> PairRules:
    """Registry lookup. An unregistered pair gets the empty ruleset — no
    guardrails, no prompt notes — rather than an error, so a 4th pair with no
    entry here yet still generates (just without pair-specific fidelity
    checks), matching how an unregistered target falls back to the generic
    language pack instead of failing."""
    key = ((native or "").strip().lower(), (target or "").strip().lower())
    return PAIR_RULES.get(key, _EMPTY)
