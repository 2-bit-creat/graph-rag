"""Statement exploration for composition units and expression-based cloze cards.

A Statement is split into stable native-language composition prompts. Per target
language, one planning call creates reference realizations and extracts canonical
expressions plus their inflected surface forms. A second call creates one cloze
card per expression. Only mechanical payload validation follows; there is no
subjective LLM quality gate or repair loop.
"""

from __future__ import annotations

import json
import hashlib
import logging
import random
import re
import uuid
from functools import lru_cache
from typing import Any

from openai import AsyncOpenAI
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .level_guidelines import cefr_label, get_level_band
from .models import Quiz, User
from .pipeline_trace import PipelineTracer
from .quiz_audio_engine import resolve_quiz_tts_text, synthesize_quiz_audio
from .quiz_generator import (
    _LANG_DISPLAY_NAMES,
    _default_question_ko,
    validate_quiz_payload,
)

logger = logging.getLogger(__name__)

# Bump this whenever the cloze contract changes.  The batch service uses it to
# retry sources that were exhausted by an older, broken prompt/normalizer.
CLOZE_GENERATOR_VERSION = "cloze-contract-v9-entity-boundary"
_BLANK_RUN_RE = re.compile(r"_{2,}")
_ENGLISH_WORD_RE = re.compile(r"[A-Za-z]+(?:['-][A-Za-z]+)*")
_HANGUL_RE = re.compile(r"[가-힣]")
_GENERIC_KO_CONTEXT_RE = re.compile(r"(문맥에\s*맞는|일반적인\s*표현|표현을\s*떠올려)")
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

# Target-language teaching focus, injected into the generation prompt so quizzes
# stress what actually matters in each language. Shared with the composition
# tutor (see tutor.py) so drill coaching and quiz generation stay aligned.
LANG_GUIDES: dict[str, str] = {
    "english": (
        "Focus on collocations, phrasal verbs, article/tense naturalness, and "
        "prepositions. Penalize word-for-word translationese."
    ),
    "german": (
        "Focus on case (Nominativ/Akkusativ/Dativ/Genitiv), V2 and subordinate-"
        "clause word order, separable verbs, and noun gender. Respect Sie/du register."
    ),
    "korean": (
        "Focus on particles (조사), verb/adjective endings and conjugation, "
        "honorific levels (높임법), and word order. Watch Sino-Korean vs native nuance."
    ),
}

# The control contract stays in one language so its schema and invariants do not
# drift between targets.  Native target-language rubrics are added alongside it
# for idiomaticity and language-specific grammar.
LOCALIZED_QUALITY_RULES: dict[str, str] = {
    "english": (
        "Write idiomatic contemporary English. Keep names and surrounding context "
        "outside the learnable answer; the answer must contain only the reusable expression."
    ),
    "german": (
        "Formuliere idiomatisches, modernes Deutsch. Eigennamen und bloßer Kontext "
        "dürfen nie Teil der Lernantwort sein; die Antwort enthält nur den wiederverwendbaren Ausdruck."
    ),
    "korean": (
        "자연스러운 현대 한국어를 사용하세요. 고유명사와 단순 문맥은 학습 정답에 넣지 말고, "
        "재사용 가능한 표현만 정답으로 만드세요."
    ),
}


def lang_guide(language: str) -> str:
    return LANG_GUIDES.get((language or "").lower(), LANG_GUIDES["english"])


def localized_quality_rules(language: str) -> str:
    return LOCALIZED_QUALITY_RULES.get(
        (language or "").lower(), LOCALIZED_QUALITY_RULES["english"]
    )


def _lang_label(language: str) -> str:
    return _LANG_DISPLAY_NAMES.get((language or "").lower(), (language or "").title())


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


class BundleSeedError(ValueError):
    """No usable Statement to build a quiz bundle from (empty graph)."""


async def _pick_seed(
    session: AsyncSession,
    user: User,
    exclude_node_ids: set[str] | None = None,
    seed_node_ids: set[str] | None = None,
) -> dict[str, Any] | None:
    """A random real Statement the learner wrote, long enough to drill.

    ``exclude_node_ids`` keeps recently-used statements out of rotation so the
    queue fills from across the whole diary instead of the same few sentences.
    """
    stmts = await crud.get_all_statement_nodes(session, user.id)
    usable = [s for s in stmts if len((s.get("content_ko") or "").strip()) >= 6]
    if seed_node_ids:
        usable = [s for s in usable if str(s.get("node_id")) in seed_node_ids]
    if not usable:
        return None
    if exclude_node_ids:
        fresh = [s for s in usable if s.get("node_id") not in exclude_node_ids]
        if fresh:
            usable = fresh
    return random.choice(usable)


_BUNDLE_SCHEMA_HINT = """{
  "segments": [{
    "segment_index": 0,
    "context_entities": [{"native": "<proper name in source>", "target_forms": ["<target-language spellings used in references>"]}],
    "reference_answers": [{"text": "<natural TARGET-language realization>", "register": "casual|neutral|formal", "note": "<native-language note>"}],
    "expressions": [{
      "canonical_form": "<dictionary/wordbook form, including important modifiers>",
      "surface_form": "<how it is realized in the reference answer; may be inflected>",
      "surface_segments": ["<one or more target-language spans in sentence order>"],
      "meaning": "<complete native-language meaning preserving intensity, negation, modality and aspect>",
      "meaning_parts": [{"target": "<meaning-bearing part>", "native": "<its native-language contribution>"}],
      "kind": "collocation|verb_phrase|grammar|domain_term|discourse_frame"
    }]
  }]
}"""

_CLOZE_SCHEMA_HINT = """{
  "cloze": [{
    "expression_id": "<supplied id>",
    "canonical_form": "<copy supplied canonical form>",
    "surface_answer": "<natural inflected contiguous answer used in sentence_target>",
    "question_ko": "<short native-language instruction that does not reveal the answer>",
    "sentence_ko": "<complete native-language translation of sentence_target>",
    "target_ko": "<matching native-language surface span when available>",
    "sentence_target": "<complete TARGET-language sentence containing surface_answer exactly once; no underscores>"
  }]
}"""

