"""Gamified quiz generation — one item per type, level-scaled."""

from __future__ import annotations

import json
import random
import re
from functools import lru_cache
from typing import Literal

from openai import AsyncOpenAI

from .config import get_settings
from .level_guidelines import clamp_level, level_prompt_context
from .quiz_audio_engine import build_complete_cloze_sentence
from .quiz_types import validate_quiz_type

QuizSource = Literal["graph", "journal"]

_DEFAULT_QUESTION_KO_TEMPLATE = {
    "cloze": "빈칸에 들어갈 {lang} 단어를 입력하세요.",
    "scramble": "{lang} 단어를 올바른 순서로 배열하세요.",
    "mcq_nuance": "문맥에 맞는 {lang} 표현을 고르세요.",
}

_LANG_KO_DISPLAY = {
    "english": "영어", "german": "독일어", "japanese": "일본어",
    "chinese": "중국어", "spanish": "스페인어", "french": "프랑스어",
    "portuguese": "포르투갈어", "italian": "이탈리아어",
    "arabic": "아랍어", "russian": "러시아어",
}


def _default_question_ko(quiz_type: str, target_language: str = "english") -> str:
    lang_ko = _LANG_KO_DISPLAY.get(target_language.lower(), target_language.title())
    template = _DEFAULT_QUESTION_KO_TEMPLATE.get(quiz_type, "{lang} 문제를 풀어보세요.")
    return template.format(lang=lang_ko)

_PERSONAL_TRIVIA_RE = re.compile(
    r"(어디(를|에)?\s*(방문|갔)|무엇을?\s*했|누가\s|누구|언제\s|왜\s.*했|일기|했나요\?|갔나요\?)",
    re.IGNORECASE,
)

_EN_BLANK_RE = re.compile(r"^[a-zA-Z][a-zA-Z' -]*[a-zA-Z]$|^[a-zA-Z]$")

_MCQ_EN_STOPWORDS = frozenset({
    "about", "after", "also", "been", "being", "both", "from", "have", "into",
    "just", "like", "many", "more", "most", "much", "only", "other", "some",
    "such", "than", "that", "the", "their", "them", "then", "there", "these",
    "they", "this", "those", "very", "what", "when", "where", "which", "while",
    "with", "would", "your",
})

_MCQ_NUANCE_DISTRACTOR_RULES = """\
[MCQ NUANCE — CONTEXT & DISTRACTOR DESIGN (MANDATORY)]
1. DYNAMIC CONTEXT CONSISTENCY (동일 맥락 유지):
   - prompt_ko sets ONE specific topic, situation, or theme (e.g. "컨설팅 업계의 복잡한 관계망에 대해 이야기할 때").
   - ALL four English options MUST stay inside that exact same topic/situation.
   - FORBIDDEN: pulling unrelated graph facts as distractors (e.g. gym workouts, matcha, travel, random people) \
when the theme is corporate networking. Every option must read as an attempt to express THE SAME scenario.

2. TRUE NUANCE-BASED DISTRACTORS — assign each WRONG option a distinct linguistic failure mode \
(the correct_index option is the natural winner; the other three each embody ONE flaw):
   • CORRECT (correct_index): Most natural, idiomatic, level-appropriate English for the prompt_ko theme.
   • AWKWARD/LITERAL distractor: Grammatically fine but stiff, overly literal, or Konglish-style wording \
an American would not naturally say in this context \
(e.g. "The consulting industry's human relationship net is very twisted.").
   • REGISTER distractor: Grammatically correct but wrong tone — too slangy, rude, or casual for the context \
(e.g. "Consulting networking is super messy and crazy.").
   • MEANING-SHIFT distractor: Uses plausible words but subtly misses the core nuance of prompt_ko \
(e.g. "There are many consultants talking to each other in the industry.").

3. Each distractor must be tempting enough that the learner must judge NATURALNESS and NUANCE — not keyword matching.
4. Do NOT label options A/B/C/D in the text. correct_index is 0–3 (position in the options array).
5. Set sentence_en to the exact text of the correct option."""

_MALHEOBOCA_SPAN_RE = re.compile(
    r"<span\s+color=['\"]#FFA500['\"][^>]*>.*?</span>",
    re.IGNORECASE | re.DOTALL,
)

