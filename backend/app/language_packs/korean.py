"""Korean target-language pack (en->ko) and Korean native-quiz pack (ko->en, ko->de).

Phase 2 moved the teaching guide/quality rubric and the native-side pieces
that already existed (the Korean composition question template, the generic-
filler regex) into ``KoreanNativePack``, and fixed one real bug: the missing
``"korean"`` entry in the Korean-label table that produced the broken
``"빈칸에 들어갈 Korean 단어를 입력하세요."`` string for an english-native learner.

Phase 5 (this revision) closes the gap with English on the TARGET side —
Korean previously had no dedicated gates at all, because every existing
gate was either Latin-regex-based (silently matching nothing on Hangul) or
explicitly scoped to ``{"english", "german"}``:

- ``function_words``/``coordinators`` data turns on the existing generic
  teachability/sibling-join checks for Korean the same way Phase 4 did for
  German — no caller changes needed.
- ``base_form_reason`` (``ko_not_dictionary_form``) — a verb_phrase/
  collocation canonical must be the 하다-lemma dictionary form (정리하다), not
  an inflected past tense (정리했다); the inflected form belongs in
  ``surface_form`` instead. Korean's counterpart to English's base-verb rule.
- ``teachability_reason`` adds ``ko_clause_answer`` on top of the inherited
  checks — a >=2-어절 answer starting with a subject-marked eojeol, or a
  >=3-어절 answer ending in a sentence-final ending, is a whole clause
  mislabeled as a reusable expression, not a real teachable target.
- ``answer_boundary_re`` is strict on both sides of the Hangul boundary
  (``ko_particle_boundary``) — the old Latin-only matcher had no opinion
  about a following Hangul character, so an author could ship
  ``surface_answer="회의"`` with an orphaned ``를`` right after it; that answer
  now simply fails to match at all, forcing the author to include the particle.
- ``contains_term`` fixes a real bug: the shared entity matcher used
  ``(?!\\w)`` as its right boundary, which never matches before a Hangul
  character, so a Korean entity followed by a particle (앤톡에서) could never
  be caught. Korean's version drops the right boundary — 앤톡 followed by
  anything is still 앤톡.
- ``mask_answer`` reveals 초성 (leading consonants) instead of whole Hangul
  syllables — the previous behavior sliced raw UTF-8 characters, which for a
  Korean answer meant the hint gave away a whole syllable (and often the
  verb root) at once.

``EnglishNativePack.subject_marked`` (in ``english.py``) gets its real
implementation here too, since it's what makes Korean's ``clause_answer_reason``
(inherited from the base pack) actually fire for en->ko instead of being a
silent no-op the way it was left in Phase 2.
"""

from __future__ import annotations

import re

from . import reasons as R
from .base import NativeQuizPack, TargetLanguagePack

_KOREAN_WORD_RE = re.compile(r"[가-힣]+|[A-Za-z]+|\d+")
_GENERIC_KO_CONTEXT_RE = re.compile(r"(문맥에\s*맞는|일반적인\s*표현|표현을\s*떠올려)")
_KO_SUBJECT_MARK_RE = re.compile(r"(?:이|가|은|는)$")