_PLAN_RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {
        "name": "statement_expression_plan",
        "strict": True,
        "schema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["segments"],
            "properties": {
                "segments": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": [
                            "segment_index", "context_entities",
                            "reference_answers", "expressions",
                        ],
                        "properties": {
                            "segment_index": {"type": "integer"},
                            "context_entities": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "additionalProperties": False,
                                    "required": ["native", "target_forms"],
                                    "properties": {
                                        "native": {"type": "string"},
                                        "target_forms": {
                                            "type": "array",
                                            "items": {"type": "string"},
                                        },
                                    },
                                },
                            },
                            "reference_answers": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "additionalProperties": False,
                                    "required": ["text", "register", "note"],
                                    "properties": {
                                        "text": {"type": "string"},
                                        "register": {
                                            "type": "string",
                                            "enum": ["casual", "neutral", "formal"],
                                        },
                                        "note": {"type": "string"},
                                    },
                                },
                            },
                            "expressions": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "additionalProperties": False,
                                    "required": [
                                        "canonical_form", "surface_form",
                                        "surface_segments", "meaning",
                                        "meaning_parts", "kind",
                                    ],
                                    "properties": {
                                        "canonical_form": {"type": "string"},
                                        "surface_form": {"type": "string"},
                                        "surface_segments": {
                                            "type": "array",
                                            "items": {"type": "string"},
                                        },
                                        "meaning": {"type": "string"},
                                        "meaning_parts": {
                                            "type": "array",
                                            "items": {
                                                "type": "object",
                                                "additionalProperties": False,
                                                "required": ["target", "native"],
                                                "properties": {
                                                    "target": {"type": "string"},
                                                    "native": {"type": "string"},
                                                },
                                            },
                                        },
                                        "kind": {
                                            "type": "string",
                                            "enum": [
                                                "collocation", "verb_phrase", "grammar",
                                                "domain_term", "discourse_frame",
                                            ],
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
}

_CLOZE_RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {
        "name": "expression_cloze_cards",
        "strict": True,
        "schema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["cloze"],
            "properties": {
                "cloze": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": [
                            "expression_id", "canonical_form", "surface_answer",
                            "question_ko", "sentence_ko", "target_ko", "sentence_target",
                        ],
                        "properties": {
                            "expression_id": {"type": "string"},
                            "canonical_form": {"type": "string"},
                            "surface_answer": {"type": "string"},
                            "question_ko": {"type": "string"},
                            "sentence_ko": {"type": "string"},
                            "target_ko": {"type": "string"},
                            "sentence_target": {"type": "string"},
                        },
                    },
                },
            },
        },
    },
}


def _split_statement_units(text: str) -> list[str]:
    """Split a Statement into stable composition prompts without inventing text."""
    cleaned = re.sub(r"[ \t]+", " ", (text or "").strip())
    if not cleaned:
        return []
    units = [
        part.strip()
        for part in re.split(r"(?<=[.!?。！？])\s+|[\r\n]+", cleaned)
        if part.strip()
    ]
    return units or [cleaned]


def _has_explicit_detail_comparison(text: str) -> bool:
    """Return whether Korean source explicitly licenses 'more/closer'."""
    return bool(re.search(r"(?:더|더욱|한층|좀\s*더|이전보다|전보다)\s*(?:자세|상세)", text))


def _source_semantic_guardrails(text: str, language: str) -> list[str]:
    guards = [
        "Do not add comparison, intensity, negation, modality, repetition, or certainty that is absent from source_text."
    ]
    if language == "english" and re.search(r"자세(?:히|하게)", text):
        if _has_explicit_detail_comparison(text):
            guards.append(
                "The source explicitly says 더 자세히: preserve the comparative meaning with 'more closely' or 'a closer look'."
            )
        else:
            guards.append(
                "The source says 자세히, NOT 더 자세히. Use 'closely' or 'a close look'; NEVER use 'closer' or 'more closely'."
            )
    return guards


def _normalize_unlicensed_detail_comparatives(
    raw_segments: list[Any], source_units: list[str], language: str
) -> list[dict[str, Any]]:
    """Narrow source-fidelity normalization, not a subjective quality judge."""
    changes: list[dict[str, Any]] = []
    if language != "english":
        return changes
    for segment in raw_segments:
        if not isinstance(segment, dict):
            continue
        index = segment.get("segment_index")
        if not isinstance(index, int) or not 0 <= index < len(source_units):
            continue
        source = source_units[index]
        if not re.search(r"자세(?:히|하게)", source) or _has_explicit_detail_comparison(source):
            continue

        def normalize_target(value: Any) -> Any:
            if not isinstance(value, str):
                return value
            normalized = re.sub(
                r"\bmore\s+closely\b", "closely",
                re.sub(r"\ba\s+closer\s+look\b", "a close look", value, flags=re.I),
                flags=re.I,
            )
            return re.sub(r"\bcloser\b", "close", normalized, flags=re.I)

        changed = False
        for answer in segment.get("reference_answers") or []:
            if isinstance(answer, dict):
                before = answer.get("text")
                answer["text"] = normalize_target(before)
                changed = changed or answer["text"] != before
        for expression in segment.get("expressions") or []:
            if not isinstance(expression, dict):
                continue
            for key in ("canonical_form", "surface_form"):
                before = expression.get(key)
                expression[key] = normalize_target(before)
                changed = changed or expression[key] != before
            expression["surface_segments"] = [
                normalize_target(value)
                for value in (expression.get("surface_segments") or [])
            ]
            meaning = expression.get("meaning")
            if isinstance(meaning, str):
                expression["meaning"] = meaning.replace("더 자세히", "자세히")
            for part in expression.get("meaning_parts") or []:
                if isinstance(part, dict):
                    part["target"] = normalize_target(part.get("target"))
                    native = part.get("native")
                    if isinstance(native, str):
                        part["native"] = native.replace("더 자세히", "자세히")
        if changed:
            changes.append({
                "segment_index": index,
                "reason": "source has 자세히 without explicit 더; removed unlicensed English comparative",
            })
    return changes