_TYPE_PROMPTS: dict[str, dict[QuizSource, str]] = {
    "cloze": {
        "graph": (
            "Create ONE Malheoboca-style vocabulary cloze quiz from knowledge-graph facts.\n"
            "Rules:\n"
            "- prompt_en: one natural sentence in the TARGET LANGUAGE with exactly ONE blank shown as ___\n"
            "- blank: the missing word or phrase (lowercase, in the target language)\n"
            "- Do NOT output blank_display — the server computes hints from level\n"
            "- accepted_answers: 1–3 valid spellings\n"
            "- sentence_en: the full sentence with the blank filled in\n"
            "- question_ko: SHORT instruction in the NATIVE LANGUAGE for the task\n"
            "- context_ko: REQUIRED — one sentence in the NATIVE LANGUAGE where the phrase matching the "
            "blank is wrapped exactly as <span color='#FFA500'>모국어구</span>\n"
            "- hint_ko: optional brief mnemonic in the NATIVE LANGUAGE\n"
            "- explanation: ONE concise sentence in the NATIVE LANGUAGE about the correct answer "
            "from a TARGET-LANGUAGE-learning perspective. Include language-specific grammar tips "
            "(e.g. German noun gender m/f/n, Japanese reading/kanji, Chinese tone, register). Max 60 words.\n"
            "Freedom OFF: blank MUST be a graph entity node name. "
            "Freedom ON: follow the seed-lock block instead.\n"
            "NEVER ask diary trivia.\n"
            'JSON: {"difficulty_level": int, "question_ko": str, "sentence_en": str, '
            '"quiz_data": {"prompt_en": str, "blank": str, "accepted_answers": [str], '
            '"context_ko": str, "hint_ko": str?, "explanation": str}}'
        ),
        "journal": (
            "Create ONE Malheoboca-style cloze from journal vocabulary/phrases.\n"
            "Test target-language production, NOT diary recall. Same JSON schema as graph cloze. "
            "context_ko MUST use <span color='#FFA500'>...</span> on the native-language target phrase. "
            "Include explanation field with a concise language-specific tip."
        ),
    },
    "scramble": {
        "graph": (
            "Create ONE sentence-unscramble quiz in the TARGET LANGUAGE from knowledge-graph facts.\n"
            "Rules:\n"
            "- sentence_en: the correct full sentence in the target language (4–10 words)\n"
            "- Do NOT output chunks or correct_order — the server tokenizes and shuffles.\n"
            "- question_ko: '단어를 올바른 순서로 배열하세요' (or equivalent in native language) — no diary trivia\n"
            "- explanation: ONE concise sentence in the NATIVE LANGUAGE about the grammar or "
            "structure demonstrated, with any language-specific notes. Max 60 words.\n"
            "Freedom OFF: sentence_en MUST be a literal translation of ONE graph fact only.\n"
            "Freedom ON: weave the mandatory target vocabulary into a natural sentence.\n"
            'JSON: {"difficulty_level": int, "question_ko": str, "sentence_en": str, '
            '"quiz_data": {"sentence_en": str, "explanation": str}}'
        ),
        "journal": (
            "Create ONE scramble quiz from a sentence pattern in the journal. "
            "Focus on target-language word order, not 'what did I do'. "
            "Include explanation field. Same JSON schema."
        ),
    },
    "mcq_nuance": {
        "graph": (
            "Create ONE TARGET LANGUAGE nuance multiple-choice quiz.\n"
            "Step 1 — Choose ONE coherent theme/situation from graph_context for prompt_ko "
            "(e.g. a professional context, relationship dynamic, or concept — NOT diary trivia).\n"
            "Step 2 — Write exactly 4 TARGET LANGUAGE options that ALL describe that SAME theme with "
            "different linguistic quality (see MCQ NUANCE distractor rules above).\n"
            "Fields:\n"
            "- prompt_ko: NATIVE LANGUAGE topic header describing WHEN/WHAT situation the learner is expressing\n"
            "- options: exactly 4 TARGET LANGUAGE sentences — same topic, different nuance/register failures\n"
            "- correct_index: 0–3 pointing to the most natural option\n"
            "- explanation: in the NATIVE LANGUAGE — why the correct choice is most natural "
            "(mention the flaw in distractors); add any target-language-specific note. Max 60 words.\n"
            "- question_ko: '가장 자연스러운 표현을 고르세요' (in native language)\n"
            "- sentence_en: exact text of the correct option (in TARGET LANGUAGE)\n"
            "Freedom OFF: theme must come from graph_context, but ALL four options paraphrase that ONE theme — "
            "never mix in unrelated graph nodes as distractors.\n"
            "Freedom ON: correct option must use the mandatory target vocabulary; distractors stay on-theme "
            "but fail on nuance/register/meaning as defined above.\n"
            'JSON: {"difficulty_level": int, "question_ko": str, "sentence_en": str, '
            '"quiz_data": {"prompt_ko": str, "options": [str,str,str,str], '
            '"correct_index": int, "explanation": str}}'
        ),
        "journal": (
            "Create ONE nuance MCQ from a single theme in the journal text. "
            "ALL four options must stay on that same theme — test TARGET LANGUAGE expression nuance, not diary recall. "
            "Follow the MCQ NUANCE distractor rules above. Include explanation in native language. Same JSON schema."
        ),
    },
}


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


def _hint_single_token(token: str, level: int) -> str:
    word = token.strip().lower()
    if not word:
        return ""
    n = len(word)
    if level <= 30:
        reveal = max(1, round(n * 0.3))
        parts = list(word[:reveal]) + ["_"] * (n - reveal)
    elif level <= 70:
        parts = [word[0]] + ["_"] * (n - 1)
    elif n > 7:
        parts = [word[0]] + ["_"] * (n - 1)
    else:
        parts = ["_"] * n
    return " ".join(parts)


def generate_malheoboca_hint(blank_word: str, current_level: int) -> str:
    """Level-scaled letter hints — supports multi-word phrases."""
    word = blank_word.strip().lower()
    if not word:
        return ""
    level = clamp_level(current_level)
    tokens = word.split()
    if len(tokens) > 1:
        return "   ".join(_hint_single_token(t, level) for t in tokens)
    return _hint_single_token(word, level)


