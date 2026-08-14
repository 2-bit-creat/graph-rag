"""German target-language pack.

Phase 2 carried over the German-specific logic that already existed
(common-noun capitalization tolerance, the all-title-case proper-name
heuristic) so behavior stayed unchanged — see
``test_german_common_noun_capitalization_is_allowed`` and the
``surface_answer`` parametrized test in ``test_quiz_bundle_repair_loop.py``.

Phase 4 (this revision) adds the gates German never had at all, closing the
gap with English:

- ``de_not_infinitive`` — a verb_phrase/collocation canonical form must be a
  dictionary infinitive, not a participle or preterite. English's analogous
  rule is ``EnglishTargetPack.base_form_reason``.
- ``de_separable_split`` — if the canonical starts with a separable prefix,
  the surface answer must still contain that prefix somewhere (a separable
  verb answer is legitimately discontinuous in German, e.g. "nimmt ... vor",
  but the prefix can't just vanish).
- ``de_case_drift`` — if the canonical carries a determiner + noun, the
  surface answer's noun must be the same lexeme (catches an answer that
  silently swapped in a different noun).
- ``teachability_reason`` — a bare separable prefix is not teachable; a
  leading determiner is only disqualifying for a short (<=2 token) answer,
  so "auf der Webseite" survives while "der Bericht" doesn't.
- ``mask_answer`` — preserves original capitalization (a lowercased German
  noun hint is simply wrong, unlike English where hints are case-insensitive).

``max_words``/``coordinators`` are now configured, which — per the Phase 2
design — is what actually turns on ``length_reason``/``sibling_join_reason``/
``clause_answer_reason``/``base_form_reason`` in ``_select_quality_expression_chunks``.
No caller code changes; only this pack's data does.
"""

from __future__ import annotations

import re

from . import reasons as R
from .base import NativeQuizPack, TargetLanguagePack
from .english import _same_lexeme

_GERMAN_WORD_RE = re.compile(r"[A-Za-zÄÖÜäöüß]+")

# German separable verb prefixes (e.g. "vornehmen" -> vor + nehmen). Shared
# with quiz_generator.py's freedom-mode seed matcher, which imports this list
# rather than keeping its own copy.
DE_SEPARABLE_PREFIXES = (
    "zurück", "durch", "weiter", "über", "unter", "wider", "um",
    "vor", "aus", "auf", "her", "hin", "los", "mit", "nach",
    "ein", "bei", "weg", "an", "ab", "zu", "fort",
)

_DE_DETERMINERS = frozenset({
    "der", "die", "das", "den", "dem", "des",
    "ein", "eine", "einen", "einem", "einer", "eines",
})
# German possessives inflect for case/gender/number, so the bare stems are not
# enough — "auf seinen Vorschlag" and "in ihrer Freizeit" have to be caught the
# same way "in my spare time" is. Generated from the six stems rather than
# written out, so no ending is quietly missing.
_DE_POSSESSIVE_STEMS = ("mein", "dein", "sein", "ihr", "unser", "euer")
_DE_POSSESSIVE_ENDINGS = ("", "e", "en", "em", "er", "es")
_DE_POSSESSIVES = frozenset(
    stem + ending
    for stem in _DE_POSSESSIVE_STEMS
    for ending in _DE_POSSESSIVE_ENDINGS
    # "euer" loses its second e when inflected (eure, euren), and "unser"
    # optionally does; include both spellings rather than guessing.
) | frozenset({"eure", "euren", "eurem", "eurer", "eures",
               "unsre", "unsren", "unsrem", "unsrer", "unsres"})

_DE_IRREGULAR_INFINITIVES = frozenset({"sein", "tun"})
_DE_WEAK_PRETERITE_RE = re.compile(r"(?:te|test|tet)$", re.IGNORECASE)