_KO_FUNCTION_WORDS = frozenset({
    "은", "는", "이", "가", "을", "를", "에", "에서", "으로", "와", "과",
    "도", "만", "의", "것", "수", "때", "입니다", "합니다", "이다",
})
_KO_SIBLING_RE = re.compile(r"(?:면서|으며|하며|그리고|고서|뿐만\s*아니라)")
_KO_DICTIONARY_FORM_RE = re.compile(r"[가-힣]다$")
_KO_INFLECTED_PAST_RE = re.compile(r"(?:았|었|였|겠)다$")
_KO_SUBJECT_EOJEOL_RE = re.compile(r"\S+(?:은|는|이|가)$")
# An object-marked tail: the span ends where the verb should begin.
_KO_OBJECT_TAIL_RE = re.compile(r"(?:을|를)$")
_KO_PREDICATE_TAIL_RE = re.compile(r"(?:다|요|니다|습니다)$")
# A bare 다-ending is the DICTIONARY form (검토하다) and the plain past
# (검토했다), not a signal that the span is a finished sentence — this pack's
# own ``base_form_reason`` requires canonical forms to end exactly that way.
# Korean being verb-final, treating every 다-ending as sentence-final rejected
# essentially every Korean verb phrase and cost en-ko most of its cards
# (23 expressions proposed, 5 accepted, in a measured run). A span is only
# terminal on a real closing ending, or on 다 followed by sentence punctuation.
_KO_SENTENCE_FINAL_RE = re.compile(
    r"(?:습니다|ㅂ니다|입니다|어요|아요|에요|예요|세요|죠|까|네)[.?!]?$|다[.?!]+$"
)
# A light heuristic, not a name database: catches the common "X그룹/X은행/
# X회사/X증권" organization-suffix pattern the plan's context_entities list
# might have missed, without false-positiving on ordinary short nouns (a
# single, common final syllable like 사 is deliberately excluded — it is
# too generic to signal a name on its own).
_KO_ORG_SUFFIXES = ("그룹", "은행", "회사", "증권")
_KO_CONTEXTUAL_POSSESSIVES = frozenset({"내", "제", "우리", "저희", "네", "너의", "그의", "그녀의"})

_CHOSEONG = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"