def _tokenize_scramble_sentence(sentence_en: str) -> list[str]:
    """Split a sentence into single-word display tokens (punctuation stays on the word)."""
    return [t for t in re.findall(r"\S+", (sentence_en or "").strip()) if t]


def _prepare_scramble_chunks(
    sentence_en: str,
    *,
    rng: random.Random | None = None,
) -> tuple[list[str], list[int]]:
    """Tokenize into single words, shuffle display order, compute correct_order."""
    tokens = _tokenize_scramble_sentence(sentence_en)
    if len(tokens) < 3:
        raise ValueError("scramble requires at least 3 single-word tokens")
    rng = rng or random.Random()
    display_order = list(range(len(tokens)))
    for _ in range(24):
        rng.shuffle(display_order)
        if display_order != list(range(len(tokens))):
            break
    else:
        display_order = display_order[1:] + display_order[:1]
    chunks = [tokens[i] for i in display_order]
    correct_order = _compute_scramble_order(chunks, sentence_en)
    return chunks, correct_order


def _mcq_content_words(text: str) -> set[str]:
    """Significant English content words for thematic overlap checks."""
    words = {
        w.lower()
        for w in re.findall(r"[a-zA-Z']+", text or "")
        if len(w) >= 4 and w.lower() not in _MCQ_EN_STOPWORDS
    }
    if words:
        return words
    return {w.lower() for w in re.findall(r"[a-zA-Z']+", text or "") if len(w) >= 3}


def _validate_mcq_nuance_coherence(
    options: list,
    correct_index: int,
    *,
    prompt_ko: str = "",
) -> None:
    """Reject distractors that jump to unrelated graph topics."""
    correct = str(options[int(correct_index)]).strip()
    if not correct:
        raise ValueError("mcq_nuance correct option must be non-empty")
    correct_words = _mcq_content_words(correct)
    min_overlap = 1
    for i, opt in enumerate(options):
        if i == int(correct_index):
            continue
        text = str(opt).strip()
        if not text:
            raise ValueError(f"mcq_nuance option {i} must be non-empty")
        overlap = correct_words & _mcq_content_words(text)
        if len(overlap) < min_overlap:
            raise ValueError(
                f"mcq_nuance option {i} is contextually disconnected from the quiz theme "
                f"(prompt: {(prompt_ko or '')[:60]}…); all options must discuss the same "
                f"situation as the correct answer — found overlap {sorted(overlap)!r}, "
                f"need at least {min_overlap} shared content word(s)"
            )


# German separable verb prefixes (e.g. "vornehmen" → vor + nehmen)
_DE_SEP_PREFIXES = (
    "zurück", "durch", "weiter", "über", "unter", "wider", "um",
    "vor", "aus", "auf", "her", "hin", "los", "mit", "nach",
    "ein", "bei", "weg", "an", "ab", "zu", "fort",
)
# Function words that are unreliable seed-match indicators
_SEED_STOPWORDS = frozenset([
    "sich", "etwas", "jemand", "jdn", "etw", "ein", "eine", "einen",
    "einem", "einer", "die", "der", "das", "den", "dem", "des",
    "es", "er", "sie", "wir", "ich", "ihr", "man", "zu", "von",
    "mit", "für", "in", "an", "auf", "aus", "bei", "nach",
    "über", "um", "vor", "durch", "the", "a", "an",
])


def _token_in_hay(tok: str, hay: str) -> bool:
    """Check whether *tok* (lower-case) appears in *hay* with inflection tolerance.

    Handles German separable verbs: 'vornehmen' is split into prefix 'vor'
    and stem 'nehmen', then both must appear anywhere in the sentence.
    """
    # Direct prefix match first (covers inflected forms like vorgenommen → starts with "vornehm")
    stem = tok[:max(4, len(tok) - 2)]
    if re.search(rf"\b{re.escape(stem)}\w*\b", hay):
        return True
    # Try separable verb split: prefix present AND verb-stem present
    for pfx in _DE_SEP_PREFIXES:
        if tok.startswith(pfx) and len(tok) > len(pfx) + 2:
            verb_stem = tok[len(pfx):][:max(3, len(tok[len(pfx):]) - 2)]
            if pfx in hay.split() or re.search(rf"\b{re.escape(pfx)}\b", hay):
                if re.search(rf"\b{re.escape(verb_stem)}\w*\b", hay):
                    return True
    return False


