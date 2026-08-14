"""Generic target/native language packs.

``TargetLanguagePack`` and ``NativeQuizPack`` carry every language-specific
rule the quiz bundle generator needs: tokenization, teachability/length/
sibling-join/base-form/proper-name/tautology/surface-boundary gates, answer
normalization, and the prompt text (teaching guide + quality rubric).

Plain classes with overridable data attributes and default method bodies —
not frozen dataclasses of callables — because the gates are polymorphic and
share state (``teachability_reason`` reads ``function_words``,
``leading_determiners``, ``min_single_token_len``, and ``tokens()`` together),
which a dataclass-of-callables can only express by threading the pack through
every call site.

The generic defaults here are deliberately NOT empty: unicode tokenization,
empty/digit/punctuation-only rejection, minimum token length, a per-``kind``
word cap when one is configured, tautology detection on 4+ character tokens,
entity containment, and sentence-length all run for ANY target language,
including one with no dedicated pack. Only genuinely morphology-specific
checks (whether a canonical form is a dictionary/base form; capitalization-
based proper-name/entity detection, which depends on a script having case at
all) return ``None`` — i.e. "no opinion" — in the generic pack. That default
is loud, not silent: ``coverage`` stays ``"generic"``, which the caller is
expected to log once and record in traces/eval reports, so a 4th target
language degrades visibly instead of silently skipping every gate the way
the old ``if language == "english"`` branches did for German and Korean.
"""

from __future__ import annotations

import re
from typing import Any

from . import reasons as R

_WORD_RE = re.compile(r"\w+(?:['-]\w+)*", re.UNICODE)
_DIGIT_RE = re.compile(r"\d")


