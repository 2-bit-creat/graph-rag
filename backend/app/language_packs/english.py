"""English target-language pack.

Encodes the gates that used to live inline as ``if language == "english"``
branches across ``quiz_bundle.py`` — this is the one pack with full parity
coverage today (verified by the golden-prompt test and the existing quality
suite), and every other pack is measured against it.
"""

from __future__ import annotations

import re
from typing import Any

from . import reasons as R
from .base import NativeQuizPack, TargetLanguagePack

_ENGLISH_WORD_RE = re.compile(r"[A-Za-z]+(?:['-][A-Za-z]+)*")
_EN_BLANK_RE = re.compile(r"^[a-zA-Z][a-zA-Z' -]*[a-zA-Z]$|^[a-zA-Z]$")

_TRIVIAL_ENGLISH_CLOZES = frozenset({
    "a", "an", "the", "and", "or", "but", "so", "if", "of", "to", "in", "on",
    "at", "by", "for", "from", "with", "as", "is", "am", "are", "was", "were",
    "be", "been", "being", "have", "has", "had", "do", "does", "did", "can", "could",
    "will", "would", "shall", "should", "may", "might", "must", "not", "no", "yes",
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "sub", "main", "major", "minor",
})
_ENGLISH_LEADING_DETERMINERS = frozenset({
    "a", "an", "the", "this", "that", "these", "those", "my", "your", "his",
    "her", "its", "our", "their",
})
_ENGLISH_POSSESSIVES = frozenset({
    "my", "your", "his", "her", "its", "our", "their",
})
_IRREGULAR_PAST = frozenset({
    "took", "went", "made", "saw", "did", "had", "was", "were", "wrote",
    "spoke", "bought",
})
_LENGTH_GATED_KINDS = frozenset({"verb_phrase", "collocation"})
_EN_SUBJECT_START_RE = re.compile(
    r"^(?:i|you|he|she|it|we|they|this|that|these|those|the\s+\w+)\b", re.IGNORECASE
)