def _sentence_contains_seed(text: str, seed: str) -> bool:
    """True if seed word/phrase appears in text (case-insensitive, word-aware).

    Handles German separable verbs and inflection. For multi-word seeds,
    requires only the CONTENT words (non-function-words > 3 chars) to match,
    and at least half of them must be found.
    """
    hay = (text or "").lower()
    needle = (seed or "").strip().lower()
    if not needle:
        return False
    if " " not in needle:
        return _token_in_hay(needle, hay)
    # Exact phrase (fast path)
    if needle in hay:
        return True
    # Content-word matching: filter out function words, require majority match
    tokens = [t for t in needle.split() if len(t) > 3 and t not in _SEED_STOPWORDS]
    if not tokens:
        # All tokens were function words — fall back to any-token check
        tokens = [t for t in needle.split() if len(t) > 2]
    if not tokens:
        return True
    matched = sum(1 for t in tokens if _token_in_hay(t, hay))
    # Require at least half of content tokens to appear
    return matched >= max(1, len(tokens) // 2)


def _compute_scramble_order(chunks: list[str], sentence_en: str) -> list[int]:
    """Map sentence word order to indices in the shuffled chunks array."""
    sentence_tokens = _tokenize_scramble_sentence(sentence_en)
    if len(sentence_tokens) != len(chunks):
        return list(range(len(chunks)))

    def _norm(token: str) -> str:
        return re.sub(r"[^\w']", "", token.lower())

    used: set[int] = set()
    order: list[int] = []
    for token in sentence_tokens:
        target = _norm(token)
        matched = False
        for ci, chunk in enumerate(chunks):
            if ci in used:
                continue
            if _norm(chunk) == target:
                order.append(ci)
                used.add(ci)
                matched = True
                break
        if not matched:
            return list(range(len(chunks)))
    if len(order) != len(chunks):
        return list(range(len(chunks)))
    return order


def _looks_like_personal_trivia(question_ko: str) -> bool:
    return bool(_PERSONAL_TRIVIA_RE.search(question_ko or ""))


def _normalize_question_ko(question_ko: str, quiz_type: str, target_language: str = "english") -> str:
    q = (question_ko or "").strip()
    if not q or _looks_like_personal_trivia(q):
        return _default_question_ko(quiz_type, target_language)
    return q


def _ensure_malheoboca_span(context_ko: str, *, fallback: str = "") -> str:
    text = (context_ko or "").strip()
    if not text:
        if fallback:
            return f"<span color='#FFA500'>{fallback}</span>"
        raise ValueError(
            "cloze context_ko must wrap the target phrase in "
            "<span color='#FFA500'>...</span>"
        )
    if _MALHEOBOCA_SPAN_RE.search(text):
        return text
    return f"<span color='#FFA500'>{text}</span>"


def _is_english_blank(text: str) -> bool:
    return bool(_EN_BLANK_RE.match(text.strip()))


def _validate_malheoboca_cloze(quiz_data: dict, blank: str, difficulty: int) -> None:
    context_ko = _ensure_malheoboca_span(
        quiz_data.get("context_ko") or "", fallback=blank
    )
    quiz_data["context_ko"] = context_ko
    quiz_data["blank_display"] = generate_malheoboca_hint(blank, difficulty)


def _sync_prompt_en_with_blank(quiz_data: dict, seed: str) -> None:
    """Ensure prompt_en contains ___ for the seed phrase."""
    prompt = (quiz_data.get("prompt_en") or "").strip()
    sentence = (quiz_data.get("sentence_en") or "").strip()
    if not prompt and sentence:
        pattern = re.compile(re.escape(seed), re.IGNORECASE)
        if pattern.search(sentence):
            quiz_data["prompt_en"] = pattern.sub("___", sentence, count=1)
            return
        quiz_data["prompt_en"] = sentence
        return
    if "___" in prompt:
        return
    pattern = re.compile(re.escape(seed), re.IGNORECASE)
    if pattern.search(prompt):
        quiz_data["prompt_en"] = pattern.sub("___", prompt, count=1)
    elif sentence:
        pattern = re.compile(re.escape(seed), re.IGNORECASE)
        if pattern.search(sentence):
            quiz_data["prompt_en"] = pattern.sub("___", sentence, count=1)


def _apply_freedom_seed(
    quiz_data: dict,
    seed_word: str,
    target_level: int,
    *,
    sentence_en: str = "",
) -> None:
    seed = seed_word.strip().lower()
    quiz_data["blank"] = seed
    quiz_data["accepted_answers"] = [seed]
    if sentence_en:
        quiz_data["sentence_en"] = sentence_en
    _sync_prompt_en_with_blank(quiz_data, seed)
    quiz_data["blank_display"] = generate_malheoboca_hint(seed, target_level)
    quiz_data["context_ko"] = _ensure_malheoboca_span(
        quiz_data.get("context_ko") or "", fallback=seed
    )


def _is_valid_blank(text: str, *, target_language: str = "english") -> bool:
    """Accept blanks in any language — Latin-only check only for English."""
    cleaned = text.strip()
    if not cleaned:
        return False
    if target_language.lower() == "english":
        return _is_english_blank(cleaned)
    # For non-English allow any non-whitespace word/phrase
    return bool(cleaned)


def validate_quiz_payload(
    quiz_type: str,
    payload: dict,
    *,
    freedom_seed: str | None = None,
    target_level: int | None = None,
    target_language: str = "english",
) -> dict:
    quiz_type = validate_quiz_type(quiz_type)
    quiz_data = payload.get("quiz_data") or {}
    if not isinstance(quiz_data, dict):
        raise ValueError("quiz_data must be an object")

    difficulty = clamp_level(
        int(target_level if target_level is not None else payload.get("difficulty_level", 10))
    )

    if quiz_type == "cloze":
        blank = (quiz_data.get("blank") or "").strip()
        accepted = quiz_data.get("accepted_answers") or []
        if freedom_seed:
            _apply_freedom_seed(
                quiz_data,
                freedom_seed,
                difficulty,
                sentence_en=(payload.get("sentence_en") or quiz_data.get("sentence_en") or ""),
            )
            blank = quiz_data["blank"]
        else:
            if not blank and accepted:
                blank = str(accepted[0]).strip()
            if not blank or not accepted:
                raise ValueError("cloze requires blank and accepted_answers")
            if not _is_valid_blank(blank, target_language=target_language):
                accepted_valid = [
                    a for a in accepted
                    if _is_valid_blank(str(a).strip(), target_language=target_language)
                ]
                if accepted_valid:
                    blank = str(accepted_valid[0]).strip()
                    quiz_data["blank"] = blank
                else:
                    raise ValueError(f"cloze blank must be a valid {target_language} word or phrase")
            accepted_valid = [
                a for a in accepted
                if _is_valid_blank(str(a).strip(), target_language=target_language)
            ]
            if not accepted_valid:
                raise ValueError(f"cloze accepted_answers must be valid {target_language} words")
            quiz_data["accepted_answers"] = [a.strip().lower() for a in accepted_valid]
            _validate_malheoboca_cloze(quiz_data, blank, difficulty)
            # Ensure prompt_en has ___ even in non-freedom mode.
            prompt_en = (quiz_data.get("prompt_en") or "").strip()
            if not prompt_en or "___" not in prompt_en:
                _sync_prompt_en_with_blank(
                    quiz_data,
                    blank,
                )
        complete = build_complete_cloze_sentence(
            quiz_data,
            blank,
            sentence_en=(payload.get("sentence_en") or quiz_data.get("sentence_en") or ""),
        )
        if complete:
            quiz_data["sentence_en_complete"] = complete
    elif quiz_type == "scramble":
        sentence = (
            quiz_data.get("sentence_en") or payload.get("sentence_en") or ""
        ).strip()
        if not sentence:
            raise ValueError("scramble requires sentence_en")
        if freedom_seed and not _sentence_contains_seed(sentence, freedom_seed):
            raise ValueError(
                f"scramble freedom mode requires target vocabulary '{freedom_seed}' "
                "in sentence_en"
            )
        chunks, correct_order = _prepare_scramble_chunks(sentence)
        quiz_data["chunks"] = chunks
        quiz_data["correct_order"] = correct_order
        quiz_data["sentence_en"] = sentence
    elif quiz_type == "mcq_nuance":
        options = quiz_data.get("options") or []
        idx = quiz_data.get("correct_index")
        if len(options) != 4 or idx is None or not (0 <= int(idx) <= 3):
            raise ValueError("mcq_nuance requires 4 options and valid correct_index")
        prompt_ko = str(quiz_data.get("prompt_ko") or "")
        correct_option = str(options[int(idx)]).strip()
        if freedom_seed and not _sentence_contains_seed(correct_option, freedom_seed):
            raise ValueError(
                f"mcq_nuance freedom mode requires target vocabulary '{freedom_seed}' "
                "in the correct option"
            )
        _validate_mcq_nuance_coherence(options, int(idx), prompt_ko=prompt_ko)
        quiz_data["sentence_en"] = correct_option

    question_ko = _normalize_question_ko(payload.get("question_ko") or "", quiz_type, target_language)
    sentence_en = payload.get("sentence_en") or quiz_data.get("sentence_en") or ""
    if quiz_type == "mcq_nuance" and quiz_data.get("sentence_en"):
        sentence_en = str(quiz_data["sentence_en"])
    if quiz_type == "cloze":
        blank = (quiz_data.get("blank") or "").strip()
        complete = build_complete_cloze_sentence(quiz_data, blank, sentence_en=sentence_en)
        if complete:
            sentence_en = complete
    return {
        "difficulty_level": difficulty,
        "question_ko": question_ko,
        "sentence_en": sentence_en,
        "quiz_data": quiz_data,
    }


def _freedom_seed_prompt(
    quiz_type: str,
    target_seed: str,
    *,
    cefr: str = "",
    target_language: str = "english",
) -> str:
    cefr_note = f" (CEFR {cefr})" if cefr else ""
    lang = _LANG_DISPLAY_NAMES.get(target_language.lower(), target_language.title())
    if quiz_type == "cloze":
        return (
            "[FREEDOM MODE — SEED LOCK]\n"
            f"Your absolute rule is to generate a {lang} sentence where the missing blank is "
            f"exactly '{target_seed}'{cefr_note}.\n"
            f"You MUST wrap the exact Korean translation of '{target_seed}' inside "
            "<span color='#FFA500'>...</span> within the 'context_ko' field. Do not test anything else.\n"
            "Use characters or places from the knowledge graph ONLY as background settings "
            "to weave a highly natural narrative scene — never as the blank itself."
        )
    if quiz_type == "scramble":
        return (
            "[FREEDOM MODE — VOCABULARY WEAVE]\n"
            f"Mandatory target vocabulary/phrase{cefr_note}: '{target_seed}'.\n"
            f"Build sentence_en as a pedagogically rich {lang} sentence that NATURALLY includes "
            f"'{target_seed}' (exact form or natural inflection).\n"
            "Use graph people, places, and relationships ONLY as the narrative setting — "
            "weave them into a creative, level-appropriate scene that teaches the target word.\n"
            "Do NOT output chunks; the server tokenizes sentence_en into single-word tokens."
        )
    if quiz_type == "mcq_nuance":
        return (
            "[FREEDOM MODE — VOCABULARY WEAVE]\n"
            f"Mandatory target vocabulary/phrase{cefr_note}: '{target_seed}'.\n"
            f"The CORRECT {lang} option (correct_index) MUST naturally use '{target_seed}' "
            "(exact form or natural inflection).\n"
            "prompt_ko sets ONE theme; ALL four options must stay on that same theme — "
            "distractors fail on awkward wording, wrong register, or subtle meaning shift, "
            "NOT by switching to unrelated graph topics.\n"
            "Set sentence_en to the text of the correct option."
        )
    return ""


def _statement_expression_prompt(quiz_type: str, expr: dict) -> str:
    """Freedom OFF + statement expression anchor: use the expression as the quiz target."""
    expression = expr.get("expression", "")
    meaning = expr.get("meaning", "")
    example = expr.get("example", "")
    base = (
        "[STATEMENT EXPRESSION MODE — Freedom OFF]\n"
        f"Target expression: '{expression}' (meaning: {meaning})\n"
        f"Reference example: {example or '(none)'}\n\n"
        "Rules:\n"
        "1. This expression is the SOLE learning target for this quiz item.\n"
        "2. Build the quiz sentence using the source Statement context in graph_context.\n"
        "3. The sentence must sound natural and contextually grounded — not invented.\n"
    )
    if quiz_type == "cloze":
        return (
            base
            + f"4. The blank MUST be the exact expression '{expression}' "
            f"(or a natural inflected form).\n"
            "5. context_ko must wrap the Korean equivalent of the expression in "
            "<span color='#FFA500'>...</span>."
        )
    if quiz_type == "scramble":
        return (
            base
            + f"4. sentence_en MUST naturally include '{expression}' "
            "(exact form or natural inflection).\n"
            "5. The sentence should reflect the source Statement context."
        )
    if quiz_type == "mcq_nuance":
        return (
            base
            + f"4. The CORRECT option must naturally use '{expression}'.\n"
            "5. ALL four options must stay on the same theme from the Statement context."
        )
    return base


def _strict_fact_based_prompt(quiz_type: str) -> str:
    base = (
        "[STRICT FACT-BASED RULES for Freedom OFF]\n"
        "1. Use the graph context as background. If a TARGET EXPRESSION is provided, "
        "that expression is the primary quiz target — build the quiz around it.\n"
        "2. Do not invent characters or situations not in the graph_context.\n"
        "3. Do not add arbitrary timeline padding unless present in the graph slice.\n"
    )
    if quiz_type == "cloze":
        return (
            base
            + "4. If no TARGET EXPRESSION is provided, the blank must be a graph entity name.\n"
            "   If a TARGET EXPRESSION is provided, the blank MUST be that expression.\n"
            "5. prompt_en, sentence_en, and context_ko must all describe the SAME situation."
        )
    if quiz_type == "scramble":
        return (
            base
            + "4. sentence_en MUST be a literal English translation of ONE node-edge-node fact "
            "from graph_context — use only graph entity names and stated relations.\n"
            "5. No adjectives, adverbs, or narrative padding not present in the graph slice."
        )
    if quiz_type == "mcq_nuance":
        return (
            base
            + "4. Pick ONE theme/concept from graph_context for prompt_ko. ALL four options must "
            "paraphrase THAT SAME theme with different linguistic quality — NEVER use unrelated "
            "graph nodes (gym, food, travel, other people) as distractors.\n"
            "5. The correct option is the most natural English for the theme; distractors are "
            "on-theme but awkward, wrong-register, or meaning-shifted."
        )
    return base


_LANG_DISPLAY_NAMES: dict[str, str] = {
    "korean": "Korean (한국어)", "english": "English", "german": "German (Deutsch)",
    "japanese": "Japanese (日本語)", "chinese": "Chinese (中文)", "spanish": "Spanish (Español)",
    "french": "French (Français)", "portuguese": "Portuguese (Português)",
    "italian": "Italian (Italiano)", "arabic": "Arabic (عربي)", "russian": "Russian (Русский)",
}

_LANG_GRAMMAR_NOTES: dict[str, str] = {
    "german": (
        "For German nouns: always note grammatical gender as (m), (f), or (n) after the word. "
        "For verbs: note any separable prefix or strong conjugation pattern if relevant."
    ),
    "japanese": (
        "For Japanese words: note the reading (hiragana/katakana) and kanji if applicable. "
        "Note politeness register (casual/polite/formal) where relevant."
    ),
    "chinese": (
        "For Chinese words: note the pinyin and tone marks. "
        "Note measure word (量词) for nouns where relevant."
    ),
    "french": (
        "For French nouns: note gender (m/f). "
        "For verbs: note être/avoir auxiliary and any irregularities."
    ),
    "spanish": (
        "For Spanish nouns: note gender (m/f). "
        "For verbs: note any stem-change or irregular conjugation patterns."
    ),
    "arabic": (
        "For Arabic words: note the root (جذر) if informative. "
        "Note whether the word is formal/standard (MSA) or colloquial."
    ),
    "russian": (
        "For Russian nouns: note grammatical gender (m/f/n) and declension class if unusual. "
        "For verbs: note aspect (imperfective/perfective)."
    ),
}


def _build_system_prompt(
    quiz_type: str,
    target_level: int,
    source: QuizSource,
    *,
    is_freedom_on: bool = False,
    vocab_seed: dict | None = None,
    statement_expression: dict | None = None,
    native_language: str = "korean",
    target_language: str = "english",
) -> str:
    level_ctx = level_prompt_context(target_level)
    type_prompt = _TYPE_PROMPTS[quiz_type][source]

    native_label = _LANG_DISPLAY_NAMES.get(native_language, native_language.title())
    target_label = _LANG_DISPLAY_NAMES.get(target_language, target_language.title())
    grammar_note = _LANG_GRAMMAR_NOTES.get(target_language, "")

    lang_ctx = (
        f"NATIVE LANGUAGE (모국어): {native_label} — use this for question_ko, context_ko, "
        f"hint_ko, explanation, and all Korean-field instructions.\n"
        f"TARGET LANGUAGE (학습 언어): {target_label} — all quiz sentences, blanks, and options "
        f"must be in this language.\n"
        f"EXPLANATION RULE: explanation field must be in {native_label}, concise (max 60 words), "
        f"covering why the answer is correct + one useful {target_label}-specific insight. "
        + (f"{grammar_note}\n" if grammar_note else "\n")
    )

    if source == "graph":
        role = (
            f"You are a {target_label} pedagogy expert. Create drills that teach vocabulary, "
            f"collocations, grammar, and nuance FROM structured knowledge-graph facts. "
            f"The learner practices {target_label} — never answer questions about their private diary."
        )
        rules = (
            f"FORBIDDEN: questions like 'where did X visit', 'what did I do today', "
            f"'who is Y' as the main task. "
            f"ALLOWED: 'fill the {target_label} word', 'pick the natural {target_label} phrase', "
            f"'unscramble this {target_label} sentence' grounded in concepts from the graph."
        )
        if not is_freedom_on:
            rules = (
                f"FORBIDDEN: inventing actions, characters, timelines, or events not present "
                f"in graph_context; diary-trivia questions; any creative embellishment. "
                f"ALLOWED: literal {target_label} translation of ONE explicit node-edge-node fact only."
            )
    else:
        role = (
            f"You create {target_label} learning quizzes from journal text. "
            f"Use the text only as a source of phrases and vocabulary to practice — "
            f"not as trivia about personal events."
        )
        rules = f"Do not ask diary-recall questions. Focus on {target_label} production and comprehension."

    freedom_block = ""
    fact_block = ""
    if is_freedom_on and vocab_seed:
        freedom_block = (
            _freedom_seed_prompt(
                quiz_type,
                vocab_seed["word"],
                cefr=vocab_seed.get("cefr", ""),
                target_language=target_language,
            )
            + "\n"
        )
    elif not is_freedom_on and source == "graph":
        if statement_expression:
            fact_block = _statement_expression_prompt(quiz_type, statement_expression) + "\n"
        else:
            fact_block = _strict_fact_based_prompt(quiz_type) + "\n"

    nuance_block = ""
    if quiz_type == "mcq_nuance":
        nuance_block = _MCQ_NUANCE_DISTRACTOR_RULES + "\n"

    return (
        f"{role} {level_ctx}\n{lang_ctx}{freedom_block}{fact_block}{nuance_block}{type_prompt}\n{rules}\n"
        "Respond with valid JSON only."
    )


def _build_user_content(
    *,
    quiz_type: str,
    target_level: int,
    source: QuizSource,
    graph_context: str,
    translation_en: str,
    transcript_clean_ko: str,
    is_freedom_on: bool = False,
    vocab_seed: dict | None = None,
    target_language: str = "english",
) -> str:
    seed_note = ""
    lang_label_uc = target_language.title() if target_language else "English"
    if is_freedom_on and vocab_seed:
        seed_note = (
            f"\nMandatory target vocabulary (CEFR {vocab_seed.get('cefr', '?')}): "
            f"'{vocab_seed['word']}'\n"
            f"Weave graph people/places as narrative background — the target word must appear "
            f"naturally in the {lang_label_uc} output.\n"
        )
    elif not is_freedom_on and source == "graph":
        if quiz_type == "cloze":
            seed_note = (
                "\nFreedom OFF — FACT CHECK MODE:\n"
                "- Use ONLY facts explicitly present in the graph_context below.\n"
                "- Pick ONE node-edge-node triple and translate it literally into English.\n"
                "- The cloze blank MUST be the English name of a graph entity node from that triple.\n"
                "- Do NOT invent roles, events, or people not listed in the graph.\n"
            )
        elif quiz_type == "scramble":
            seed_note = (
                "\nFreedom OFF — FACT CHECK MODE:\n"
                "- Use ONLY facts explicitly present in the graph_context below.\n"
                "- Pick ONE node-edge-node triple and translate it literally into sentence_en.\n"
                "- Do NOT invent roles, events, or people not listed in the graph.\n"
            )
        elif quiz_type == "mcq_nuance":
            seed_note = (
                "\nFreedom OFF — FACT CHECK MODE:\n"
                "- Pick ONE theme from graph_context for prompt_ko.\n"
                "- ALL four English options must express THAT SAME theme with different nuance failures.\n"
                "- Do NOT use unrelated graph facts (gym, matcha, travel, other people) as distractors.\n"
            )
    lang_label = target_language.title() if target_language else "English"
    if source == "graph":
        return (
            "Knowledge graph (entities, types, relationships — the ONLY allowed facts):\n"
            f"{graph_context or '(empty — output a minimal placeholder using any single node if present)'}\n\n"
            f"Quiz type: {quiz_type}\n"
            f"Target level: {target_level}\n"
            f"Target language: {lang_label}\n"
            f"{seed_note}\n"
            f"All answers and blanks must be in {lang_label}. "
            "When Freedom OFF, every word in the sentence must trace to the graph slice above."
        )
    return (
        f"Journal (English):\n{translation_en}\n\n"
        f"Journal (Korean):\n{transcript_clean_ko or '(none)'}\n\n"
        f"Graph context:\n{graph_context or '(none)'}\n\n"
        f"Quiz type: {quiz_type}\nTarget level: {target_level}{seed_note}"
    )


async def generate_one(
    *,
    translation_en: str,
    transcript_clean_ko: str,
    graph_context: str,
    quiz_type: str,
    target_level: int,
    premium: bool = False,
    source: QuizSource = "graph",
    is_freedom_on: bool = False,
    vocab_seed: dict | None = None,
    statement_expression: dict | None = None,
    native_language: str = "korean",
    target_language: str = "english",
) -> dict:
    """Generate a single gamified quiz item via LLM."""
    quiz_type = validate_quiz_type(quiz_type)
    settings = get_settings()
    client = _client()
    model = settings.openai_premium_model if premium else settings.openai_model
    system = _build_system_prompt(
        quiz_type,
        target_level,
        source,
        is_freedom_on=is_freedom_on,
        vocab_seed=vocab_seed,
        statement_expression=statement_expression,
        native_language=native_language,
        target_language=target_language,
    )
    user_content = _build_user_content(
        quiz_type=quiz_type,
        target_level=target_level,
        source=source,
        graph_context=graph_context,
        translation_en=translation_en,
        transcript_clean_ko=transcript_clean_ko,
        is_freedom_on=is_freedom_on,
        vocab_seed=vocab_seed,
        target_language=target_language,
    )
    freedom_seed = vocab_seed["word"] if is_freedom_on and vocab_seed else None

    resp = await client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ],
        temperature=0.35,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or "{}"
    data = json.loads(raw)
    validated = validate_quiz_payload(
        quiz_type,
        data,
        freedom_seed=freedom_seed,
        target_level=target_level,
        target_language=target_language,
    )
    validated["_model"] = model
    validated["_system_prompt"] = system
    validated["_raw_llm"] = data
    validated["_vocab_seed"] = vocab_seed
    validated["_is_freedom_on"] = is_freedom_on
    return validated