class GermanTargetPack(TargetLanguagePack):
    language = "german"
    coverage = "full"

    word_re = _GERMAN_WORD_RE
    possessive_determiners = _DE_POSSESSIVES
    coordinators = frozenset({"und", "während", "sowie", "bzw", "sowohl"})
    max_words = {"verb_phrase": 7, "collocation": 5}
    min_single_token_len = 3

    teaching_guide = (
        "Focus on case (Nominativ/Akkusativ/Dativ/Genitiv), V2 and subordinate-"
        "clause word order, separable verbs, and noun gender. Respect Sie/du register."
    )
    quality_rubric = (
        "Formuliere idiomatisches, modernes Deutsch — übernimm nicht wörtlich den Satzbau "
        "der Ausgangssprache. Ein koreanischer Definitionssatz ('X는 Y이다'), der X als ein "
        "abstraktes Recht einer anderen Partei beschreibt, darf nicht zu einer wörtlichen "
        "Kopula ('X ist Y') werden; verwende stattdessen ein natürliches Prädikat (z. B. 'X "
        "gibt Investoren das Recht, ...', nicht 'X ist ein Recht für Investoren, ...'). "
        "Eigennamen und bloßer Kontext dürfen nie Teil der Lernantwort sein; die Antwort "
        "enthält nur den wiederverwendbaren Ausdruck."
    )
    plan_prompt_notes = (
        "For German verb_phrase and collocation candidates, canonical_form MUST use the "
        "dictionary infinitive (vornehmen, vergleichen, abholen; never nahm vor, verglich, "
        "abgeholt). A separable-prefix verb keeps its prefix attached in canonical_form "
        "(vornehmen, not nehmen); the surface_form may realize it discontinuously "
        "(nimmt ... vor) but must still contain the prefix somewhere."
    )
    author_prompt_notes = (
        "If surface_answer realizes a German separable verb, prefer a sentence where the "
        "prefix and stem stay together and contiguous — the past participle (vorgenommen), "
        "an infinitive after a modal (muss ... vornehmen), or a subordinate clause (..., weil "
        "er es vornimmt) — over a present-tense main clause that strands the prefix at the "
        "end of the sentence, since surface_answer must be one contiguous span."
    )

    def teachability_reason(self, answer: str) -> str | None:
        normalized = (answer or "").strip()
        if not normalized:
            return R.reason(R.NOT_TEACHABLE, "answer is empty")
        words = self.tokens(normalized)
        if not words:
            return R.reason(R.NOT_TEACHABLE, "answer has no word characters")
        lowered = [w.lower() for w in words]
        if len(words) == 1 and lowered[0] in DE_SEPARABLE_PREFIXES:
            return R.reason(R.NOT_TEACHABLE, f"{words[0]!r} is a bare separable prefix")
        if lowered[0] in _DE_DETERMINERS and len(words) <= 2:
            return R.reason(
                R.LEADING_DETERMINER,
                f"answer starts with determiner {words[0]!r} and is too short to be useful alone",
            )
        possessive_reason = self.internal_possessive_reason(words)
        if possessive_reason:
            return possessive_reason
        if len(words) == 1 and len(words[0]) < self.min_single_token_len:
            return R.reason(R.NOT_TEACHABLE, f"single token {words[0]!r} is too short")
        return None

    def internal_possessive_reason(self, words: list[str]) -> str | None:
        """German-specific: a possessive only counts when a noun follows it.

        ``sein`` and ``ihr`` are homographs of the infinitive "to be" and the
        pronoun "you/her", so the English rule ("this token is a possessive")
        would reject real expressions — ``überrascht sein`` is a genuine
        canonical form from the eval set. German capitalizes nouns, so a
        following capitalized token is what separates the possessive
        determiner ``in seiner Freizeit`` from the verb ``überrascht sein``.

        Unlike English this scans from the FIRST token. English relies on
        ``leading_determiners`` to cover position 0, but German's leading
        determiner rule only fires for answers of two words or fewer and its
        list holds articles only — so without scanning position 0 here,
        ``ihre Unterlagen überarbeiten`` is caught nowhere at all.
        """
        for index, word in enumerate(words):
            if word.casefold() not in self.possessive_determiners:
                continue
            following = words[index + 1] if index + 1 < len(words) else ""
            if following[:1].isupper():
                return R.reason(
                    R.INTERNAL_POSSESSIVE,
                    f"answer contains possessive {word!r} before noun {following!r} "
                    f"at position {index}; end the answer before it",
                )
        return None

    def base_form_reason(self, canonical: str, kind: str) -> str | None:
        if kind not in {"verb_phrase", "collocation"}:
            return None
        tokens = self.tokens(canonical)
        if not tokens:
            return None
        first = tokens[0]
        lowered = first.lower()
        if lowered in _DE_IRREGULAR_INFINITIVES or lowered.endswith(("en", "eln", "ern")):
            return None  # a dictionary infinitive — the common, unambiguous case
        if lowered.startswith("ge") and lowered.endswith(("t", "en")):
            return R.reason(
                R.DE_NOT_INFINITIVE,
                f"{canonical!r} starts with a past participle {first!r}; use the infinitive",
            )
        if _DE_WEAK_PRETERITE_RE.search(lowered):
            return R.reason(
                R.DE_NOT_INFINITIVE,
                f"{canonical!r} starts with a preterite form {first!r}; use the infinitive",
            )
        return None

    def proper_name_reason(self, text: str, kind: str) -> str | None:
        base_reason = super().proper_name_reason(text, kind)
        if base_reason:
            return base_reason
        words = self.tokens(text)
        # German common nouns are capitalized by rule. Only reject a phrase
        # made entirely of title-cased tokens — a strong multi-word name signal.
        if len(words) > 1 and all(word[:1].isupper() for word in words):
            return R.reason(R.PROPER_NAME, f"{text!r} is entirely title-cased")
        return None

    def surface_boundary_reason(
        self, *, answer: str, sentence_target: str, canonical_form: str
    ) -> str | None:
        canonical_words = self.tokens(canonical_form)
        if canonical_words:
            first = canonical_words[0].lower()
            prefix = next(
                (p for p in DE_SEPARABLE_PREFIXES if first == p or (first.startswith(p) and len(first) > len(p) + 2)),
                None,
            )
            if prefix:
                surface_lowered = [t.lower() for t in self.tokens(answer)]
                # The prefix survives either as its own token ("nimmt ... vor")
                # or fused into a participle ("vorgenommen") — only a fully
                # missing prefix (e.g. a stripped "genommen") is rejected.
                if not any(t == prefix or t.startswith(prefix) for t in surface_lowered):
                    return R.reason(
                        R.DE_SEPARABLE_SPLIT,
                        f"separable prefix {prefix!r} from canonical_form {canonical_form!r} is "
                        f"missing from surface_answer {answer!r}; rewrite with a subordinate "
                        "clause, the perfect tense, or a modal so the prefix stays present",
                    )
            if canonical_words[0].lower() in _DE_DETERMINERS and len(canonical_words) > 1:
                canonical_noun = canonical_words[1]
                surface_words = self.tokens(answer)
                if not any(_same_lexeme(canonical_noun, w) for w in surface_words):
                    return R.reason(
                        R.DE_CASE_DRIFT,
                        f"surface_answer {answer!r} does not inflect the canonical noun "
                        f"{canonical_noun!r} from {canonical_form!r}",
                    )

        answer_words = self.tokens(answer)
        if not answer_words:
            return None
        answer_at_sentence_start = sentence_target.lstrip().casefold().startswith(answer.casefold())
        for index, word in enumerate(answer_words):
            if not word[:1].isupper() or word.casefold() == "i":
                continue
            if index == 0 and answer_at_sentence_start and canonical_words:
                if _same_lexeme(word, canonical_words[0]):
                    continue
            if any(_same_lexeme(word, canonical_word) for canonical_word in canonical_words):
                continue
            return R.reason(
                R.ENTITY_LEAK, f"surface_answer adds entity-like token {word!r} outside canonical_form"
            )
        return None

    def mask_answer(self, answer: str, level: int) -> str:
        """Same level bands as the base pack, but preserves original
        capitalization — German common nouns are capitalized by rule, so a
        lowercased hint would be actively wrong, not just imprecise."""
        word = (answer or "").strip()
        if not word:
            return ""

        def _hint_token(token: str) -> str:
            n = len(token)
            if n == 0:
                return ""
            if level <= 30:
                reveal = max(1, round(n * 0.3))
                parts = list(token[:reveal]) + ["_"] * (n - reveal)
            elif level <= 70:
                parts = [token[0]] + ["_"] * (n - 1)
            elif n > 7:
                parts = [token[0]] + ["_"] * (n - 1)
            else:
                parts = ["_"] * n
            return " ".join(parts)

        tokens = word.split()
        if len(tokens) > 1:
            return "   ".join(_hint_token(t) for t in tokens)
        return _hint_token(word)