class TargetLanguagePack:
    """Rules for the language being learned (the quiz *answer* language)."""

    language: str = "generic"
    coverage: str = "generic"  # "full" for a pack with real morphology gates
    script: str = "latin"

    word_re: re.Pattern[str] = _WORD_RE
    function_words: frozenset[str] = frozenset()
    leading_determiners: frozenset[str] = frozenset()
    # Possessive determiners whose referent shifts with the speaker ("their
    # shares" for the company, "my shares" for the investor telling the same
    # story). Deixis is not vocabulary, so one inside an answer means the blank
    # ran past the reusable expression into a sentence-specific object phrase.
    # Empty here — a pack with no list keeps its old behaviour.
    possessive_determiners: frozenset[str] = frozenset()
    coordinators: frozenset[str] = frozenset()
    # A separate, smaller stopword set for tautology detection (content words
    # only) — distinct from ``function_words``, which drives the teachability
    # gate. The two lists diverge in the original code and must stay separate.
    tautology_stopwords: frozenset[str] = frozenset({
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "and", "or",
        "with", "by", "is", "are", "as", "that", "this", "its", "their",
    })
    tautology_min_len: int = 4
    # kind -> max token count for a canonical/surface answer of that kind.
    max_words: dict[str, int] = {}
    min_single_token_len: int = 2
    min_sentence_tokens: int = 3

    teaching_guide: str = ""
    quality_rubric: str = ""
    plan_prompt_notes: str = ""
    author_prompt_notes: str = ""

    # -- tokenization / matching -------------------------------------------------

    def tokens(self, text: str) -> list[str]:
        return self.word_re.findall(text or "")

    def contains_span(self, haystack: str, needle: str) -> bool:
        """Whether ``needle`` occurs inside ``haystack`` (exact substring by
        default; a target with flexible spacing, e.g. Korean, overrides this)."""
        return bool(needle) and needle in (haystack or "")

    def answer_boundary_re(self, answer: str) -> re.Pattern[str]:
        """Word-boundary-aware matcher for locating ``answer`` inside a
        sentence — used to build the ``___`` prompt and to verify the answer
        occurs exactly once."""
        return re.compile(
            r"(?<![A-Za-z0-9])" + re.escape(answer) + r"(?![A-Za-z0-9])",
            re.IGNORECASE,
        )

    def contains_term(self, text: str, term: str) -> bool:
        """Whether an excluded context-entity ``term`` appears in ``text``."""
        if not term:
            return False
        pattern = re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)
        return bool(pattern.search(text or ""))

    # -- gates: return None (pass) or a "code: message" string ------------------

    def teachability_reason(self, answer: str) -> str | None:
        normalized = (answer or "").strip().casefold()
        if not normalized:
            return R.reason(R.NOT_TEACHABLE, "answer is empty")
        if _DIGIT_RE.fullmatch(normalized.replace(" ", "")):
            return R.reason(R.NOT_TEACHABLE, "answer is only digits")
        if normalized in self.function_words:
            return R.reason(R.FUNCTION_WORD_ANSWER, f"{normalized!r} is a function word")
        words = self.tokens(normalized)
        if not words:
            return R.reason(R.NOT_TEACHABLE, "answer has no word characters")
        if words[0].casefold() in self.leading_determiners:
            return R.reason(R.LEADING_DETERMINER, f"answer starts with determiner {words[0]!r}")
        possessive_reason = self.internal_possessive_reason(words)
        if possessive_reason:
            return possessive_reason
        if len(words) == 1 and len(words[0]) < self.min_single_token_len:
            return R.reason(R.NOT_TEACHABLE, f"single token {words[0]!r} is too short")
        return None

    def internal_possessive_reason(self, words: list[str]) -> str | None:
        """Reject an answer that swallows a possessive after its first word.

        ``leading_determiners`` already blocks "their key results"; this is the
        same rule one token later, for "buy back their shares or bonds" — the
        blank there spans a reusable verb plus a possessed object, and the
        native gloss has to pick a person ("내 주식") that the target text
        renders from the other side ("their shares"). Trimming the blank back
        to "buy back" leaves the possessive printed as context, where it needs
        no guessing.
        """
        for index, word in enumerate(words[1:], start=1):
            if word.casefold() in self.possessive_determiners:
                return R.reason(
                    R.INTERNAL_POSSESSIVE,
                    f"answer contains possessive {word!r} at position {index}; "
                    f"end the answer before it",
                )
        return None

    def base_form_reason(self, canonical: str, kind: str) -> str | None:
        """Whether ``canonical`` is a dictionary/base form appropriate for
        ``kind`` (e.g. English infinitive, German infinitive, Korean 하다-lemma).
        Morphology-specific — the generic pack has no opinion."""
        return None

    def length_reason(self, canonical: str, kind: str) -> str | None:
        cap = self.max_words.get(kind)
        if cap is None:
            return None
        n = len(self.tokens(canonical))
        if n > cap:
            return R.reason(R.TOO_LONG, f"{kind} {canonical!r} has {n} tokens, cap is {cap}")
        return None

    def sibling_join_reason(self, canonical: str) -> str | None:
        if not self.coordinators:
            return None
        tokens = {t.casefold() for t in self.tokens(canonical)}
        hit = tokens & self.coordinators
        if hit:
            return R.reason(R.SIBLING_JOIN, f"{canonical!r} joins siblings via {sorted(hit)!r}")
        return None

    def clause_answer_reason(
        self, chunk: dict[str, Any], key: str, native: "NativeQuizPack"
    ) -> str | None:
        """Reject a whole subject+predicate clause mislabeled as a reusable
        expression, using the native pack's ``subject_marked`` to read the
        clue off ``meaning_parts[].native`` (the language the plan actually
        wrote the clue in)."""
        for part in chunk.get("meaning_parts") or []:
            if not isinstance(part, dict):
                continue
            target_part = " ".join(self.tokens(str(part.get("target") or "").casefold()))
            native_part = str(part.get("native") or "").strip()
            if (
                len(target_part.split()) >= 2
                and key.startswith(f"{target_part} ")
                and native.subject_marked(native_part)
            ):
                return R.reason(
                    R.CLAUSE_ANSWER, f"{key!r} looks like a subject+predicate clause"
                )
        return None

    _ALL_CAPS_RE = re.compile(r"\b[A-ZÄÖÜ]{2,}\b")

    def proper_name_reason(self, text: str, kind: str) -> str | None:
        if kind in {"proper_name", "person", "organization", "brand", "location", "event"}:
            return R.reason(R.PROPER_NAME, f"kind={kind}")
        if any(ch.isdigit() for ch in text) or "@" in text or "://" in text:
            return R.reason(R.PROPER_NAME, f"{text!r} contains a digit/URL/handle")
        if self._ALL_CAPS_RE.search(text):
            return R.reason(R.PROPER_NAME, f"{text!r} contains an ALL-CAPS token")
        return None

    def surface_boundary_reason(
        self, *, answer: str, sentence_target: str, canonical_form: str
    ) -> str | None:
        """Entity-leak check only in the generic pack; capitalization-based
        detection needs a script with case and belongs to a concrete pack."""
        return None

    def tautology_reason(self, text: str) -> str | None:
        """Flag a phrase that restates the same headword twice, e.g. a
        discourse frame stacked on a term that already carries the frame's
        own head noun ("in the event of credit events" repeats "event").
        Mechanical, not a real reduplication idiom ("day by day") — only
        looks at content words of ``tautology_min_len``+ characters."""
        words = [w.casefold() for w in self.tokens(text)]
        lemmas = [
            w[:-1] if w.endswith("s") and len(w) > self.tautology_min_len else w
            for w in words
            if w not in self.tautology_stopwords and len(w) >= self.tautology_min_len
        ]
        if len(lemmas) != len(set(lemmas)):
            return R.reason(R.TAUTOLOGY, f"{text!r} repeats a headword")
        return None

    def sentence_length_reason(self, sentence: str) -> str | None:
        n = len(self.tokens(sentence))
        if n < self.min_sentence_tokens:
            return R.reason(R.SENTENCE_TOO_SHORT, f"sentence has {n} tokens, need {self.min_sentence_tokens}")
        return None

    def sentence_language_reason(self, sentence: str) -> str | None:
        """Reject a sentence written mainly in a different script when known."""
        return None

    # How much of the sentence must survive outside the blank. Two tokens of
    # stem is the floor: "Ich habe ___." tells the learner nothing about which
    # expression belongs there.
    min_stem_tokens: int = 3

    def blank_context_reason(self, sentence: str, answer: str) -> str | None:
        """Reject a blank that swallows the sentence it is supposed to sit in.

        A cloze teaches by making the surrounding context select the answer.
        When the blank takes the whole predicate and leaves a bare stem
        ("Ich habe ___." for "die Präsentationsunterlagen genau geprüft"),
        nothing in the prompt narrows the answer down and the card is a
        translation exercise wearing a cloze's clothes — the learner cannot
        get it right except by reproducing the reference sentence.
        """
        answer_tokens = len(self.tokens(answer))
        if answer_tokens < 2:
            return None  # a short blank always leaves the sentence standing
        stem = len(self.tokens(sentence)) - answer_tokens
        if stem < self.min_stem_tokens:
            return R.reason(
                R.SENTENCE_TOO_SHORT,
                f"blank {answer!r} leaves only {stem} token(s) of context; "
                f"lengthen the sentence or shorten the blank",
            )
        return None

    # -- output-side -------------------------------------------------------------

    def is_valid_blank(self, text: str) -> bool:
        cleaned = (text or "").strip()
        return bool(cleaned)

    def normalize_learner_answer(self, text: str) -> str:
        return (text or "").strip().casefold()

    def mask_answer(self, answer: str, level: int) -> str:
        """Level-scaled letter-reveal hint. Generic implementation mirrors the
        original Latin-only ``_hint_single_token`` policy: at low level reveal
        ~30% of characters, at mid level reveal only the first character, at
        high level reveal nothing (or the first character for long words)."""
        word = (answer or "").strip().lower()
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


class NativeQuizPack:
    """Rules for the learner's native language (question copy, glosses)."""

    language: str = "generic"
    script_re: re.Pattern[str] = re.compile(r"[A-Za-z]")
    generic_filler_re: re.Pattern[str] = re.compile(r"$^")  # never matches
    script_label: str = "Generic"

    def meaning_question(self, meaning: str) -> str:
        return f"Which expression means '{meaning}'?"

    def default_question(self, quiz_type: str, target_label: str) -> str:
        if quiz_type == "cloze":
            return f"Type the missing {target_label} word."
        if quiz_type == "composition":
            return f"Write a sentence in {target_label}."
        return f"Complete the {target_label} exercise."

    def subject_marked(self, native_part: str) -> bool:
        """Whether ``native_part`` (a fragment from ``meaning_parts[].native``)
        looks like a marked grammatical subject in this native language —
        used by ``clause_answer_reason`` to catch a whole clause mislabeled
        as a reusable expression."""
        return False

    def target_label(self, target_language: str) -> str:
        return target_language.title()

    def contains_span(self, haystack: str, needle: str) -> bool:
        return bool(needle) and needle in (haystack or "")