_VOCAB_CONTEXT_CLOZE_PROMPT = """Create ONE IELTS-level English vocabulary cloze quiz from a real dialogue context.

Rules:
- prompt_en: one natural English sentence with exactly ONE blank shown as ___
- blank: the missing ENGLISH phrase (lowercase) — may be multi-word (e.g. "wrap up", "look forward to")
- accepted_answers: 1–3 valid spellings of the full phrase
- sentence_en: full sentence with blank filled
- question_ko: short Korean instruction
- context_ko: one Korean sentence; wrap the target phrase in <span color='#FFA500'>...</span>
- Use the dialogue context — who spoke to whom matters
- The blank MUST be the complete target vocabulary PHRASE (never a token fragment)
- NEVER ask diary trivia

JSON: {"difficulty_level": int, "question_ko": str, "sentence_en": str,
"quiz_data": {"prompt_en": str, "blank": str, "accepted_answers": [str], "context_ko": str, "hint_ko": str?}}
"""


async def generate_vocab_cloze_from_context(
    context,
    *,
    target_level: int,
    freedom_off: bool = True,
) -> dict:
    settings = get_settings()
    model = settings.openai_premium_model if settings.openai_premium_model else settings.openai_model
    client = AsyncOpenAI(api_key=settings.openai_api_key)

    user_content = (
        f"Target vocabulary phrase: {context.vocab_lemma}\n"
        f"Anchor speaker: {context.speaker_name}\n"
        f"Anchor utterance: {context.anchor_text}\n"
        f"Dialogue context (timeline):\n{context.formatted_dialogue}\n\n"
        f"Target level: {target_level}\n"
        f"Freedom OFF: {freedom_off}"
    )
    resp = await client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": _VOCAB_CONTEXT_CLOZE_PROMPT},
            {"role": "user", "content": user_content},
        ],
        temperature=0.35,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or "{}"
    data = json.loads(raw)
    validated = validate_quiz_payload(
        "cloze",
        data,
        freedom_seed=context.vocab_lemma if not freedom_off else None,
        target_level=target_level,
    )
    validated["_model"] = model
    validated["_system_prompt"] = _VOCAB_CONTEXT_CLOZE_PROMPT
    validated["_raw_llm"] = data
    return validated