def _choseong(ch: str) -> str:
    if "가" <= ch <= "힣":
        return _CHOSEONG[(ord(ch) - 0xAC00) // 588]
    return ch


class KoreanTargetPack(TargetLanguagePack):
    language = "korean"
    coverage = "full"
    script = "hangul"

    word_re = _KOREAN_WORD_RE
    function_words = _KO_FUNCTION_WORDS
    # Korean 어절 pack a lot of meaning per token, so caps are tighter than
    # the Latin targets' word-level caps.
    max_words = {"verb_phrase": 4, "collocation": 3, "domain_term": 3}
    min_single_token_len = 1  # single-syllable Korean words are common and valid
    # A Korean 어절 carries a particle and often a whole predicate, so two of
    # them leave about as much context as three Latin words do.
    min_stem_tokens = 2

    teaching_guide = (
        "Focus on particles (조사), verb/adjective endings and conjugation, "
        "honorific levels (높임법), and word order. Watch Sino-Korean vs native nuance."
    )
    quality_rubric = (
        "자연스러운 현대 한국어를 사용하세요. 원문 언어의 문장 구조를 그대로 옮기지 말고, "
        "무언가를 부여하거나 허용하는 의미라면 'X는 Y이다' 식 계사 문장이 아니라 "
        "'X는 Y에게 ~할 권리를 준다'처럼 자연스러운 서술어로 재구성하세요. "
        "고유명사와 단순 문맥은 학습 정답에 넣지 말고, 재사용 가능한 표현만 정답으로 만드세요."
    )
    plan_prompt_notes = (
        "For Korean verb_phrase and collocation candidates, canonical_form MUST use the "
        "사전형/하다-lemma dictionary form (정리하다, 검토하다; never the inflected 정리했다, "
        "검토했음). surface_form carries the inflected 어미 realization actually used in the "
        "reference answer, including any attached particle needed for the answer to stand "
        "alone (회의를 정리했다, not the particle-stripped 회의 정리했다)."
    )
    author_prompt_notes = (
        "surface_answer must include its attached 조사 whenever the expression is not a bare "
        "동사/형용사 (회의를 정리했다, not just 회의 or 정리했다 with the particle left dangling "
        "in the sentence). Never return an answer that is only a 조사/어미/의존명사. Follow "
        "standard 띄어쓰기 exactly — an extra or missing space changes whether the answer can "
        "be located in sentence_target at all."
    )

    def tokens(self, text: str) -> list[str]:
        return self.word_re.findall(text or "")

    def contains_term(self, text: str, term: str) -> bool:
        """No right boundary: a Korean entity is almost always followed by a
        particle (앤톡에서), and ``\\w`` never fails to match before Hangul, so
        the base pack's ``(?!\\w)`` right-boundary check could never fire on a
        real Korean entity leak."""
        if not term:
            return False
        pattern = re.compile(r"(?<![가-힣])" + re.escape(term))
        return bool(pattern.search(text or ""))

    def answer_boundary_re(self, answer: str) -> re.Pattern[str]:
        return re.compile(
            r"(?<![가-힣A-Za-z0-9])" + re.escape(answer) + r"(?![가-힣A-Za-z0-9])"
        )

    def teachability_reason(self, answer: str) -> str | None:
        base_reason = super().teachability_reason(answer)
        if base_reason:
            return base_reason
        words = self.tokens(answer)
        if len(words) >= 2 and _KO_SUBJECT_EOJEOL_RE.search(words[0]):
            return R.reason(
                R.KO_CLAUSE_ANSWER,
                f"{answer!r} starts with a subject-marked eojeol {words[0]!r}; "
                "looks like a whole clause, not a reusable expression",
            )
        if len(words) >= 3 and _KO_SENTENCE_FINAL_RE.search(words[-1]):
            return R.reason(
                R.KO_CLAUSE_ANSWER,
                f"{answer!r} ends with a sentence-final ending {words[-1]!r}; "
                "looks like a whole clause, not a reusable expression",
            )
        return None

    def base_form_reason(self, canonical: str, kind: str) -> str | None:
        if kind not in {"verb_phrase", "collocation"}:
            return None
        text = (canonical or "").strip()
        if not _KO_DICTIONARY_FORM_RE.search(text):
            return R.reason(
                R.KO_NOT_DICTIONARY_FORM,
                f"{canonical!r} is not a Korean dictionary form; use a -다 lemma "
                "and keep the sentence ending in surface_form",
            )
        if _KO_INFLECTED_PAST_RE.search(text):
            return R.reason(
                R.KO_NOT_DICTIONARY_FORM,
                f"{canonical!r} is an inflected past-tense form; use the 하다-lemma "
                "dictionary form and put the inflection in surface_form instead",
            )
        return None

    def sibling_join_reason(self, canonical: str) -> str | None:
        if _KO_SIBLING_RE.search(canonical or ""):
            return R.reason(
                R.SIBLING_JOIN, f"{canonical!r} joins sibling actions via a Korean coordination marker"
            )
        return None

    def proper_name_reason(self, text: str, kind: str) -> str | None:
        base_reason = super().proper_name_reason(text, kind)
        if base_reason:
            return base_reason
        stripped = (text or "").strip()
        if stripped.endswith(_KO_ORG_SUFFIXES):
            return R.reason(
                R.PROPER_NAME, f"{text!r} ends with a common organization-name suffix"
            )
        return None

    def is_valid_blank(self, text: str) -> bool:
        cleaned = (text or "").strip()
        if not cleaned or "_" in cleaned:
            return False
        return any("가" <= ch <= "힣" for ch in cleaned)

    def surface_boundary_reason(
        self, *, answer: str, sentence_target: str, canonical_form: str
    ) -> str | None:
        words = self.tokens(answer)
        if words and words[0] in _KO_CONTEXTUAL_POSSESSIVES:
            return R.reason(
                R.INTERNAL_POSSESSIVE,
                f"Korean answer {answer!r} starts with contextual possessive {words[0]!r}; keep it outside the blank",
            )
        return None

    def sentence_language_reason(self, sentence: str) -> str | None:
        hangul = re.findall(r"[가-힣]+", sentence or "")
        latin = re.findall(r"[A-Za-z]+", sentence or "")
        if len(hangul) < 2 or len(latin) > max(3, len(hangul)):
            return R.reason(
                R.WRONG_LANGUAGE,
                "Korean target sentence is not predominantly Korean",
            )
        return None

    def normalize_learner_answer(self, text: str) -> str:
        # Korean spacing is genuinely variable; tolerate it the same way the
        # existing grading path (quiz_queue._normalize_answer) already does.
        return re.sub(r"\s+", "", (text or "").strip()).casefold()

    def mask_answer(self, answer: str, level: int) -> str:
        """Reveal 초성 (leading consonants) instead of whole Hangul syllables
        — slicing raw characters (the Latin-pack default) hands over a whole
        syllable, and for a short verb that's often the entire root."""
        text = (answer or "").strip()
        if not text:
            return ""

        def hint_token(token: str, choseong_only: bool) -> str:
            n = len(token)
            if n == 0:
                return ""
            if level <= 30 and not choseong_only:
                reveal = max(1, round(n * 0.3))
                chars = list(token[:reveal]) + [_choseong(c) for c in token[reveal:]]
            else:
                chars = [_choseong(c) for c in token]
            return " ".join(chars)

        tokens = text.split()
        if len(tokens) == 1:
            return hint_token(tokens[0], choseong_only=level > 30)
        if level > 70:
            # Only the first eojeol gets a choseong hint; the rest stay blank.
            parts = [hint_token(tokens[0], choseong_only=True)]
            parts.extend(" ".join("_" for _ in t) for t in tokens[1:])
            return "   ".join(parts)
        return "   ".join(hint_token(t, choseong_only=level > 30) for t in tokens)


class KoreanNativePack(NativeQuizPack):
    language = "korean"
    script_re = re.compile(r"[가-힣]")
    script_label = "Korean"
    generic_filler_re = _GENERIC_KO_CONTEXT_RE

    def meaning_question(self, meaning: str) -> str:
        return f"'{meaning}'라는 뜻에 맞는 표현은 무엇일까요?"

    def default_question(self, quiz_type: str, target_label: str) -> str:
        if quiz_type == "cloze":
            return f"빈칸에 들어갈 {target_label} 단어를 입력하세요."
        if quiz_type == "scramble":
            return f"{target_label} 단어를 올바른 순서로 배열하세요."
        if quiz_type == "mcq_nuance":
            return f"문맥에 맞는 {target_label} 표현을 고르세요."
        return f"{target_label} 문제를 풀어보세요."

    def gloss_scope_reason(self, gloss: str, kind: str) -> str | None:
        """A verb phrase glossed by a bare object is missing its predicate.

        Korean is verb-final, so a gloss that stops at the object particle
        을/를 is an argument still waiting for its verb — "예약을" cannot be
        the meaning of "die Reservierung auf den Nachmittag verschoben". The
        planner's ``kind`` is what makes this safe: a noun-phrase answer such
        as "die beiden Berichte" is legitimately glossed "두 보고서를", and it
        is not a verb_phrase, so it is never touched here.

        Stating the rule in the author prompt alone did not work — a measured
        round left the defect rate flat (4 -> 6) — so it is enforced here.
        """
        if kind != "verb_phrase":
            return None
        cleaned = (gloss or "").strip().rstrip(".,!?…，。")
        if _KO_OBJECT_TAIL_RE.search(cleaned):
            return R.reason(
                R.NATIVE_TARGET_MISALIGNMENT,
                f"gloss {gloss!r} stops at the object particle but the answer is a "
                "verb phrase; extend the gloss through the Korean 서술어",
            )
        if cleaned and not _KO_PREDICATE_TAIL_RE.search(cleaned):
            return R.reason(
                R.NATIVE_TARGET_MISALIGNMENT,
                f"gloss {gloss!r} has no Korean predicate ending but the answer is a "
                "verb phrase; include the full action, not only its noun or stem",
            )
        return None

    def subject_marked(self, native_part: str) -> bool:
        return bool(_KO_SUBJECT_MARK_RE.search((native_part or "").strip()))

    def target_label(self, target_language: str) -> str:
        from .. import quiz_generator

        return quiz_generator._LANG_KO_DISPLAY.get(
            target_language.lower(), target_language.title()
        )

    def contains_span(self, haystack: str, needle: str) -> bool:
        """Space-insensitive containment: Korean spacing is genuinely
        variable, and a single stray space must not fail an otherwise
        correct native-alignment check (``target_ko`` inside ``sentence_ko``)."""
        if not needle:
            return False
        strip = lambda s: re.sub(r"\s+", "", s or "")
        return strip(needle) in strip(haystack)