def _build_system_prompt(native_label: str, target_label: str, level: int, guide: str) -> str:
    band = get_level_band(level)
    return (
        "You are an expert language-quiz author. From a single sentence the learner "
        "wrote in their diary (NATIVE language), produce a BUNDLE of practice quizzes "
        f"in the TARGET language. NATIVE language: {native_label}. TARGET language: "
        f"{target_label}. Learner level: {level}/100 (CEFR {band.cefr}); vocabulary "
        f"scope: {band.vocabulary}; grammar scope: {band.grammar}. Keep every target-"
        "language sentence within this level — comprehensible, never showing off. "
        f"TARGET-LANGUAGE TEACHING FOCUS: {guide} "
        "Produce one natural 'composition' (translate the native sentence) and "
        "First extract 1-3 distinct useful expression_chunks from the composition answer, then create exactly one cloze item for each chunk. "
        "Every cloze.expression and cloze.blank MUST exactly equal its expression_chunks.text. "
        "Never extract or blank proper names: people, organizations, brands, products, events, locations, dates, IDs, acronyms, or capitalized names. "
        "Do not create scramble or multiple-choice items in this endpoint. "
        "For EVERY cloze item, sentence_en MUST be a complete TARGET-language "
        "sentence with blank filled in exactly once. NEVER put underscores or a blank "
        "marker in sentence_en; the server creates the blanked sentence itself. Never "
        "put the native-language source sentence in sentence_en. sentence_ko is "
        "mandatory, must contain NO underscores, and must translate the "
        "entire English sentence naturally. target_ko is mandatory and must occur "
        "verbatim inside sentence_ko: it is the exact native-language counterpart of "
        "blank, written in Korean when the native language is Korean; NEVER copy an "
        "English or German answer into target_ko. Copy the exact inflected Korean surface "
        "phrase from sentence_ko (for example 정리했다, not the lemma 정리하다). "
        "blank MUST be copied verbatim from sentence_en, including the exact "
        "inflected surface form (for German use 'sorgfältig verglichen' when the sentence "
        "contains verglichen, never the dictionary form 'sorgfältig vergleichen'). "
        "If a useful collocation is discontinuous in a draft, rewrite the complete sentence "
        "naturally so it is contiguous (English example: 'I carefully compared the reports' "
        "with blank 'carefully compared'). "
        "Choose only expressions worth actively learning: collocations, phrasal "
        "verbs, natural predicates, or meaningful domain terms. Do not choose numbers, "
        "articles, auxiliaries, isolated prefixes, or trivial words. Do not use a "
        "generic object noun phrase merely because it is easy to blank. When the source "
        "contains a useful action, prefer its verb collocation or predicate. An English "
        "blank must never begin with an article or determiner. Do not use a "
        "generic situation/explanation in place of sentence_ko. "
        "For mcq, all "
        "four options must express the SAME situation set by 'prompt_ko'; exactly one is "
        "the most natural, the other three each carry one plausible flaw. "
        "Native-language fields (prompt, notes, prompt_ko, explanation, hints.note, "
        "glossary.term) MUST be in the native language; target-language fields "
        "(sentence_target, blank, options, model_answers.text, key_expressions.expression, "
        "hints.snippet) MUST be in the target language. "
        f"Respond ONLY with JSON of this exact shape: {_BUNDLE_SCHEMA_HINT}"
    )


def _build_plan_system_prompt(
    native_label: str,
    target_label: str,
    level: int,
    guide: str,
    language: str = "english",
) -> str:
    band = get_level_band(level)
    return (
        "You are an expert language-learning content planner. The server has already split one native-language Statement "
        f"into stable composition units. For EVERY supplied unit, produce natural reference realizations in {target_label} "
        "and extract useful expressions from those realizations. "
        f"Native language: {native_label}. Learner level: {level}/100 (CEFR {band.cefr}). "
        f"Vocabulary scope: {band.vocabulary}. Grammar scope: {band.grammar}. Teaching focus: {guide} "
        f"Target-language quality rubric: {localized_quality_rules(language)} "
        "Return one result for every segment_index and 1-3 expressions per segment. Never merge, drop, reorder, or rewrite source units. "
        "Separate canonical_form (the reusable wordbook form) from surface_form (the naturally inflected realization). They are allowed and "
        "often expected to differ because of tense, person, case, word order, separable verbs, or grammar. surface_segments may contain "
        "multiple spans for discontinuous expressions. Never add a meaning-bearing modifier that the source does not contain. "
        "In particular, Korean '자세히' maps to English 'closely' or 'a close look', while only explicit '더 자세히' maps to "
        "'more closely' or 'a closer look'. Do not upgrade the former into the latter. Explicitly account for comparison/intensity, "
        "negation, modality, aspect, direction, particles and required prepositions in meaning_parts. "
        "Prefer collocations, verb phrases, grammar patterns, reusable opinion/discourse frames (for example 'könnte man so sehen'), "
        "and useful domain terms. When the source describes a concrete action, extract that action itself; never replace it with a vague phrase "
        "about doing/checking a task (Arbeit/Aufgabe/Sache/work/task). The chunk meaning must directly match the native source meaning. "
        "First list EVERY proper name in context_entities, including its native spelling and every target-language spelling used in a "
        "reference answer. Then exclude all such entities and identifying terms from canonical_form, surface_form, surface_segments, "
        "and meaning_parts. This includes people, companies, brands, products, events, locations, dates, IDs, acronyms, and report or "
        "organization names. A common noun modified by a name must lose the name: source '앤톡 웹페이지에서' may teach 'on the webpage' "
        "or 'auf der Webseite', but NEVER 'at the Antock webpage' or 'auf der Webseite von Entok'. "
        "Do not create native-language questions, cloze, scramble, or multiple-choice content in this planning step. "
        "Native-language fields must use the native language and target-language fields must use the target language. "
        f"Respond only with JSON of this exact shape: {_BUNDLE_SCHEMA_HINT}"
    )