class EnglishTargetPack(TargetLanguagePack):
    language = "english"
    coverage = "full"
    script = "latin"

    word_re = _ENGLISH_WORD_RE
    function_words = _TRIVIAL_ENGLISH_CLOZES
    leading_determiners = _ENGLISH_LEADING_DETERMINERS
    possessive_determiners = _ENGLISH_POSSESSIVES
    coordinators = frozenset({"and", "while"})
    max_words = {"verb_phrase": 7, "collocation": 5}
    min_single_token_len = 4
    min_sentence_tokens = 3

    teaching_guide = (
        "Focus on collocations, phrasal verbs, article/tense naturalness, and "
        "prepositions. Penalize word-for-word translationese."
    )
    quality_rubric = (
        "Write idiomatic contemporary English — restructure the sentence into a natural "
        "English predicate rather than mirroring the native sentence's grammar. A Korean "
        "definitional sentence ('X는 Y이다') that casts X as an abstract right/permission/"
        "ability belonging to someone else must NOT become a literal English copula ('X is "
        "Y'): use the natural predicate instead, e.g. 'X gives investors the right to ...', "
        "never 'X is a legal right for investors to ...'. The same applies to any '이다' "
        "sentence describing what X does, allows, or causes rather than what category X "
        "belongs to. Keep names and surrounding context outside the learnable answer; the "
        "answer must contain only the reusable expression."
    )

    def teachability_reason(self, answer: str) -> str | None:
        normalized = (answer or "").strip().casefold()
        if not normalized:
            return R.reason(R.NOT_TEACHABLE, "answer is empty")
        if normalized in self.function_words or normalized.isdigit():
            return R.reason(R.NOT_TEACHABLE, f"{normalized!r} is trivial or a bare number")
        words = self.tokens(normalized)
        if not words or " ".join(words).casefold() != normalized:
            return R.reason(R.NOT_TEACHABLE, f"{normalized!r} is not purely word characters")
        if words[0].casefold() in self.leading_determiners:
            return R.reason(R.LEADING_DETERMINER, f"answer starts with determiner {words[0]!r}")
        possessive_reason = self.internal_possessive_reason(words)
        if possessive_reason:
            return possessive_reason
        if len(words) == 1 and len(words[0]) < self.min_single_token_len:
            return R.reason(R.NOT_TEACHABLE, f"single token {words[0]!r} is too short")
        return None

    def base_form_reason(self, canonical: str, kind: str) -> str | None:
        if kind not in _LENGTH_GATED_KINDS:
            return None
        tokens = self.tokens(canonical)
        if not tokens:
            return None
        first = tokens[0]
        if first.endswith("ing") or first.endswith("ed") or first.casefold() in _IRREGULAR_PAST:
            return R.reason(
                R.EN_INFLECTED_FIRST_WORD,
                f"{canonical!r} starts with inflected verb form {first!r}, use the base form",
            )
        return None

    def length_reason(self, canonical: str, kind: str) -> str | None:
        if kind not in _LENGTH_GATED_KINDS:
            return None
        return super().length_reason(canonical, kind)

    def sibling_join_reason(self, canonical: str) -> str | None:
        return super().sibling_join_reason(canonical)

    def clause_answer_reason(
        self, chunk: dict[str, Any], key: str, native: "NativeQuizPack"
    ) -> str | None:
        return super().clause_answer_reason(chunk, key, native)

    def proper_name_reason(self, text: str, kind: str) -> str | None:
        base_reason = super().proper_name_reason(text, kind)
        if base_reason:
            return base_reason
        words = self.tokens(text)
        # A dictionary-form English expression may accidentally retain
        # sentence-initial capitalization, but an internal title-cased token
        # is a name.
        if any(word[:1].isupper() for word in words[1:]):
            return R.reason(R.PROPER_NAME, f"{text!r} has an internal title-cased token")
        return None

    def surface_boundary_reason(
        self, *, answer: str, sentence_target: str, canonical_form: str
    ) -> str | None:
        answer_words = self.tokens(answer)
        canonical_words = self.tokens(canonical_form)
        if not answer_words:
            return None
        answer_at_sentence_start = sentence_target.lstrip().casefold().startswith(answer.casefold())
        for index, word in enumerate(answer_words):
            if not word[:1].isupper() or word.casefold() == "i":
                continue
            if index == 0 and answer_at_sentence_start and canonical_words:
                if _same_lexeme(word, canonical_words[0]):
                    continue
            return R.reason(
                R.ENTITY_LEAK, f"surface_answer adds entity-like token {word!r} outside canonical_form"
            )
        return None

    def is_valid_blank(self, text: str) -> bool:
        return bool(_EN_BLANK_RE.match((text or "").strip()))

    def normalize_learner_answer(self, text: str) -> str:
        return (text or "").strip().casefold()


def _same_lexeme(left: str, right: str) -> bool:
    """Conservative inflection match used only for capitalization fallback checks."""
    left = left.casefold()
    right = right.casefold()
    if left == right:
        return True
    return len(left) >= 4 and len(right) >= 4 and left[:4] == right[:4]


class EnglishNativePack(NativeQuizPack):
    language = "english"
    script_re = re.compile(r"[A-Za-z]")
    script_label = "English"
    generic_filler_re = re.compile(
        r"(?:the (?:natural|appropriate) expression|think of an expression|in context)",
        re.IGNORECASE,
    )

    def meaning_question(self, meaning: str) -> str:
        return f"Which expression means '{meaning}'?"

    def default_question(self, quiz_type: str, target_label: str) -> str:
        if quiz_type == "cloze":
            return f"Type the missing {target_label} word."
        if quiz_type == "scramble":
            return f"Arrange the {target_label} words in the correct order."
        if quiz_type == "mcq_nuance":
            return f"Choose the {target_label} expression that fits the context."
        return f"Complete the {target_label} exercise."

    def subject_marked(self, native_part: str) -> bool:
        """English has no case marking, so the clue is positional: a pronoun
        or a determiner+noun ("the report") at the very start of the clue
        usually means the plan wrote a subject there, not a reusable
        expression fragment."""
        return bool(_EN_SUBJECT_START_RE.match((native_part or "").strip()))