def _build_cloze_system_prompt(
    native_label: str, target_label: str, level: int, guide: str, language: str = "english"
) -> str:
    return (
        "You create exactly one context-grounded cloze card for each supplied expression. "
        f"Native language: {native_label}. Target language: {target_label}. Learner level: {level}/100. "
        f"Teaching focus: {guide} Target-language quality rubric: {localized_quality_rules(language)} "
        "Use the supplied source segment, reference answer, canonical form, surface form, meaning parts and grammar. Do not weaken or omit "
        "meaning-bearing modifiers such as closer/more, again, still, barely, might, must or not, and never add one absent from the source. "
        "Korean '자세히' does not license English 'closer/more closely'; those require explicit '더 자세히'. canonical_form is a wordbook identity, "
        "NOT a literal substring requirement. Choose surface_answer as a natural inflected form for this sentence, but inflection may "
        "change grammar only: it must NEVER add a name, organization, event, place, date, product, or contextual noun that is not part of "
        "the reusable expression. Every supplied excluded entity is forbidden in surface_answer. Keep it outside the blank or omit it from "
        "this vocabulary example. For example, use surface_answer 'on the webpage' / 'auf der Webseite', never 'at the Antock webpage' / "
        "'auf der Webseite von Entok'. The complete target_ko must cover the WHOLE surface_answer; if target_ko is only '웹페이지에서', "
        "surface_answer cannot contain 'Antock'. For a discontinuous or "
        "separable expression, write a new natural sentence where one useful realization is contiguous; never force the canonical form into "
        "an ungrammatical position. sentence_target must contain surface_answer exactly once and no underscores. "
        "sentence_ko must be its complete natural native-language translation and contain no underscores. "
        "target_ko should identify the matching inflected native-language span when one is available. "
        "The instruction must not reveal the answer. "
        f"Respond only with JSON of this exact shape: {_CLOZE_SCHEMA_HINT}"
    )


def _compose_quiz_data(comp: dict, language: str, level: int) -> dict:
    """Mirror composition_quiz.generate_composition_quiz's quiz_data shape so the
    same submit/evaluate path grades bundle-generated composition items."""
    model_answers = []
    for a in comp.get("model_answers") or []:
        if isinstance(a, dict) and (a.get("text") or "").strip():
            model_answers.append({
                "text": str(a.get("text")).strip(),
                "tone": str(a.get("register") or a.get("tone") or "neutral").strip(),
                "note": str(a.get("note") or "").strip(),
            })

    def _clean(items, keys):
        out = []
        for it in items or []:
            if isinstance(it, dict):
                cleaned = {k: str(it.get(k) or "").strip() for k in keys}
                if any(cleaned.values()):
                    out.append(cleaned)
        return out

    hints = []
    for h in comp.get("hints") or []:
        if isinstance(h, dict) and str(h.get("note") or "").strip():
            hints.append({
                "note": str(h.get("note")).strip(),
                "snippet": str(h.get("snippet") or "").strip(),
            })

    return {
        "language": language,
        "source_mode": "journal",
        "source_label": str(comp.get("source_label") or "내 기록에서").strip(),
        "target_expressions": [
            str(t).strip() for t in (comp.get("target_expressions") or []) if str(t).strip()
        ][:5],
        "glossary": _clean(comp.get("glossary"), ("term", "target"))[:6],
        "hints": hints[:3],
        "model_answers": model_answers[:2],
        "key_expressions": _clean(
            comp.get("key_expressions"), ("expression", "meaning", "example")
        )[:6],
        "thinking_tip": str(comp.get("thinking_tip") or "").strip(),
        "cefr": cefr_label(level),
        "difficulty": "normal",
        "style": {},
    }


def _normalize_bundle_cloze(
    item: dict,
    *,
    language: str,
) -> tuple[str, str, str, str] | None:
    """Return ``(full_sentence, prompt, blank, context_ko)`` for a safe cloze.

    Old traces used ``sentence_target`` and several model responses used a run
    of six underscores.  Accept those legacy shapes once, but refuse a Korean
    source sentence paired with an English answer instead of creating an
    unanswerable word quiz.
    """
    blank = str(item.get("surface_answer") or item.get("blank") or "").strip()
    full_sentence = str(item.get("sentence_en") or item.get("sentence_target") or "").strip()
    if not blank or not full_sentence:
        return None

    # Normalise one model placeholder run (___, ______, etc.) atomically.  A
    # partial replacement of "______" previously left trailing underscores in
    # sentence_en and caused downstream validation/storage failures.
    if len(_BLANK_RUN_RE.findall(full_sentence)) > 1:
        return None
    if _BLANK_RUN_RE.search(full_sentence):
        full_sentence = _BLANK_RUN_RE.sub(blank, full_sentence, count=1)

    # Never trust the model's prompt separately. Build it from the completed
    # sentence, so ``___ eight`` and other answer-leaking variants cannot ship.
    matcher = re.compile(
        r"(?<![A-Za-z0-9])" + re.escape(blank) + r"(?![A-Za-z0-9])",
        re.IGNORECASE,
    )
    if "_" in full_sentence or len(list(matcher.finditer(full_sentence))) != 1:
        return None
    prompt = matcher.sub("___", full_sentence, count=1)
    if language == "english" and len(_ENGLISH_WORD_RE.findall(full_sentence)) < 3:
        return None

    sentence_ko = str(item.get("sentence_ko") or "").strip()
    target_ko = str(item.get("target_ko") or "").strip()
    if not sentence_ko:
        return None
    if target_ko and _HANGUL_RE.search(sentence_ko) and not _HANGUL_RE.search(target_ko):
        return None
    # Some models incorrectly blank the native translation too. Unlike guessing
    # a translation, restoring the explicitly supplied target_ko into one marker
    # is deterministic and preserves the complete native meaning shown in the UI.
    native_markers = _BLANK_RUN_RE.findall(sentence_ko)
    if len(native_markers) > 1:
        return None
    if native_markers:
        sentence_ko = _BLANK_RUN_RE.sub(target_ko, sentence_ko, count=1)
    if "_" in sentence_ko:
        return None
    if _GENERIC_KO_CONTEXT_RE.search(sentence_ko):
        return None
    if not target_ko or target_ko not in sentence_ko:
        return None
    context_ko = sentence_ko.replace(
        target_ko, f"<span color='#FFA500'>{target_ko}</span>", 1
    )
    return full_sentence, prompt, blank, context_ko


def _is_teachable_cloze(blank: str, *, language: str) -> bool:
    """Reject answers that cannot justify a production-learning card."""
    normalized = blank.strip().casefold()
    if not normalized:
        return False
    if language == "english":
        if normalized in _TRIVIAL_ENGLISH_CLOZES or normalized.isdigit():
            return False
        words = _ENGLISH_WORD_RE.findall(normalized)
        if not words or " ".join(words).casefold() != normalized:
            return False
        if words[0].casefold() in _ENGLISH_LEADING_DETERMINERS:
            return False
        # Bare one/two-letter fragments (for example ``sub`` from ``sub-model``)
        # are not a useful expression even when grammatically valid.
        if len(words) == 1 and len(words[0]) < 4:
            return False
    return True


def _expression_key(value: str) -> str:
    """Canonical expression identity shared by extraction, QA, and persistence."""
    return " ".join(re.findall(r"[\w'-]+", value.casefold()))


def _segment_entity_terms(segment: dict[str, Any]) -> tuple[list[str], list[str]]:
    """Return native and target spellings that may provide context, never answers."""
    native: list[str] = []
    target: list[str] = []
    for entity in segment.get("context_entities") or []:
        if not isinstance(entity, dict):
            continue
        native_value = str(entity.get("native") or "").strip()
        if native_value:
            native.append(native_value)
        for value in entity.get("target_forms") or []:
            value = str(value or "").strip()
            if value:
                target.append(value)
    return native, target


def _contains_term(text: str, terms: list[str]) -> str | None:
    """Return the matched entity spelling using word-aware, case-insensitive bounds."""
    for term in sorted(set(terms), key=len, reverse=True):
        pattern = re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)
        if pattern.search(text or ""):
            return term
    return None


def _same_lexeme(left: str, right: str) -> bool:
    """Conservative inflection match used only for capitalisation fallback checks."""
    left = left.casefold()
    right = right.casefold()
    if left == right:
        return True
    return len(left) >= 4 and len(right) >= 4 and left[:4] == right[:4]


def _surface_answer_contract_reason(
    *,
    answer: str,
    sentence_target: str,
    canonical_form: str,
    excluded_target_terms: list[str],
    language: str,
) -> str | None:
    """Reject context/entity expansion while still allowing grammatical inflection.

    This is a mechanical boundary, not subjective LLM QA. Explicit entity forms
    come from the planning payload; capitalization is a fallback for a missed
    entity such as ``Antock``/``Entok``.
    """
    matched = _contains_term(answer, excluded_target_terms)
    if matched:
        return f"surface_answer contains excluded context entity {matched!r}"

    if language not in {"english", "german"}:
        return None
    answer_words = _ENGLISH_WORD_RE.findall(answer)
    canonical_words = _ENGLISH_WORD_RE.findall(canonical_form)
    if not answer_words:
        return None
    answer_at_sentence_start = sentence_target.lstrip().casefold().startswith(
        answer.casefold()
    )
    for index, word in enumerate(answer_words):
        if not word[:1].isupper() or word.casefold() == "i":
            continue
        if index == 0 and answer_at_sentence_start and canonical_words:
            if _same_lexeme(word, canonical_words[0]):
                continue
        if language == "german" and any(
            _same_lexeme(word, canonical_word) for canonical_word in canonical_words
        ):
            continue
        # English words inside a reusable answer are not title-cased. German
        # common nouns are, but a new capitalised token absent from the canonical
        # expression is contextual content and must stay outside the blank.
        return f"surface_answer adds entity-like token {word!r} outside canonical_form"
    return None


def _usable_expression_chunks(raw_chunks: Any, *, language: str) -> set[str]:
    """Keep learnable chunks only; proper names never become quiz answers.

    The model is asked for lowercase chunks, but this server-side rule makes the
    exclusion deterministic even when a model ignores that instruction.
    """
    chunks: set[str] = set()
    language = (language or "").lower()
    for item in raw_chunks or []:
        text = str(
            (item.get("canonical_form") or item.get("text"))
            if isinstance(item, dict)
            else item
        ).strip()
        kind = str(item.get("kind") if isinstance(item, dict) else "").strip().lower()
        key = _expression_key(text)
        if not key or any(ch.isdigit() for ch in text) or "@" in text or "://" in text:
            continue
        if kind in {"proper_name", "person", "organization", "brand", "location", "event"}:
            continue
        if re.search(r"\b[A-ZÄÖÜ]{2,}\b", text):
            continue
        words = re.findall(r"[A-Za-zÄÖÜäöüß]+", text)
        # A dictionary-form English expression may accidentally retain sentence-
        # initial capitalization, but an internal title-cased token is a name.
        if language == "english" and any(word[:1].isupper() for word in words[1:]):
            continue
        # German common nouns are capitalized by rule. Only reject a phrase
        # made entirely of title-cased tokens, a strong multi-word name signal.
        if language == "german" and len(words) > 1 and all(word[:1].isupper() for word in words):
            continue
        chunks.add(key)
    return chunks


def _cloze_structural_reason(item: Any, raw_index: int) -> str:
    """Give the repair model a field-specific reason instead of a generic failure."""
    if not isinstance(item, dict):
        return f"candidate {raw_index}: item must be a JSON object"
    blank = str(item.get("surface_answer") or item.get("blank") or "").strip()
    full_sentence = str(
        item.get("sentence_en") or item.get("sentence_target") or ""
    ).strip()
    if not blank or not full_sentence:
        return f"candidate {raw_index}: blank and sentence_en are both required"
    completed = full_sentence
    markers = _BLANK_RUN_RE.findall(completed)
    if len(markers) == 1:
        completed = _BLANK_RUN_RE.sub(blank, completed, count=1)
    matcher = re.compile(
        r"(?<![A-Za-z0-9])" + re.escape(blank) + r"(?![A-Za-z0-9])",
        re.IGNORECASE,
    )
    if "_" in completed or len(list(matcher.finditer(completed))) != 1:
        return (
            f"candidate {raw_index}: blank {blank!r} must be copied verbatim as one "
            "contiguous, inflected surface substring of sentence_en; rewrite sentence_en "
            "if necessary and do not return a dictionary form"
        )
    sentence_ko = str(item.get("sentence_ko") or "").strip()
    target_ko = str(item.get("target_ko") or "").strip()
    native_completed = sentence_ko
    native_markers = _BLANK_RUN_RE.findall(native_completed)
    if len(native_markers) == 1:
        native_completed = _BLANK_RUN_RE.sub(target_ko, native_completed, count=1)
    if _HANGUL_RE.search(sentence_ko) and not _HANGUL_RE.search(target_ko):
        return (
            f"candidate {raw_index}: target_ko {target_ko!r} is target-language text; "
            "target_ko must be Korean copied verbatim from sentence_ko"
        )
    if not target_ko or target_ko not in native_completed:
        return (
            f"candidate {raw_index}: target_ko {target_ko!r} must be the exact inflected "
            "Korean surface phrase copied verbatim from sentence_ko (not a lemma)"
        )
    return (
        f"candidate {raw_index}: sentence_en and sentence_ko must be complete natural "
        "sentences with exactly one answer/translation alignment"
    )


def _prepare_cloze_candidates(
    items: list[Any],
    *,
    language: str,
    level: int,
    source_meta: dict[str, Any],
    expression_contracts: dict[str, dict[str, Any]] | None = None,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Apply every deterministic guard and return actionable rejection reasons."""
    candidates: list[dict[str, Any]] = []
    reasons: list[str] = []
    seen_blanks: set[str] = set()
    for raw_index, item in enumerate(items[:6]):
        if not isinstance(item, dict):
            reasons.append(f"candidate {raw_index}: item is not an object")
            continue
        normalized = _normalize_bundle_cloze(item, language=language)
        if normalized is None:
            reasons.append(_cloze_structural_reason(item, raw_index))
            continue
        sentence_full, prompt_en, blank, context_ko = normalized
        expression_id = str(item.get("expression_id") or "").strip()
        contract = (expression_contracts or {}).get(expression_id, {})
        canonical_form = str(
            contract.get("canonical_form")
            or item.get("canonical_form")
            or item.get("expression")
            or blank
        ).strip()
        scope_reason = _surface_answer_contract_reason(
            answer=blank,
            sentence_target=sentence_full,
            canonical_form=canonical_form,
            excluded_target_terms=list(contract.get("excluded_target_terms") or []),
            language=language,
        )
        if scope_reason:
            reasons.append(f"candidate {raw_index}: {scope_reason}")
            continue
        blank_key = blank.casefold()
        if blank_key in seen_blanks:
            reasons.append(f"candidate {raw_index}: duplicate answer {blank!r}")
            continue
        seen_blanks.add(blank_key)
        question_ko = str(
            item.get("question_ko") or _default_question_ko("cloze", language)
        ).strip()
        try:
            validated = validate_quiz_payload(
                "cloze",
                {
                    "question_ko": question_ko,
                    "sentence_en": sentence_full,
                    "quiz_data": {
                        "prompt_en": prompt_en,
                        "blank": blank,
                        "accepted_answers": [blank],
                        "sentence_en": sentence_full,
                        "context_ko": context_ko,
                        "hint_ko": str(item.get("hint_ko") or "").strip(),
                    },
                },
                target_level=level,
                target_language=language,
            )
        except ValueError as exc:
            reasons.append(f"candidate {raw_index}: {exc}")
            continue
        qd = dict(validated["quiz_data"])
        qd["language"] = language
        qd["target_ko"] = str(item.get("target_ko") or "").strip()
        qd["sentence_ko"] = str(item.get("sentence_ko") or "").strip()
        qd["_source"] = dict(source_meta)
        candidates.append({
            "blank": blank,
            "expression_id": expression_id,
            "expression": canonical_form,
            "question_ko": question_ko,
            "sentence_en": sentence_full,
            "prompt_en": prompt_en,
            "context_ko": context_ko,
            "spec": {
                "quiz_type": "cloze",
                "question_ko": validated["question_ko"],
                "sentence_en": validated["sentence_en"],
                "quiz_data": qd,
            },
        })
    return candidates, reasons


async def generate_quiz_bundle(
    session: AsyncSession,
    user: User,
    *,
    language: str,
    exclude_node_ids: set[str] | None = None,
    seed_node_ids: set[str] | None = None,
) -> tuple[list[Quiz], dict]:
    """Generate composition units and expression clozes from one Statement.

    Returns (created_quizzes, trace). Raises :class:`BundleSeedError` when the
    learner has no usable Statement yet.
    """
    settings = get_settings()
    language = (language or "english").lower()
    native_language = (getattr(user, "native_language", None) or "korean").lower()
    native_label = _lang_label(native_language)
    target_label = _lang_label(language)
    level = crud.get_language_level(user, language)

    seed = await _pick_seed(session, user, exclude_node_ids, seed_node_ids)
    if seed is None:
        raise BundleSeedError("퀴즈를 만들 문장이 없어요. 먼저 일기를 작성해 주세요.")
    seed_node_id = seed.get("node_id")
    seed_nodes = None
    try:
        seed_nodes = [uuid.UUID(str(seed_node_id))]
    except (TypeError, ValueError):
        seed_nodes = None

    bundle_id = uuid.uuid4()
    tracer = PipelineTracer(bundle_id)
    tracer.run.current_phase = "quiz_path"
    tracer.run.status = "quiz_path"

    step = tracer.begin_step(
        "bundle_seed_select", "graph", phase="quiz_path",
        input_data={"language": language, "exclude_count": len(exclude_node_ids or [])},
    )
    tracer.finish_step(step, output={"seed_node_id": seed_node_id, "content": seed.get("content_ko")})

    source_units = _split_statement_units(str(seed.get("content_ko") or ""))
    if not source_units:
        raise BundleSeedError("퀴즈를 만들 수 있는 문장이 없어요.")
    system = _build_plan_system_prompt(
        native_label, target_label, level, lang_guide(language), language
    )
    user_content = json.dumps(
        {
            "source_statement": str(seed.get("content_ko") or ""),
            "composition_units": [
                {
                    "segment_index": index,
                    "source_text": text,
                    "semantic_guardrails": _source_semantic_guardrails(text, language),
                }
                for index, text in enumerate(source_units)
            ],
        },
        ensure_ascii=False,
    )
    step = tracer.begin_step(
        "bundle_plan_generate", "llm", phase="quiz_path",
        input_data={"language": language, "level": level, "segment_count": len(source_units)},
    )
    step.model = settings.openai_model
    step.system_prompt = system
    resp = await _client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ],
        temperature=0.35,
        response_format=_PLAN_RESPONSE_FORMAT,
        timeout=settings.openai_timeout_sec,
    )
    raw = json.loads(resp.choices[0].message.content or "{}")
    raw_segments = raw.get("segments") or []
    # Backward-compatible parsing keeps in-flight older model responses visible.
    if not raw_segments and isinstance(raw.get("composition"), dict):
        old_comp = raw["composition"]
        raw_segments = [{
            "segment_index": 0,
            "reference_answers": old_comp.get("model_answers") or [],
            "expressions": raw.get("expression_chunks") or [],
        }]
    semantic_normalizations = _normalize_unlicensed_detail_comparatives(
        raw_segments, source_units, language
    )
    raw_expression_count = sum(
        len(segment.get("expressions") or [])
        for segment in raw_segments if isinstance(segment, dict)
    )
    tracer.finish_step(
        step,
        output={
            "segment_count": len(raw_segments),
            "raw_expression_count": raw_expression_count,
            "semantic_normalizations": semantic_normalizations,
            "response_keys": list(raw.keys()),
        },
        artifacts=[("bundle_plan.json", raw, "application/json")],
    )

    base_source_meta = {
        "node_id": seed_node_id,
        "bundle_id": str(bundle_id),
        "mode": "statement",
        "language": language,
    }
    to_create: list[dict] = []

    # Each stable native-language unit is itself a composition question. The LLM
    # supplies references and expression annotations, never a replacement prompt.
    accepted_chunks: list[dict[str, Any]] = []
    seen_expression_keys: set[str] = set()
    segments_by_index = {
        int(segment.get("segment_index")): segment
        for segment in raw_segments
        if isinstance(segment, dict) and isinstance(segment.get("segment_index"), int)
    }
    for segment_index, prompt in enumerate(source_units):
        segment = segments_by_index.get(segment_index, {})
        references = segment.get("reference_answers") or []
        excluded_native_terms, excluded_target_terms = _segment_entity_terms(segment)
        comp = {
            "source_label": "진술 노드",
            "model_answers": references,
            "target_expressions": [
                str(item.get("canonical_form") or item.get("text") or "").strip()
                for item in (segment.get("expressions") or []) if isinstance(item, dict)
            ],
            "key_expressions": [
                {
                    "expression": str(item.get("canonical_form") or item.get("text") or "").strip(),
                    "meaning": str(item.get("meaning") or "").strip(),
                    "example": str((references[0] if references else {}).get("text") or "")
                    if isinstance(references[0] if references else {}, dict) else "",
                }
                for item in (segment.get("expressions") or []) if isinstance(item, dict)
            ],
        }
        source_meta = {
            **base_source_meta,
            "segment_index": segment_index,
            "segment_id": f"{seed_node_id}:{segment_index}",
            "source_text": prompt,
        }
        qd = _compose_quiz_data(comp, language, level)
        qd["_source"] = dict(source_meta)
        to_create.append({
            "quiz_type": "composition",
            "question_ko": prompt,
            "sentence_en": None,
            "quiz_data": qd,
            "segment_key": str(segment_index),
        })
        for local_index, chunk in enumerate(segment.get("expressions") or []):
            if not isinstance(chunk, dict):
                continue
            canonical = str(chunk.get("canonical_form") or chunk.get("text") or "").strip()
            key_set = _usable_expression_chunks([chunk], language=language)
            key = _expression_key(canonical)
            if key not in key_set or key in seen_expression_keys:
                continue
            # A valid reusable canonical expression can arrive with a polluted
            # reference surface (for example ``auf der Webseite von Entok``).
            # Keep the expression, but remove that contextual surface before the
            # cloze stage so the model is never encouraged to blank the name.
            surface_form = str(chunk.get("surface_form") or canonical).strip()
            reference_text = str(
                (references[0] if references and isinstance(references[0], dict) else {}).get("text")
                or surface_form
            )
            surface_pollution = _surface_answer_contract_reason(
                answer=surface_form,
                sentence_target=reference_text,
                canonical_form=canonical,
                excluded_target_terms=excluded_target_terms,
                language=language,
            )
            if surface_pollution:
                surface_form = canonical
            surface_segments = [
                str(value).strip()
                for value in (chunk.get("surface_segments") or [])
                if str(value).strip()
                and not _surface_answer_contract_reason(
                    answer=str(value).strip(),
                    sentence_target=reference_text,
                    canonical_form=canonical,
                    excluded_target_terms=excluded_target_terms,
                    language=language,
                )
            ]
            accepted_chunks.append({
                **chunk,
                "expression_id": f"{segment_index}:{local_index}",
                "canonical_form": canonical,
                "surface_form": surface_form,
                "surface_segments": surface_segments,
                "excluded_native_terms": excluded_native_terms,
                "excluded_target_terms": excluded_target_terms,
                "segment_index": segment_index,
                "source_segment": prompt,
                "semantic_guardrails": _source_semantic_guardrails(prompt, language),
                "reference_answers": references,
            })
            seen_expression_keys.add(key)

    expression_keys = set(seen_expression_keys)
    if seed_node_id and accepted_chunks:
        from .node_expression_store import save_node_expressions

        await save_node_expressions(
            user.id,
            str(seed_node_id),
            language,
            [
                {
                    "expression": chunk["canonical_form"],
                    "meaning": str(chunk.get("meaning") or "").strip(),
                    "example": str(
                        ((chunk.get("reference_answers") or [{}])[0]).get("text") or ""
                    ) if isinstance((chunk.get("reference_answers") or [{}])[0], dict) else "",
                    "surface_form": chunk.get("surface_form"),
                    "meaning_parts": chunk.get("meaning_parts") or [],
                }
                for chunk in accepted_chunks
            ],
            node_name=str(seed.get("node_name") or seed.get("content_ko") or ""),
        )

    # Stage two generates one card per extracted expression. There is no repair
    # call and no subjective LLM approval/rejection call after this point.
    cloze_items: list[Any] = []
    if accepted_chunks:
        cloze_system = _build_cloze_system_prompt(
            native_label, target_label, level, lang_guide(language), language
        )
        cloze_payload = {
            "source_statement": str(seed.get("content_ko") or ""),
            "expressions": accepted_chunks,
        }
        cloze_step = tracer.begin_step(
            "bundle_cloze_generate", "llm", phase="quiz_path",
            input_data={
                "expression_count": len(accepted_chunks),
                "expressions": [chunk["canonical_form"] for chunk in accepted_chunks],
            },
        )
        cloze_step.model = settings.openai_model
        cloze_step.system_prompt = cloze_system
        cloze_resp = await _client().chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": cloze_system},
                {"role": "user", "content": json.dumps(cloze_payload, ensure_ascii=False)},
            ],
            temperature=0.25,
            response_format=_CLOZE_RESPONSE_FORMAT,
            timeout=settings.openai_timeout_sec,
        )
        cloze_raw = json.loads(cloze_resp.choices[0].message.content or "{}")
        cloze_items = list(cloze_raw.get("cloze") or [])
        tracer.finish_step(
            cloze_step,
            output={"returned_count": len(cloze_items), "response_keys": list(cloze_raw.keys())},
            artifacts=[("cloze.json", cloze_raw, "application/json")],
        )

    cloze_candidates, structural_reasons = _prepare_cloze_candidates(
        cloze_items,
        language=language,
        level=level,
        source_meta=base_source_meta,
        expression_contracts={
            str(chunk["expression_id"]): chunk for chunk in accepted_chunks
        },
    )
    chunks_by_id = {str(chunk["expression_id"]): chunk for chunk in accepted_chunks}
    for candidate in cloze_candidates:
        chunk = chunks_by_id.get(candidate["expression_id"])
        if chunk is None:
            candidate_key = _expression_key(candidate["expression"])
            chunk = next(
                (
                    item for item in accepted_chunks
                    if _expression_key(item["canonical_form"]) == candidate_key
                ),
                None,
            )
        if chunk is None:
            continue
        candidate["spec"]["expression_key"] = _expression_key(chunk["canonical_form"])
        candidate["spec"]["quiz_data"].update({
            "canonical_form": chunk["canonical_form"],
            "surface_form": candidate["blank"],
            "meaning": str(chunk.get("meaning") or ""),
            "meaning_parts": chunk.get("meaning_parts") or [],
            "source_segment": chunk.get("source_segment"),
            "surface_segments": chunk.get("surface_segments") or [],
        })
        to_create.append(candidate["spec"])
    tracer_step = tracer.begin_step(
        "bundle_structural_validation", "policy", phase="quiz_path",
        input_data={"candidate_count": len(cloze_items), "expression_count": len(expression_keys)},
    )
    tracer.finish_step(tracer_step, output={
        "accepted_count": len(cloze_candidates),
        "structural_rejections": structural_reasons,
        "llm_quality_gate": "disabled",
    })
    if not any(q["quiz_type"] == "cloze" for q in to_create):
        logger.warning("Bundle produced no structurally renderable cloze: user=%s node=%s", user.id, seed_node_id)

    trace = tracer.finish(status="completed")

    created: list[Quiz] = []
    existing_clozes = (
        await session.scalars(
            select(Quiz).where(
                Quiz.user_id == user.id,
                Quiz.language == language,
                Quiz.quiz_type == "cloze",
                Quiz.queue_kind != "archived",
            )
        )
    ).all()
    active_expression_keys = {
        _expression_key(
            str((quiz.quiz_data or {}).get("canonical_form")
                or (quiz.quiz_data or {}).get("blank") or "")
        )
        for quiz in existing_clozes
    }
    for spec in to_create:
        identity = spec.get("expression_key") or f"composition:{spec.get('segment_key', '0')}"
        # Vocabulary identity is global per learner/language/canonical form so
        # the same answer from multiple nodes becomes one learning target. A
        # composition identity remains source-segment specific.
        identity_scope = "vocabulary" if spec["quiz_type"] == "cloze" else str(seed_node_id)
        if spec["quiz_type"] == "cloze" and identity in active_expression_keys:
            logger.info(
                "Skipping existing vocabulary target: language=%s expression=%s",
                language,
                identity,
            )
            continue
        generation_key = hashlib.sha256(
            f"{user.id}|{language}|{identity_scope}|{spec['quiz_type']}|{identity}".encode()
        ).hexdigest()
        existing = await session.scalar(
            select(Quiz).where(Quiz.user_id == user.id, Quiz.generation_key == generation_key)
        )
        if existing is not None:
            logger.info("Skipping duplicate bundle quiz: node=%s type=%s expression=%s", seed_node_id, spec["quiz_type"], identity)
            continue
        quiz = await crud.create_quiz(
            session,
            user_id=user.id,
            quiz_type=spec["quiz_type"],
            question_ko=spec["question_ko"],
            sentence_en=spec["sentence_en"],
            quiz_data=spec["quiz_data"],
            difficulty_level=level,
            queue_kind="new",
            language=language,
            source_nodes=seed_nodes,
            pipeline_trace=trace,
            debug_run_dir=tracer.debug_dir_relative,
            generation_key=generation_key,
        )
        if spec["quiz_type"] == "cloze":
            tts_text = resolve_quiz_tts_text(
                spec["quiz_type"],
                {"sentence_en": spec["sentence_en"], "quiz_data": spec["quiz_data"]},
            )
            audio_url, tts_error = await synthesize_quiz_audio(
                quiz.id,
                tts_text,
                language=language,
            )
            if audio_url:
                quiz.quiz_data = {**(quiz.quiz_data or {}), "audio_url": audio_url}
                await session.commit()
                await session.refresh(quiz)
            elif tts_error:
                logger.warning("Bundle quiz audio unavailable for quiz=%s: %s", quiz.id, tts_error)
        created.append(quiz)
        if spec["quiz_type"] == "cloze":
            active_expression_keys.add(identity)

    return created, trace
