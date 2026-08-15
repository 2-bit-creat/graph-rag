"""Statement exploration for composition units and expression-based cloze cards.

A Statement is split into stable native-language composition prompts. Per target
language, one planning call creates reference realizations and extracts canonical
expressions plus their inflected surface forms (``bundle_plan_generate``), then a
second call performs the sole semantic release edit for both composition and
cloze (``bundle_plan_quality_review``). Each accepted expression is copied
deterministically from that reviewed target sentence into a cloze candidate, so
the same frozen bilingual contract is not paid for and reviewed twice. Old
unreviewed inventory and any newly repaired alignment still receive an explicit
cloze release review. There is no reference fallback; unchecked or still-failing
cards are withheld.
"""

from __future__ import annotations

import json
import hashlib
import logging
import random
import re
import uuid
import asyncio
from copy import deepcopy
from functools import lru_cache
from typing import Any

from openai import AsyncOpenAI
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .expression_entity_guard import EntityNameGuard, build_statement_entity_guard
from .language_packs import native_quiz_pack, pair_rules, target_pack
from .language_packs import reasons as R
from .quiz_prompt_profiles import QuizPromptProfile, get_quiz_prompt_profile
from .level_guidelines import cefr_label, get_level_band
from .models import Quiz, User
from .pipeline_trace import PipelineTracer
from .text_coverage import native_ngram_coverage, split_statement_units
from .quiz_audio_engine import synthesize_quiz_audio_assets
from .quiz_generator import (
    _LANG_DISPLAY_NAMES,
    _default_question_ko,
    validate_quiz_payload,
)

logger = logging.getLogger(__name__)

# Bump this whenever the cloze contract changes.  The batch service uses it to
# retry sources that were exhausted by an older, broken prompt/normalizer.
CLOZE_GENERATOR_VERSION = "cloze-contract-v17-single-semantic-review"

_REVIEW_CONTRACT_VERSION = "pair-release-v1"

_CLOZE_RELEASE_SCORE = 92
_BLANK_RUN_RE = re.compile(r"_{2,}")
# Kept as a module-level alias: several structural helpers below tokenize
# canonical/answer text with the English word pattern regardless of target
# language when doing generic bookkeeping (not a quality gate). Language-
# specific gates go through ``language_packs`` instead — see that package's
# docstring for why the split exists.
_ENGLISH_WORD_RE = re.compile(r"[A-Za-z]+(?:['-][A-Za-z]+)*")


def _native_script_re(native_language: str) -> re.Pattern[str]:
    """Regex matching one character of the given native language's script —
    used to sanity-check that a "native text" field is actually in that
    script rather than accidentally left in the target language."""
    return native_quiz_pack(native_language).script_re


def lang_guide(language: str) -> str:
    return target_pack(language).teaching_guide or target_pack("english").teaching_guide


def localized_quality_rules(language: str) -> str:
    return target_pack(language).quality_rubric or target_pack("english").quality_rubric


def _lang_label(language: str) -> str:
    return _LANG_DISPLAY_NAMES.get((language or "").lower(), (language or "").title())


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


def _temperature_args(model: str, value: float) -> dict[str, float]:
    """Reasoning-family models choose their own sampling; older models accept temperature."""
    return {} if (model or "").lower().startswith("gpt-5") else {"temperature": value}


def _usage_payload(response: Any) -> dict[str, int]:
    """Persist provider token accounting in traces without storing secrets."""
    usage = getattr(response, "usage", None)
    prompt_details = getattr(usage, "prompt_tokens_details", None)
    completion_details = getattr(usage, "completion_tokens_details", None)
    return {
        "prompt_tokens": int(getattr(usage, "prompt_tokens", 0) or 0),
        "completion_tokens": int(getattr(usage, "completion_tokens", 0) or 0),
        "total_tokens": int(getattr(usage, "total_tokens", 0) or 0),
        "cached_prompt_tokens": int(getattr(prompt_details, "cached_tokens", 0) or 0),
        "reasoning_tokens": int(getattr(completion_details, "reasoning_tokens", 0) or 0),
    }


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
    "source_text": "<exact contiguous native source span>",
    "prompt_native": "<short self-contained native composition prompt preserving the source meaning>",
    "grammar_focus": ["<one useful target-language grammar focus>"],
    "context_entities": [{"native": "<proper name in source>", "target_forms": ["<target-language spellings used in references>"]}],
    "reference_answers": [{"text": "<natural TARGET-language realization>", "register": "casual|neutral|formal", "note": "<native-language note>"}],
    "expressions": [{
      "canonical_form": "<dictionary/wordbook form, including important modifiers>",
      "surface_form": "<how it is realized in the reference answer; may be inflected>",
      "surface_segments": ["<one or more target-language spans in sentence order>"],
      "meaning": "<complete native-language meaning preserving intensity, negation, modality and aspect>",
      "meaning_parts": [{"target": "<meaning-bearing part>", "native": "<its native-language contribution>"}],
      "quality_score": 0,
      "quality_reason": "<why this expression is natural, reusable and worth producing>",
      "kind": "collocation|verb_phrase|grammar|domain_term|discourse_frame"
    }]
  }]
}"""

_CLOZE_SCHEMA_HINT = """{
  "cloze": [{
    "expression_id": "<supplied id>",
    "canonical_form": "<copy supplied canonical form>",
    "surface_answer": "<natural inflected contiguous answer used in sentence_target>",
    "question_native": "<short NATIVE-language instruction that does not reveal the answer>",
    "sentence_native": "<complete NATIVE-language translation of sentence_target>",
    "answer_native": "<exact matching NATIVE-language surface span copied from sentence_native>",
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
                            "segment_index", "source_text", "prompt_native", "grammar_focus", "context_entities",
                            "reference_answers", "expressions",
                        ],
                        "properties": {
                            "segment_index": {"type": "integer"},
                            "source_text": {"type": "string"},
                            "prompt_native": {"type": "string"},
                            "grammar_focus": {
                                "type": "array",
                                "items": {"type": "string"},
                            },
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
                                        "quality_score", "quality_reason",
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
                                        "quality_score": {"type": "integer", "minimum": 0, "maximum": 100},
                                        "quality_reason": {"type": "string"},
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


def _bundle_schema_hint(profile: QuizPromptProfile) -> str:
    """Make the native gloss field impossible to confuse across directions."""
    return _BUNDLE_SCHEMA_HINT.replace(
        '"meaning": "<complete native-language meaning preserving intensity, negation, modality and aspect>"',
        f'"{profile.native_gloss_field}": "<complete {profile.native_language} meaning preserving intensity, negation, modality and aspect>"',
    )


def _plan_response_format(profile: QuizPromptProfile) -> dict[str, Any]:
    """Use meaning_ko/meaning_en in strict output instead of an ambiguous meaning field."""
    response_format = deepcopy(_PLAN_RESPONSE_FORMAT)
    response_format["json_schema"]["name"] = (
        f"statement_expression_plan_{profile.key.replace('-', '_')}"
    )
    expression_schema = response_format["json_schema"]["schema"]["properties"][
        "segments"
    ]["items"]["properties"]["expressions"]["items"]
    expression_schema["required"] = [
        profile.native_gloss_field if key == "meaning" else key
        for key in expression_schema["required"]
    ]
    expression_schema["properties"][profile.native_gloss_field] = (
        expression_schema["properties"].pop("meaning")
    )
    return response_format


def _normalize_plan_language_fields(
    payload: dict[str, Any], profile: QuizPromptProfile
) -> dict[str, Any]:
    """Map concrete strict-output field names to the internal neutral model."""
    for segment in payload.get("segments") or []:
        if not isinstance(segment, dict):
            continue
        for expression in segment.get("expressions") or []:
            if not isinstance(expression, dict):
                continue
            concrete = expression.get(profile.native_gloss_field)
            if concrete is not None:
                expression["meaning"] = concrete
    return payload

def _cloze_alignment_response_format(profile: QuizPromptProfile) -> dict[str, Any]:
    """Concrete-language output fields prevent native/target role reversal."""
    required = [
        "expression_id",
        "canonical_form",
        profile.target_answer_field,
        profile.native_gloss_field,
    ]
    return {
        "type": "json_schema",
        "json_schema": {
            "name": f"expression_alignment_{profile.key.replace('-', '_')}",
            "strict": True,
            "schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["alignments"],
                "properties": {
                    "alignments": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "required": required,
                            "properties": {
                                "expression_id": {"type": "string"},
                                "canonical_form": {"type": "string"},
                                profile.target_answer_field: {"type": "string"},
                                profile.native_gloss_field: {"type": "string"},
                            },
                        },
                    },
                },
            },
        },
    }

_CLOZE_QA_RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {
        "name": "cloze_card_quality_review",
        "strict": True,
        "schema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["reviews"],
            "properties": {
                "reviews": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["expression_id", "verdict", "score", "issues"],
                        "properties": {
                            "expression_id": {"type": "string"},
                            "verdict": {"type": "string", "enum": ["pass", "repair"]},
                            "score": {"type": "integer", "minimum": 0, "maximum": 100},
                            "issues": {"type": "array", "items": {"type": "string"}},
                        },
                    },
                },
            },
        },
    },
}


def _build_cloze_qa_system_prompt(
    native_label: str,
    target_label: str,
    native_language: str = "korean",
    target_language: str = "english",
) -> str:
    profile = get_quiz_prompt_profile(native_language, target_language)
    return (
        f"{profile.review_rules} "
        "You are the independent release editor for a commercial native-level language-learning product. "
        "Review every card from scratch; never trust the author or planner. A false pass teaches an error, so be conservative about PASS. "
        f"Target language: {target_label}. Native language: {native_label}. Score strictly on: idiomatic target-language usage (20), "
        "learning value and reusable expression boundary (15), source fidelity (15), exact inflected answer boundary (15), "
        "context that makes the intended answer reasonably recoverable with the native meaning and letter hint (10), complete native "
        "translation of every clause (15), level/length fit (5), and concise useful wording (5). A card must be repaired when score < 92, "
        "when surface_answer itself imports a sibling expression, when the native sentence omits or adds meaning, or when the example is unnatural. "
        "A sibling expression may remain outside the blank when it is part of the faithful short source sentence; that is context, not "
        "sibling_expression_leak. "
        "The native answer gloss must translate the WHOLE surface_answer with the same semantic scope and grammatical role, not merely "
        "one convenient word. Explicitly reject part-of-speech or constituent mismatches (for example, English noun phrase "
        "'a conservative discount rate' cannot be glossed only as Korean adverb '보수적으로'; the span must express the rate itself, such "
        "as '보수적인 할인율'). Distinguish lexical senses and domain collocations: in finance, 'use/apply a conservative discount rate' "
        "means using/applying a prudently chosen rate; do not approve a mechanically rearranged translation that changes what is modified. "
        "Both target and native sentences must sound publishable to an educated native speaker, not merely grammatical or understandable. "
        "Do not rewrite cards. Return terse machine-readable issue codes such as unnatural_collocation, sibling_expression_leak, "
        "translation_omission, translation_addition, semantic_scope_mismatch, part_of_speech_mismatch, wrong_sense, ambiguous_answer, "
        "answer_boundary, source_drift, too_long, or level_mismatch."
    )


def _quality_feedback_for_items(
    items: list[dict[str, Any]], reviews: dict[str, dict[str, Any]]
) -> dict[str, list[str]]:
    """Fail closed: every learner-facing card needs an explicit high-score pass."""
    feedback: dict[str, list[str]] = {}
    for item in items:
        expression_id = str(item.get("expression_id") or "")
        review = reviews.get(expression_id)
        if review is None:
            feedback[expression_id] = ["missing_quality_review"]
            continue
        if review.get("verdict") != "pass" or int(review.get("score") or 0) < _CLOZE_RELEASE_SCORE:
            feedback[expression_id] = list(review.get("issues") or ["quality_score_below_release_bar"])
    return feedback


def _has_reusable_release_review(chunk: dict[str, Any]) -> bool:
    """Whether a frozen bilingual expression passed the current editor contract.

    Version equality invalidates old inventory automatically. Missing provenance
    follows the safe legacy path and receives an explicit cloze review.
    """
    return bool(chunk.get("release_reviewed")) and bool(chunk.get("review_model")) and (
        str(chunk.get("review_contract_version") or "") == _REVIEW_CONTRACT_VERSION
    )


def _store_legacy_cloze_fields(card: dict[str, Any]) -> dict[str, Any]:
    """Translate model-facing language-neutral names to the persisted API names."""
    mapped = dict(card)
    for neutral, legacy in (
        ("question_native", "question_ko"),
        ("sentence_native", "sentence_ko"),
        ("answer_native", "target_ko"),
    ):
        if neutral in mapped:
            mapped[legacy] = mapped.pop(neutral)
    return mapped


def _review_cloze_view(card: dict[str, Any]) -> dict[str, Any]:
    """Hide misleading legacy ``*_ko`` names from the independent model reviewer."""
    view = dict(card)
    for legacy, neutral in (
        ("question_ko", "question_native"),
        ("sentence_ko", "sentence_native"),
        ("target_ko", "answer_native"),
    ):
        if legacy in view:
            view[neutral] = view.pop(legacy)
    return view


def _source_alignment_span(source: str, chunk: dict[str, Any]) -> str:
    """Recover an exact native span from reviewed bilingual meaning parts."""
    text = (source or "").strip()
    if not text:
        return ""
    lowered = text.casefold()
    def find_span(phrase: str) -> tuple[int, int] | None:
        needle = phrase.strip().casefold()
        if re.fullmatch(r"[a-z][a-z '\-]*", needle):
            exact = re.search(r"(?<![a-z])" + re.escape(needle) + r"(?![a-z])", lowered)
            start = exact.start() if exact else -1
        else:
            start = lowered.find(needle)
        if start >= 0:
            return start, start + len(phrase.strip())
        # English meaning_parts often store the bare lemma ("apply") while
        # the source contains an inflected form ("is applying"). Recover that
        # span whether or not the planner prefixed the lemma with "to ".
        lemma_phrase = needle[3:] if needle.startswith("to ") else needle
        if not re.fullmatch(r"[a-z]+(?:\s+[a-z][a-z -]*)?", lemma_phrase):
            return None
        words = lemma_phrase.split(maxsplit=1)
        if not words:
            return None
        verb = words[0]
        tail = f" {words[1]}" if len(words) > 1 else ""
        forms = {verb, f"{verb}s", f"{verb}ed", f"{verb}ing"}
        if verb.endswith("e"):
            forms.add(f"{verb[:-1]}ing")
        if verb.endswith("y") and len(verb) > 1:
            forms.add(f"{verb[:-1]}ies")
        for form in sorted(forms, key=len, reverse=True):
            candidate = f"{form}{tail}"
            start = lowered.find(candidate)
            if start < 0:
                continue
            prefix = lowered[:start]
            aux = re.search(r"\b(?:am|is|are|was|were|be|been|being|has|have|had|will)\s+$", prefix)
            return (aux.start() if aux else start), start + len(candidate)
        return None

    candidates: list[tuple[int, int]] = []
    meaning = str(chunk.get("meaning") or "").strip()
    if meaning:
        span = find_span(meaning)
        if span:
            candidates.append(span)
    spans: list[tuple[int, int]] = []
    alignable_parts = []
    for part in chunk.get("meaning_parts") or []:
        if not isinstance(part, dict):
            continue
        native = str(part.get("native") or "").strip()
        if len(native) < 3:
            continue
        alignable_parts.append(native)
        span = find_span(native)
        if span:
            spans.append(span)
    # A partial subset recreates the original bug: noun-only "discount rate"
    # was accepted for the full action "applying a conservative discount
    # rate". Only combine parts when every meaningful contribution aligned.
    if spans and len(spans) == len(alignable_parts):
        candidates.append((
            min(value[0] for value in spans),
            max(value[1] for value in spans),
        ))
    if not candidates:
        return ""
    start, end = max(candidates, key=lambda value: value[1] - value[0])
    return text[start:end].strip()


# Both now live in ``precision_text`` so the knowledge-graph extractor can reuse
# them without importing this module's language packs, TTS and OpenAI client.
# Kept under their original private names: every call site below is unchanged.
_split_statement_units = split_statement_units
_native_ngram_coverage = native_ngram_coverage


def _composition_prompt_for_segment(segment: dict[str, Any]) -> str:
    source_text = str(segment.get("source_text") or "").strip()
    prompt_native = str(segment.get("prompt_native") or source_text).strip()
    if not source_text:
        return prompt_native
    # Permit small grammatical repairs, but never a summary that silently drops
    # a clause. Exact source text is preferable to an incomplete easy question.
    # A complete Korean Statement is already the best learner prompt. The
    # planner once changed a declaration into "어떤 할인율을 적용하나요?", which
    # silently removed modifiers even though the reference still translated
    # the original sentence.
    korean_complete = bool(
        re.search(r"[가-힣](?:다|요|죠|네|니다|습니다)[.!?]?$", source_text)
    )
    chosen = (
        source_text
        if korean_complete or _native_ngram_coverage(source_text, prompt_native) < 0.72
        else (prompt_native or source_text)
    )
    # English source spans may legitimately begin after a comma with a
    # coordinating connective. A standalone composition task must not.
    leading = re.match(r"^(?:and|but|so)\s+(.+)$", chosen, re.IGNORECASE)
    if leading:
        chosen = leading.group(1)
        chosen = chosen[:1].upper() + chosen[1:]
    chosen = chosen.rstrip(" ,")
    # Planner spans often end at a Korean connective boundary. Convert only
    # narrow, high-confidence endings so the learner receives a real sentence.
    ending_rewrites = (
        (r"했고$", "했다."),
        (r"였고$", "였다."),
        (r"았고$", "았다."),
        (r"었고$", "었다."),
        (r"한다고$", "한다."),
        (r"하며$", "한다."),
        (r"지만$", "다."),
    )
    for pattern, replacement in ending_rewrites:
        if re.search(pattern, chosen):
            return re.sub(pattern, replacement, chosen)
    return chosen if re.search(r"[.!?]$", chosen) else f"{chosen}."


def _trim_overlapping_segment_sources(segments: list[dict[str, Any]]) -> None:
    """Remove a later unit accidentally duplicated inside an earlier source span."""
    index = 0
    while index < len(segments) - 1:
        current = str(segments[index].get("source_text") or "").strip()
        following = str(segments[index + 1].get("source_text") or "").strip()
        if not current or not following or current == following:
            index += 1
            continue
        overlap_at = current.find(following)
        if overlap_at > 0:
            prefix = current[:overlap_at].strip()
            # If removing the duplicate tail would leave only an adverb or
            # connective (e.g. "동시에"), the later segment is the duplicate;
            # keep the more complete first unit and drop the redundant one.
            if len(prefix) < 8:
                del segments[index + 1]
                continue
            if prefix:
                segments[index]["source_text"] = prefix
                prompt = str(segments[index].get("prompt_native") or "")
                if following in prompt:
                    segments[index]["prompt_native"] = prefix
        index += 1


def _plan_domain_contract_reason(
    source_statement: str,
    segments: list[dict[str, Any]],
    *,
    native_language: str,
    target_language: str,
) -> str | None:
    """Deterministic contracts for terms whose generic paraphrase changes the lesson."""
    references = " ".join(
        str(answer.get("text") or "")
        for segment in segments
        if isinstance(segment, dict)
        for answer in segment.get("reference_answers") or []
        if isinstance(answer, dict)
    )
    expressions = " ".join(
        " ".join(
            (
                str(expression.get("canonical_form") or ""),
                str(expression.get("surface_form") or ""),
            )
        )
        for segment in segments
        if isinstance(segment, dict)
        for expression in segment.get("expressions") or []
        if isinstance(expression, dict)
    )
    source = source_statement.casefold()
    target = references.casefold()
    if native_language == "korean" and "갱신 손실" in source_statement:
        if target_language == "english" and "lost update" not in target:
            return "domain_term_mismatch: 갱신 손실 must be translated as 'lost update'"
        if target_language == "english" and "lost update" not in expressions.casefold():
            return (
                "domain_expression_mismatch: retain 'lost update' itself in at least one "
                "expression candidate so the domain term can become a cloze"
            )
        if target_language == "english" and re.search(
            r"\blost update\b[^.!?]{0,24}\boccur\w*\s+(?:in|to)\s+(?:the\s+)?balance\b",
            target,
            re.IGNORECASE,
        ):
            return (
                "domain_collocation_mismatch: a lost update can occur while/when updating "
                "the balance or occur in a system; it does not 'occur to the balance'"
            )
        if target_language == "german" and not (
            "lost update" in target
            or re.search(r"verloren\w*\s+update", target, re.IGNORECASE)
            or "aktualisierungsverlust" in target
            or re.search(r"verloren\w*\s+aktualisierung", target, re.IGNORECASE)
        ):
            return (
                "domain_term_mismatch: 갱신 손실 must use the explicit German technical term "
                "'Lost Update', 'verlorenes Update', 'Aktualisierungsverlust', or "
                "'verlorene Aktualisierung'; never a generic loss paraphrase"
            )
        if target_language == "german" and not (
            "lost update" in expressions.casefold()
            or re.search(r"verloren\w*\s+update", expressions, re.IGNORECASE)
            or "aktualisierungsverlust" in expressions.casefold()
            or re.search(r"verloren\w*\s+aktualisierung", expressions, re.IGNORECASE)
        ):
            return (
                "domain_expression_mismatch: retain the explicit German lost-update term "
                "in at least one expression candidate"
            )
    if native_language == "english" and "lost update" in source:
        if target_language == "korean" and "갱신 손실" not in references:
            return "domain_term_mismatch: 'lost update' must be translated as 갱신 손실"
        if target_language == "korean" and "갱신 손실" not in expressions:
            return (
                "domain_expression_mismatch: retain 갱신 손실 in at least one Korean "
                "expression candidate"
            )
    return None


def _native_expression_meaning(chunk: dict[str, Any], native_language: str) -> str:
    """Prefer a native-language meaning, rebuilding it from aligned parts."""
    native_script = _native_script_re(native_language)
    meaning = str(chunk.get("meaning") or "").strip()
    if native_script.search(meaning):
        return meaning
    native_parts = [
        str(part.get("native") or "").strip()
        for part in chunk.get("meaning_parts") or []
        if isinstance(part, dict)
        and native_script.search(str(part.get("native") or ""))
    ]
    return " ".join(dict.fromkeys(native_parts)) or meaning


def _quiz_role_models(settings: Any, native_language: str, target_language: str) -> tuple[str, str]:
    """Select measured author/editor roles for a language direction."""
    quality_model = settings.quiz_quality_model or settings.openai_model
    author_model = settings.quiz_author_model or quality_model
    if native_language == "english" and target_language == "korean":
        quality_model = getattr(settings, "quiz_quality_model_en_ko", "") or quality_model
        author_model = getattr(settings, "quiz_author_model_en_ko", "") or author_model
    return author_model, quality_model


def _inventory_expressions_by_index(
    segments: list[Any],
) -> dict[int, list[dict[str, Any]]]:
    """Merge duplicate segment rows instead of silently overwriting candidates."""
    merged: dict[int, list[dict[str, Any]]] = {}
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        segment_index = int(segment.get("segment_index") or 0)
        merged.setdefault(segment_index, []).extend(
            item
            for item in segment.get("expressions") or []
            if isinstance(item, dict)
        )
    return merged


def _review_collapses_long_plan(
    source_statement: str, proposed_count: int, reviewed_count: int
) -> bool:
    """Prevent a reviewer from re-merging already useful long composition units."""
    return (
        len(re.sub(r"\s+", "", source_statement or "")) >= 45
        and proposed_count >= 2
        and reviewed_count < proposed_count
    )


def _plan_has_incomplete_units(
    segments: list[Any],
    *,
    native_language: str = "korean",
    target_language: str = "english",
    check_expressions: bool = True,
) -> bool:
    """Detect subordinate/dangling fragments that cannot be composition tasks."""
    native_dangling = re.compile(r"(?:바람에|때문에|지만|는데|면서|하며|하고|했고|고)[.!?]?$" )
    english_leading_fragment = re.compile(
        r"^(?:and|but|so)\b|^(?:after|before|while)\s+[^,.!?]+(?:ing|ed)\b[^,.!?]*[.!?]?$",
        re.IGNORECASE,
    )
    target_dangling = re.compile(r"(?:,|\bbut|\band|\bwhile|\bbecause|\bdue to)[.!?]?$", re.IGNORECASE)
    for segment in segments:
        if not isinstance(segment, dict):
            return True
        prompt = _composition_prompt_for_segment(segment)
        # Older in-flight/test plans may omit prompt fields and are normalized
        # from the source immediately afterward; only explicit bad endings fail.
        if prompt and native_dangling.search(prompt):
            return True
        if native_language == "english" and prompt and english_leading_fragment.search(prompt):
            return True
        references = [
            str(answer.get("text") or "").strip()
            for answer in segment.get("reference_answers") or []
            if isinstance(answer, dict)
        ]
        if not references or any(not value or target_dangling.search(value) for value in references):
            return True
        if native_language == "korean" and target_language != "korean" and any(
            re.search(r"[가-힣]", value) for value in references
        ):
            return True
        if any(target_pack(target_language).sentence_language_reason(value) for value in references):
            return True
        if not check_expressions:
            continue
        pack = target_pack(target_language)
        for expression in segment.get("expressions") or []:
            if not isinstance(expression, dict):
                continue
            surface = str(expression.get("surface_form") or "").strip()
            if not surface or not any(pack.contains_span(value, surface) for value in references):
                return True
            if pack.teachability_reason(surface):
                return True
    return False


def _merge_english_leading_fragments(units: list[str]) -> list[str]:
    """Attach an English adverbial fragment to the following complete clause."""
    merged: list[str] = []
    index = 0
    fragment = re.compile(
        r"^(?:after|before|while)\s+[^,.!?]+(?:ing|ed)\b[^,.!?]*[.!?]?$",
        re.IGNORECASE,
    )
    while index < len(units):
        current = units[index].strip()
        # Contrast tails such as "not just glanced at them" cannot stand as
        # composition prompts. They modify the preceding assertion, unlike an
        # After/Before/While fragment which modifies the following clause.
        if re.match(r"^(?:not\s+(?:just|merely|only)|rather\s+than)\b", current, re.IGNORECASE):
            if merged:
                merged[-1] = f"{merged[-1].rstrip(' .')} — {current.rstrip(' .')}."
            index += 1
            continue
        if fragment.search(current) and index + 1 < len(units):
            merged.append(f"{current} {units[index + 1].strip()}")
            index += 2
            continue
        merged.append(current)
        index += 1
    return merged


def _normalize_german_frozen_expression(
    chunk: dict[str, Any], reference_text: str
) -> dict[str, Any]:
    """Recover a clean exact German span without inventing or rewriting text.

    A contextual possessive can be left outside a verb-phrase blank. When a
    separable verb makes the planned action discontinuous, a reviewed aligned
    noun phrase is a valid independent expression only when its own native
    meaning part is present.
    """
    pack = target_pack("german")
    surface = str(chunk.get("surface_form") or "").strip()
    words = pack.tokens(surface)
    if words and words[0].casefold() in pack.possessive_determiners:
        remainder = surface.split(maxsplit=1)[1] if len(surface.split(maxsplit=1)) == 2 else ""
        if (
            remainder
            and pack.contains_span(reference_text, remainder)
            and not pack.teachability_reason(remainder)
        ):
            return {**chunk, "surface_form": remainder, "surface_segments": [remainder]}

    if (
        surface
        and pack.contains_span(reference_text, surface)
        and not pack.surface_boundary_reason(
            answer=surface,
            sentence_target=reference_text,
            canonical_form=str(chunk.get("canonical_form") or ""),
        )
    ):
        return chunk

    canonical_words = pack.tokens(str(chunk.get("canonical_form") or ""))
    for width in range(len(canonical_words) - 1, 1, -1):
        for start in range(0, len(canonical_words) - width + 1):
            candidate = " ".join(canonical_words[start:start + width])
            if not pack.contains_span(reference_text, candidate) or pack.teachability_reason(candidate):
                continue
            candidate_tokens = {token.casefold() for token in pack.tokens(candidate)}
            aligned_parts = [
                part for part in chunk.get("meaning_parts") or []
                if isinstance(part, dict)
                and set(
                    token.casefold()
                    for token in pack.tokens(str(part.get("target") or ""))
                ) <= candidate_tokens
                and str(part.get("native") or "").strip()
            ]
            if not aligned_parts:
                continue
            native_meaning = " ".join(
                dict.fromkeys(str(part.get("native") or "").strip() for part in aligned_parts)
            )
            return {
                **chunk,
                "canonical_form": candidate,
                "surface_form": candidate,
                "surface_segments": [candidate],
                "meaning": native_meaning,
                "meaning_parts": aligned_parts,
                "kind": "domain_term",
                "quality_reason": (
                    f"{str(chunk.get('quality_reason') or '').strip()} "
                    "Normalized to an exact reviewed German noun span."
                ).strip(),
            }
    return chunk


def _source_semantic_guardrails(
    text: str, language: str, *, native_language: str = "korean"
) -> list[str]:
    guards = [
        "Do not add comparison, intensity, negation, modality, repetition, or certainty that is absent from source_text."
    ]
    for guardrail in pair_rules(native_language, language).guardrails:
        if not guardrail.source_re.search(text):
            continue
        note = guardrail.licensed_note if guardrail.licensed(text) else guardrail.note
        if note:
            guards.append(note)
    return guards


def _normalize_unlicensed_detail_comparatives(
    raw_segments: list[Any],
    source_units: list[str],
    language: str,
    *,
    native_language: str = "korean",
) -> list[dict[str, Any]]:
    """Narrow source-fidelity normalization, not a subjective quality judge."""
    changes: list[dict[str, Any]] = []
    guardrails = [
        g for g in pair_rules(native_language, language).guardrails
        if g.normalize_target or g.normalize_native
    ]
    if not guardrails:
        return changes
    for segment in raw_segments:
        if not isinstance(segment, dict):
            continue
        index = segment.get("segment_index")
        if not isinstance(index, int) or not 0 <= index < len(source_units):
            continue
        source = source_units[index]
        guardrail = next(
            (g for g in guardrails if g.source_re.search(source) and not g.licensed(source)),
            None,
        )
        if guardrail is None:
            continue

        def normalize_target(value: Any) -> Any:
            if not isinstance(value, str) or guardrail.normalize_target is None:
                return value
            return guardrail.normalize_target(value)

        def normalize_native_field(value: Any) -> Any:
            if not isinstance(value, str) or guardrail.normalize_native is None:
                return value
            return guardrail.normalize_native(value)

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
                expression["meaning"] = normalize_native_field(meaning)
            for part in expression.get("meaning_parts") or []:
                if isinstance(part, dict):
                    part["target"] = normalize_target(part.get("target"))
                    native = part.get("native")
                    if isinstance(native, str):
                        part["native"] = normalize_native_field(native)
        if changed:
            changes.append({
                "segment_index": index,
                "reason": f"unlicensed {guardrail.code} normalized per pair guardrail",
            })
    return changes


def _build_plan_system_prompt(
    native_label: str,
    target_label: str,
    level: int,
    guide: str,
    language: str = "english",
    native_language: str = "korean",
) -> str:
    band = get_level_band(level)
    profile = get_quiz_prompt_profile(native_language, language)
    return (
        f"{profile.plan_rules} "
        f"You are the dedicated {profile.key} curriculum planner. This prompt handles only {native_label} to {target_label}; never apply "
        "rules or field roles from another direction. Turn the Statement into 1-4 complete, self-contained study units. Merge dependent "
        "fragments; split only at proposition boundaries. source_text is an exact contiguous source span. prompt_native may make only a "
        "minimal grammatical repair and must preserve every proposition. Write one complete, publishable target reference, then extract "
        "expressions only from that finished sentence. "
        f"Native language: {native_label}. Learner level: {level}/100 (CEFR {band.cefr}). "
        f"Vocabulary scope: {band.vocabulary}. Grammar scope: {band.grammar}. Teaching focus: {guide} "
        f"Target-language quality rubric: {localized_quality_rules(language)} "
        "Return units in source order. Across the Statement select 2-6 genuinely useful candidates when supported. Prefer a predicate, "
        "collocation, grammar pattern, or domain term over generic words. canonical_form is the reusable dictionary identity; surface_form "
        "is one exact contiguous inflected substring of its reference. Never propose a discontinuous surface. meaning and meaning_parts.native "
        "must be complete natural native-language equivalents with the same constituent and scope. Preserve negation, aspect, modality, "
        "comparison, particles, objects, articles and prepositions. One candidate teaches one expression; exclude proper names, dates, IDs, "
        "brands, forbidden_entities, and contextual possessors. List names only in context_entities. Score 70+ only when the expression is "
        "idiomatic, source-faithful, reusable, exactly aligned and leaves useful sentence context. Do not emit quiz questions at this stage. "
        f"Respond only with JSON of this exact shape: {_bundle_schema_hint(profile)}"
    )


def _plan_prompt_extra_notes(language: str) -> str:
    """A per-target-pack addendum appended to the shared plan prompt.

    Empty for English (its rules are still the hardcoded sentences above,
    preserved byte-for-byte for the golden-prompt parity test); non-empty
    for a pack like German that needs a rule the shared English-oriented
    prose above doesn't state correctly for its own morphology."""
    notes = target_pack(language).plan_prompt_notes
    return f"{notes} " if notes else ""


def _build_plan_qa_system_prompt(
    native_label: str,
    target_label: str,
    level: int,
    language: str,
    native_language: str = "korean",
) -> str:
    profile = get_quiz_prompt_profile(native_language, language)
    return (
        f"{profile.plan_review_rules} "
        f"You are the independent senior release editor for only {profile.key}. This is the sole semantic release review shared by "
        "the composition card and every deterministic cloze made from its expressions. Return a corrected final plan, never comments. "
        f"Native language: {native_label}. Target language: {target_label}. Learner level: {level}/100. "
        "Internally make a proposition ledger: every predicate, argument, modifier, time, negation, contrast, cause, sequence and simultaneous "
        "action must map one-to-one between prompt_native and the target reference. Every unit has a complete main predicate; merge dependent "
        "fragments and remove dangling connectives. source_text remains an exact source span. Rewrite unnatural or wrong-language target text. "
        "For every expression independently verify and correct all of these release invariants: useful dictionary canonical form; exact contiguous "
        "surface_form in the corrected reference; no possessive/name/context leakage; complete native meaning with identical scope, aspect, argument "
        "coverage and part of speech; sufficient recoverable context outside the future blank; and native-level idiom on both sides. Remove an expression "
        "entirely when it cannot satisfy every invariant without changing the source meaning. Set quality_score below 92 for nothing you retain: retained "
        "expressions are release decisions, not suggestions. "
        "If an action is discontinuous in the finished sentence, choose another useful contiguous expression rather than fabricating a span. "
        f"Apply this target-language rubric: {localized_quality_rules(language)} "
        f"Respond only with JSON of this exact shape: {_bundle_schema_hint(profile)}"
    )


def _build_expression_inventory_system_prompt(
    native_label: str,
    target_label: str,
    level: int,
    language: str,
    native_language: str = "korean",
) -> str:
    profile = get_quiz_prompt_profile(native_language, language)
    return (
        f"{profile.inventory_rules} "
        "You are the expression-inventory editor for a language-learning product. "
        f"Native language: {native_label}. Target language: {target_label}. Learner level: {level}/100. "
        "The supplied segments and reference answers are final: preserve their source_text, prompt_native, grammar_focus, "
        "context_entities, and reference_answers exactly, and replace only expressions. Across the full plan return 2-6 "
        "high-value expressions when supported, normally 1-2 per segment. Extract each distinct useful action separately: "
        "if a reference says 'dried my wet shoes while checking the travel schedule', return one card candidate for drying "
        "shoes and another for checking the schedule; NEVER combine sibling actions with and/while. canonical_form must be "
        "a reusable dictionary/base form, normally 1-5 words, beginning with a base verb for verb phrases/collocations. A single "
        "semantically necessary verb phrase may use 6-7 words, but never pad it with optional context; never return "
        "a subject+predicate clause such as 'concurrent requests modify balance'. Preserve every grammatically required article and "
        "preposition: use 'reproduce a lost update', never the telegraphic 'reproduce lost update'. surface_form and every "
        "surface_segment must be an exact span "
        "of its segment's reference answer. meaning and every meaning_parts.native value MUST be complete natural native-language "
        "text, never target-language definitions. Exclude proper names, dates, and sentence-specific decoration from the answer. "
        "Use quality_score 70+ only for source-faithful, idiomatic, reusable production knowledge. Prefer a useful predicate or "
        "collocation over generic words, but do not invent a quota filler. "
        "Use established target-language terminology for domain concepts rather than literal calques; for example, the database anomaly "
        "Korean '갱신 손실' is 'lost update', never 'update loss'; a production-worthy verb phrase is 'reproduce a lost update'. "
        f"Apply this target-language rubric: {localized_quality_rules(language)} "
        f"{_plan_prompt_extra_notes(language)}"
        f"Respond only with JSON of this exact shape: {_bundle_schema_hint(profile)}"
    )


def _build_cloze_system_prompt(
    native_label: str,
    target_label: str,
    level: int,
    guide: str,
    language: str = "english",
    native_language: str = "korean",
) -> str:
    profile = get_quiz_prompt_profile(native_language, language)
    return (
        f"{profile.author_rules} "
        "You align exactly one expression to a frozen bilingual sentence pair. "
        f"Native language: {native_label}. Target language: {target_label}. Learner level: {level}/100. "
        f"Teaching focus: {guide} Target-language quality rubric: {localized_quality_rules(language)} "
        "Use the supplied frozen native sentence, frozen target sentence, canonical form, surface form, meaning parts and grammar as the only meaning source. "
        "Never generate, shorten, translate, or rewrite either sentence. Copy the target answer from the frozen target sentence and write one complete "
        "natural native-language gloss for that whole answer. A sibling expression may remain as context outside the answer. Do not weaken or omit "
        "meaning-bearing modifiers such as closer/more, again, still, barely, might, must or not, and never add one absent from the source. "
        "Korean '자세히' does not license English 'closer/more closely'; those require explicit '더 자세히'. canonical_form is a wordbook identity, "
        "NOT a literal substring requirement. Choose surface_answer as a natural inflected form for this sentence, but inflection may "
        "change grammar only: it must NEVER add a name, organization, event, place, date, product, or contextual noun that is not part of "
        "the reusable expression. Every supplied excluded entity is forbidden in the answer. Keep it outside the blank. The native gloss must cover "
        "the WHOLE target answer with the same semantic scope and grammatical role. It is a natural dictionary-style gloss and does not need to be a "
        "literal substring of the native sentence. If a discontinuous expression has no useful contiguous realization in the frozen sentence, choose "
        "a smaller valid reusable span or return an empty alignments array; never rewrite the sentence. "
        f"{_author_prompt_extra_notes(language)}"
        "Return only the concrete-language alignment JSON required by the response schema."
    )


def _author_prompt_extra_notes(language: str) -> str:
    """See ``_plan_prompt_extra_notes`` — same additive, English-neutral pattern."""
    notes = target_pack(language).author_prompt_notes
    return f"{notes} " if notes else ""


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
    native_language: str = "korean",
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
    pack = target_pack(language)
    matcher = pack.answer_boundary_re(blank)
    if "_" in full_sentence or len(list(matcher.finditer(full_sentence))) != 1:
        return None
    prompt = matcher.sub("___", full_sentence, count=1)
    if pack.sentence_length_reason(full_sentence) or pack.sentence_language_reason(full_sentence):
        return None
    if pack.blank_context_reason(full_sentence, blank):
        return None

    sentence_ko = str(item.get("sentence_ko") or "").strip()
    target_ko = str(item.get("target_ko") or "").strip()
    if not sentence_ko:
        return None
    native_pack = native_quiz_pack(native_language)
    native_script = native_pack.script_re
    # The author sometimes copies the target-language sentence into BOTH native
    # fields verbatim, so sentence_ko and target_ko agree with each other and
    # every alignment check below passes — the card ships with its "문장 뜻"
    # rendered in the language the learner is supposed to be producing. The
    # older check right after this one only fired when sentence_ko was in the
    # native language, so it skipped exactly this case. A whole native sentence
    # always carries native script, so requiring it here costs nothing.
    if not native_script.search(sentence_ko):
        return None
    if target_ko and not native_script.search(target_ko):
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
    if native_pack.generic_filler_re.search(sentence_ko):
        return None
    if not target_ko:
        return None
    # A natural cross-language gloss is not always a literal contiguous source
    # span (Korean endings, English phrasal verbs, and German separable verbs are
    # common counterexamples). Highlight it when exact alignment exists; keep
    # the complete native sentence otherwise. Semantic scope is reviewed below.
    context_ko = (
        sentence_ko.replace(target_ko, f"<span color='#FFA500'>{target_ko}</span>", 1)
        if native_pack.contains_span(sentence_ko, target_ko)
        else sentence_ko
    )
    return full_sentence, prompt, blank, context_ko


def _is_teachable_cloze(blank: str, *, language: str) -> bool:
    """Reject answers that cannot justify a production-learning card."""
    return target_pack(language).teachability_reason(blank) is None


def _expression_key(value: str) -> str:
    """Canonical expression identity shared by extraction, QA, and persistence."""
    return " ".join(re.findall(r"[\w'-]+", value.casefold()))


def _expression_utility_score(chunk: dict[str, Any], pack: Any = None) -> int:
    """Transparent first-pass ranking for deferred cloze materialisation."""
    canonical = str(chunk.get("canonical_form") or chunk.get("text") or "").strip()
    tokenizer = pack or target_pack("english")
    words = len(tokenizer.tokens(canonical)) or len(canonical.split())
    kind = str(chunk.get("kind") or "")
    score = 10 + min(words, 4) * 3
    if kind in {"collocation", "verb_phrase", "grammar", "discourse_frame"}:
        score += 5
    elif kind == "domain_term":
        score += 2
    if chunk.get("meaning_parts"):
        score += 2
    return score


# Gates below only make sense for a self-contained action/collocation, not for
# a grammar pattern or discourse frame that legitimately spans a whole clause.
_LENGTH_GATED_KINDS = frozenset({"verb_phrase", "collocation"})


def _select_quality_expression_chunks(
    chunks: list[dict[str, Any]],
    *,
    language: str = "english",
    limit: int = 6,
    native_language: str = "korean",
) -> list[dict[str, Any]]:
    """Rank useful expressions while removing nested/near-duplicate targets.

    Which gates actually reject a candidate is entirely data-driven per
    target-language pack: ``length_reason``/``sibling_join_reason``/
    ``base_form_reason``/``clause_answer_reason`` are called for every
    language here, but they are no-ops unless the pack configures
    ``max_words``/``coordinators``/overrides them — so English (fully
    configured) behaves exactly as before, and German/Korean (not yet
    configured beyond Phase 2) stay exactly as permissive as before too.
    Phase 4/5 tighten German/Korean by adding data to their packs, not by
    touching this function again.
    """
    pack = target_pack(language)
    native = native_quiz_pack(native_language)
    ranked = sorted(
        chunks,
        key=lambda item: (
            int(item.get("quality_score") or 0),
            _expression_utility_score(item, pack),
            len(_expression_key(str(item.get("canonical_form") or ""))),
        ),
        reverse=True,
    )
    selected: list[dict[str, Any]] = []
    selected_tokens: list[set[str]] = []
    for chunk in ranked:
        if int(chunk.get("quality_score") or 0) < 70:
            continue
        canonical = str(chunk.get("canonical_form") or "")
        key = _expression_key(canonical)
        tokens = set(key.split())
        if not tokens:
            continue
        kind = str(chunk.get("kind") or "").lower()
        if kind in _LENGTH_GATED_KINDS:
            if (
                pack.length_reason(canonical, kind)
                or pack.sibling_join_reason(canonical)
                or pack.clause_answer_reason(chunk, key, native)
                or pack.base_form_reason(canonical, kind)
            ):
                continue
        # Nested targets such as "acquire control" / "acquire management
        # control" test the same production knowledge. Keep the higher-ranked
        # contract, while allowing genuinely different phrases from one unit.
        if any(
            tokens <= existing or existing <= tokens
            for existing in selected_tokens
        ):
            continue
        selected.append(chunk)
        selected_tokens.append(tokens)
        if len(selected) >= limit:
            break
    return sorted(selected, key=lambda item: (
        int(item.get("segment_index") or 0),
        str(item.get("expression_id") or ""),
    ))


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
    come from the planning payload; capitalization-based detection is a
    per-language fallback for a missed entity such as ``Antock``/``Entok``
    (see ``TargetLanguagePack.surface_boundary_reason``).
    """
    pack = target_pack(language)
    for term in sorted(set(excluded_target_terms), key=len, reverse=True):
        if pack.contains_term(answer, term):
            return f"surface_answer contains excluded context entity {term!r}"
    canonical_tokens = pack.tokens(canonical_form)
    answer_tokens = pack.tokens(answer)
    if len(canonical_tokens) >= 2 and len(answer_tokens) == 1:
        return (
            "answer_boundary: repaired answer collapsed a multiword expression "
            "to one token"
        )
    return pack.surface_boundary_reason(
        answer=answer, sentence_target=sentence_target, canonical_form=canonical_form
    )


def _usable_expression_chunks(raw_chunks: Any, *, language: str) -> set[str]:
    """Keep learnable chunks only; proper names never become quiz answers.

    The model is asked for lowercase chunks, but this server-side rule makes the
    exclusion deterministic even when a model ignores that instruction.
    """
    chunks: set[str] = set()
    pack = target_pack(language)
    for item in raw_chunks or []:
        text = str(
            (item.get("canonical_form") or item.get("text"))
            if isinstance(item, dict)
            else item
        ).strip()
        kind = str(item.get("kind") if isinstance(item, dict) else "").strip().lower()
        key = _expression_key(text)
        if not key:
            continue
        if pack.proper_name_reason(text, kind):
            continue
        if pack.tautology_reason(text):
            continue
        chunks.add(key)
    return chunks


def _cloze_structural_reason(
    item: Any, raw_index: int, native_language: str = "korean", language: str = "english"
) -> str:
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
    matcher = target_pack(language).answer_boundary_re(blank)
    if "_" in completed or len(list(matcher.finditer(completed))) != 1:
        return f"candidate {raw_index}: " + R.reason(
            R.ANSWER_NOT_CONTIGUOUS,
            f"blank {blank!r} must be copied verbatim as one contiguous, inflected "
            "surface substring of sentence_en; rewrite sentence_en if necessary and "
            "do not return a dictionary form",
        )
    sentence_ko = str(item.get("sentence_ko") or "").strip()
    target_ko = str(item.get("target_ko") or "").strip()
    native_completed = sentence_ko
    native_markers = _BLANK_RUN_RE.findall(native_completed)
    if len(native_markers) == 1:
        native_completed = _BLANK_RUN_RE.sub(target_ko, native_completed, count=1)
    context_reason = target_pack(language).blank_context_reason(completed, blank)
    if context_reason:
        return f"candidate {raw_index}: " + context_reason
    native = native_quiz_pack(native_language)
    native_script = native.script_re
    if not native_script.search(sentence_ko):
        # Coded rather than free text: this one has to be countable in the eval
        # histogram, because a card it drops was already broken (its "문장 뜻"
        # was target-language text), and that has to be distinguishable from a
        # card genuinely lost to a tightened rule.
        return f"candidate {raw_index}: " + R.reason(
            R.WRONG_LANGUAGE,
            f"sentence_ko {sentence_ko[:60]!r} contains no {native.script_label} text; "
            f"sentence_ko must translate sentence_en into {native.script_label}, "
            "never repeat the target-language sentence",
        )
    if native_script.search(sentence_ko) and not native_script.search(target_ko):
        return f"candidate {raw_index}: " + R.reason(
            R.WRONG_LANGUAGE,
            f"native gloss {target_ko!r} is target-language text; it must be a "
            f"complete {native.script_label} gloss of the target answer",
        )
    if not target_ko:
        return f"candidate {raw_index}: " + R.reason(
            R.NATIVE_TARGET_MISALIGNMENT,
            f"the {native.script_label} answer gloss is required and must cover the "
            "whole target-language answer",
        )
    # Everything above mirrors a specific check in _normalize_bundle_cloze. The
    # remaining ones had no branch here, so every one of them collapsed into
    # the generic sentence below — which became the largest bucket in the eval
    # and said nothing about what to fix. Name them.
    pack = target_pack(language)
    length_reason = pack.sentence_length_reason(completed)
    if length_reason:
        return f"candidate {raw_index}: " + length_reason
    language_reason = pack.sentence_language_reason(completed)
    if language_reason:
        return f"candidate {raw_index}: " + language_reason
    if len(native_markers) > 1:
        return f"candidate {raw_index}: " + R.reason(
            R.NATIVE_TRANSLATION_MISSING,
            f"sentence_ko has {len(native_markers)} blank markers; it must be the "
            "complete native sentence with no blanks",
        )
    if "_" in native_completed:
        return f"candidate {raw_index}: " + R.reason(
            R.NATIVE_TRANSLATION_MISSING,
            "sentence_ko still contains an underscore; return the complete native "
            "sentence, not a fill-in-the-blank",
        )
    if native.generic_filler_re.search(native_completed):
        return f"candidate {raw_index}: " + R.reason(
            R.NATIVE_GENERIC_FILLER,
            f"sentence_ko {native_completed[:60]!r} is filler rather than a real "
            "translation; translate sentence_en concretely",
        )
    return f"candidate {raw_index}: " + R.reason(
        R.NATIVE_TARGET_MISALIGNMENT,
        "sentence_en and sentence_ko must be complete natural sentences with exactly "
        "one answer/translation alignment",
    )


def _prepare_cloze_candidates(
    items: list[Any],
    *,
    language: str,
    level: int,
    source_meta: dict[str, Any],
    expression_contracts: dict[str, dict[str, Any]] | None = None,
    native_language: str = "korean",
) -> tuple[list[dict[str, Any]], list[str]]:
    """Apply every deterministic guard and return actionable rejection reasons."""
    candidates: list[dict[str, Any]] = []
    reasons: list[str] = []
    seen_blanks: set[str] = set()
    for raw_index, item in enumerate(items[:6]):
        if not isinstance(item, dict):
            reasons.append(f"candidate {raw_index}: item is not an object")
            continue
        normalized = _normalize_bundle_cloze(item, language=language, native_language=native_language)
        if normalized is None:
            reasons.append(
                _cloze_structural_reason(item, raw_index, native_language, language)
            )
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
        # The teachability gate had been dead code: defined and unit-tested but
        # never called from the generation path, so answers its own tests call
        # unteachable ("the two reports", "their key results") still shipped.
        teachability_reason = target_pack(language).teachability_reason(blank)
        if teachability_reason:
            reasons.append(f"candidate {raw_index}: {teachability_reason}")
            continue
        gloss_reason = native_quiz_pack(native_language).gloss_scope_reason(
            str(item.get("target_ko") or "").strip(), str(contract.get("kind") or "")
        )
        if gloss_reason:
            reasons.append(f"candidate {raw_index}: {gloss_reason}")
            continue
        blank_key = blank.casefold()
        if blank_key in seen_blanks:
            reasons.append(f"candidate {raw_index}: duplicate answer {blank!r}")
            continue
        seen_blanks.add(blank_key)
        native = native_quiz_pack(native_language)
        question_ko = str(item.get("question_ko") or "").strip()
        if not question_ko:
            question_ko = native.default_question("cloze", _lang_label(language))
        aligned_native = str(item.get("target_ko") or "").strip()
        native_meaning = (
            aligned_native
            if native.script_re.search(aligned_native)
            else _native_expression_meaning(contract, native_language)
        )
        if native_meaning:
            question_ko = native.meaning_question(native_meaning)
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
        qd["_origin"] = str(item.get("_origin") or "author")
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


def _structural_feedback_by_expression(
    items: list[dict[str, Any]],
    *,
    chunks: list[dict[str, Any]],
    language: str,
    level: int,
    native_language: str,
    sink: list[str] | None = None,
) -> dict[str, list[str]]:
    """Turn deterministic failures into targeted author-repair instructions.

    ``sink`` collects the same reasons for the trace. Without it the eval's
    gate histogram sees only the final structural pass, so a gate that fires
    here — drives a repair, and is then satisfied — is invisible, which reads
    in a report as "the gate never fired" rather than "the gate worked".
    """
    contracts = {str(chunk.get("expression_id")): chunk for chunk in chunks}
    feedback: dict[str, list[str]] = {}
    for item in items:
        expression_id = str(item.get("expression_id") or "")
        candidates, reasons = _prepare_cloze_candidates(
            [item],
            language=language,
            level=level,
            source_meta={"validation_only": True},
            expression_contracts=contracts,
            native_language=native_language,
        )
        if not candidates:
            feedback[expression_id] = reasons or ["structural_validation_failed"]
            if sink is not None:
                sink.extend(reasons)
    return feedback


async def _author_individual_cloze_items(
    chunks: list[dict[str, Any]],
    *,
    source_statement: str,
    native_language: str,
    target_language: str,
    level: int,
    model: str,
    timeout: float,
    feedback: dict[str, list[str]] | None = None,
) -> tuple[list[dict[str, Any]], list[str], list[dict[str, Any]]]:
    """Align one expression to frozen bilingual sentences, with bounded concurrency."""
    native_label = _lang_label(native_language)
    target_label = _lang_label(target_language)
    profile = get_quiz_prompt_profile(native_language, target_language)
    base_system = _build_cloze_system_prompt(
        native_label,
        target_label,
        level,
        lang_guide(target_language),
        target_language,
        native_language,
    ) + (
        f" This request contains exactly ONE expression. Return exactly one alignment using {profile.target_answer_field} and "
        f"{profile.native_gloss_field}. The target answer must focus on that expression alone and occur exactly once in the frozen target sentence. "
        "Repair feedback is binding. semantic_scope_mismatch or part_of_speech_mismatch means the native gloss must cover the entire target answer "
        "as the same kind of constituent, including its action, head noun, required object, modifiers, negation, and aspect."
    )
    sibling_names = [str(chunk.get("canonical_form") or "") for chunk in chunks]
    semaphore = asyncio.Semaphore(3)

    async def author(chunk: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None, dict[str, Any]]:
        expression_id = str(chunk.get("expression_id") or "")
        forbidden = [name for name in sibling_names if name != chunk.get("canonical_form")]
        references = chunk.get("reference_answers") or []
        reference_text = str(
            (references[0] if references and isinstance(references[0], dict) else {}).get("text")
            or ""
        ).strip()
        source_text = str(chunk.get("source_segment") or "").strip()
        # Keep legacy persistence names out of the model request. In en->ko,
        # sentence_ko/target_ko reverse linguistic roles and previously induced
        # Korean text in the explicitly English gloss field.
        payload = {
            "source_statement": source_statement,
            f"frozen_{profile.native_language}_sentence": source_text,
            f"frozen_{profile.target_language}_sentence": reference_text,
            "expression_contract": {
                f"canonical_{profile.target_language}": str(chunk.get("canonical_form") or ""),
                f"planned_surface_{profile.target_language}": str(chunk.get("surface_form") or ""),
                f"meaning_{profile.native_language}": _native_expression_meaning(
                    chunk, native_language
                ),
                "kind": str(chunk.get("kind") or ""),
                "meaning_parts": list(chunk.get("meaning_parts") or []),
            },
            "forbidden_inside_target_answer": forbidden,
            "repair_feedback": list((feedback or {}).get(expression_id) or []),
        }
        try:
            async with semaphore:
                response = await _client().chat.completions.create(
                    model=model,
                    messages=[
                        {"role": "system", "content": base_system},
                        {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
                    ],
                    **_temperature_args(model, 0.2 if not payload["repair_feedback"] else 0.1),
                    response_format=_cloze_alignment_response_format(profile),
                    timeout=timeout,
                )
            raw = json.loads(response.choices[0].message.content or "{}")
            alignments = [item for item in (raw.get("alignments") or []) if isinstance(item, dict)]
            if len(alignments) != 1:
                return None, f"{expression_id}: author returned {len(alignments)} alignments", _usage_payload(response)
            alignment = dict(alignments[0])
            card = {
                "expression_id": expression_id,
                "canonical_form": str(chunk.get("canonical_form") or ""),
                "surface_answer": str(alignment.get(profile.target_answer_field) or "").strip(),
                "sentence_target": reference_text,
                # Legacy persistence names; values are directionally explicit
                # in the model schema and mapped only after the response.
                "sentence_ko": source_text,
                "target_ko": str(alignment.get(profile.native_gloss_field) or "").strip(),
                "question_ko": native_quiz_pack(native_language).default_question(
                    "cloze", target_label
                ),
            }
            card["expression_id"] = expression_id
            return card, None, _usage_payload(response)
        except Exception as exc:
            logger.warning("Individual cloze author failed expression=%s: %s", expression_id, exc)
            return None, f"{expression_id}: author request failed", {}

    results = await asyncio.gather(*(author(chunk) for chunk in chunks))
    items = [item for item, _, _ in results if item is not None]
    errors = [error for _, error, _ in results if error]
    usages = [usage for _, _, usage in results if usage]
    return items, errors, usages


async def _review_cloze_quality(
    items: list[dict[str, Any]],
    *,
    chunks: list[dict[str, Any]],
    native_language: str,
    target_language: str,
    model: str,
    timeout: float,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """Review a whole set cheaply so cross-card repetition is also visible."""
    if not items:
        return {}, {}
    system = _build_cloze_qa_system_prompt(
        _lang_label(native_language),
        _lang_label(target_language),
        native_language,
        target_language,
    )
    contracts = {str(chunk.get("expression_id")): chunk for chunk in chunks}
    payload = {
        "cards": [
            {
                "card": _review_cloze_view(item),
                "contract": contracts.get(str(item.get("expression_id")), {}),
            }
            for item in items
        ]
    }
    response = await _client().chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
        ],
        **_temperature_args(model, 0),
        response_format=_CLOZE_QA_RESPONSE_FORMAT,
        timeout=timeout,
    )
    raw = json.loads(response.choices[0].message.content or "{}")
    reviews = {
        str(review.get("expression_id")): review
        for review in (raw.get("reviews") or [])
        if isinstance(review, dict) and review.get("expression_id")
    }
    return reviews, _usage_payload(response)


def _cloze_from_reviewed_expression(
    chunk: dict[str, Any], *, native_language: str, target_language: str
) -> dict[str, Any] | None:
    """Build the primary cloze candidate from a reviewed, frozen sentence pair.

    This is not recovery behavior: the reviewed sentence and its exact expression
    span are the source of truth.  An LLM author is used only to repair an invalid
    alignment, never to regenerate either sentence.
    """
    answer = str(chunk.get("surface_form") or chunk.get("canonical_form") or "").strip()
    references = chunk.get("reference_answers") or []
    sentence = str(
        (references[0].get("text") if references and isinstance(references[0], dict) else "")
        or ""
    ).strip()
    native_sentence = str(chunk.get("source_segment") or "").strip()
    native_gloss = _native_expression_meaning(chunk, native_language)
    pack = target_pack(target_language)
    if not answer or not sentence or not pack.contains_span(sentence, answer):
        return None
    if not native_sentence or not native_gloss:
        return None
    return {
        "expression_id": str(chunk.get("expression_id") or ""),
        "canonical_form": str(chunk.get("canonical_form") or answer),
        "surface_answer": answer,
        "question_ko": _default_question_ko("cloze", target_language),
        "sentence_ko": native_sentence,
        "target_ko": native_gloss,
        "sentence_target": sentence,
    }


async def generate_quiz_bundle(
    session: AsyncSession,
    user: User,
    *,
    language: str,
    exclude_node_ids: set[str] | None = None,
    seed_node_ids: set[str] | None = None,
    generation_version: str | None = None,
    allow_existing_expressions: bool = False,
    materialize_cloze: bool = True,
    synthesize_audio: bool = True,
) -> tuple[list[Quiz], dict]:
    """Generate composition units and expression clozes from one Statement.

    Returns (created_quizzes, trace). Raises :class:`BundleSeedError` when the
    learner has no usable Statement yet.
    """
    from .languages import is_supported_pair

    settings = get_settings()
    language = (language or "english").lower()
    native_language = (getattr(user, "native_language", None) or "korean").lower()
    author_model, quality_model = _quiz_role_models(settings, native_language, language)
    if not is_supported_pair(native_language, language):
        raise BundleSeedError(
            f"unsupported language pair: native={native_language!r} target={language!r}"
        )
    native_label = _lang_label(native_language)
    target_label = _lang_label(language)
    profile = get_quiz_prompt_profile(native_language, language)
    plan_response_format = _plan_response_format(profile)
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
    if native_language == "english":
        source_units = _merge_english_leading_fragments(source_units)
    if not source_units:
        raise BundleSeedError("퀴즈를 만들 수 있는 문장이 없어요.")
    system = _build_plan_system_prompt(
        native_label, target_label, level, lang_guide(language), language, native_language
    )
    # Who this Statement is about, straight from the graph (speaker + mentioned
    # identities). Told to the planner so it can keep the names in
    # context_entities, and enforced below whatever the planner does with them.
    entity_guard = (
        await build_statement_entity_guard(session, user.id, seed_nodes[0])
        if seed_nodes
        else EntityNameGuard([])
    )
    user_content = json.dumps(
        {
            "source_statement": str(seed.get("content_ko") or ""),
            "forbidden_entities": sorted(entity_guard.native),
            "composition_units": [
                {
                    "segment_index": index,
                    "source_text": text,
                    "semantic_guardrails": _source_semantic_guardrails(
                        text, language, native_language=native_language
                    ),
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
        **_temperature_args(settings.openai_model, 0.35),
        response_format=plan_response_format,
        timeout=settings.openai_timeout_sec,
    )
    raw = _normalize_plan_language_fields(
        json.loads(resp.choices[0].message.content or "{}"), profile
    )
    raw_segments = raw.get("segments") or []
    # Backward-compatible parsing keeps in-flight older model responses visible.
    if not raw_segments and isinstance(raw.get("composition"), dict):
        old_comp = raw["composition"]
        raw_segments = [{
            "segment_index": 0,
            "reference_answers": old_comp.get("model_answers") or [],
            "expressions": raw.get("expression_chunks") or [],
        }]
    # Normalise legacy/in-flight plans and fail closed on invented source spans.
    # The planner may split one punctuation span into several semantic units,
    # so its final ordered units, rather than the preliminary splitter, drive
    # composition creation from this point onward.
    original_statement = str(seed.get("content_ko") or "").strip()
    planned_segments: list[dict[str, Any]] = []
    for order, raw_segment in enumerate(raw_segments[:4]):
        if not isinstance(raw_segment, dict):
            continue
        old_index = raw_segment.get("segment_index")
        fallback_source = (
            source_units[old_index]
            if isinstance(old_index, int) and 0 <= old_index < len(source_units)
            else (source_units[order] if order < len(source_units) else original_statement)
        )
        source_text = str(raw_segment.get("source_text") or fallback_source).strip()
        if not source_text or source_text not in original_statement:
            source_text = fallback_source
        prompt_native = str(raw_segment.get("prompt_native") or source_text).strip()
        segment = dict(raw_segment)
        segment.update({
            "segment_index": order,
            "source_text": source_text,
            "prompt_native": prompt_native or source_text,
            "grammar_focus": list(raw_segment.get("grammar_focus") or []),
            "context_entities": list(raw_segment.get("context_entities") or []),
        })
        planned_segments.append(segment)
    raw_segments = planned_segments
    semantic_normalizations = _normalize_unlicensed_detail_comparatives(
        raw_segments, source_units, language, native_language=native_language
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
            "usage": _usage_payload(resp),
        },
        artifacts=[("bundle_plan.json", raw, "application/json")],
    )

    plan_release_reviewed = False
    plan_review_model = ""
    plan_qa_step = tracer.begin_step(
        "bundle_plan_quality_review", "llm", phase="quiz_path",
        input_data={"proposed_segment_count": len(raw_segments)},
    )
    plan_qa_step.model = quality_model
    plan_qa_system = _build_plan_qa_system_prompt(
        native_label, target_label, level, language, native_language
    )
    plan_qa_step.system_prompt = plan_qa_system
    planner_segment_count = len(raw_segments)
    try:
        plan_qa_response = await _client().chat.completions.create(
            model=quality_model,
            messages=[
                {"role": "system", "content": plan_qa_system},
                {"role": "user", "content": json.dumps({
                    "source_statement": str(seed.get("content_ko") or ""),
                    "proposed_plan": {"segments": raw_segments},
                }, ensure_ascii=False)},
            ],
            **_temperature_args(quality_model, 0),
            response_format=plan_response_format,
            timeout=settings.openai_timeout_sec,
        )
        reviewed_plan = _normalize_plan_language_fields(
            json.loads(plan_qa_response.choices[0].message.content or "{}"), profile
        )
        reviewed_segments = list(reviewed_plan.get("segments") or [])
        collapsed_long_plan = _review_collapses_long_plan(
            original_statement, planner_segment_count, len(reviewed_segments)
        )
        incomplete_reviewed_plan = _plan_has_incomplete_units(
            reviewed_segments,
            native_language=native_language,
            target_language=language,
        )
        domain_contract_reason = _plan_domain_contract_reason(
            original_statement,
            reviewed_segments,
            native_language=native_language,
            target_language=language,
        )
        needs_segmentation_repair = (
            collapsed_long_plan or incomplete_reviewed_plan or bool(domain_contract_reason)
        )
        collapse_repaired = False
        plan_repair_usage: dict[str, Any] = {}
        if needs_segmentation_repair:
            try:
                repair_response = await _client().chat.completions.create(
                    model=quality_model,
                    messages=[
                        {"role": "system", "content": plan_qa_system},
                        {"role": "user", "content": json.dumps({
                            "source_statement": original_statement,
                            "proposed_plan": {"segments": reviewed_segments},
                            "required_units": [
                                {"segment_index": index, "source_text": unit}
                                for index, unit in enumerate(source_units)
                            ],
                            "mandatory_repair": (
                                "The prior review collapsed or fragmented a long multi-predicate source. Return exactly one "
                                "segment for each required_units item, in that order, without overlap. Each prompt must "
                                "have its own complete main predicate; no cause-only fragment and no dangling connective. "
                                "For English native prompts, remove a leading so/but/and and attach an After/Before/While gerund "
                                "fragment to its following main clause. Every target reference must contain only the target language. "
                                f"Mandatory semantic contract: {domain_contract_reason or 'none beyond the supplied pair rules'}."
                            ),
                        }, ensure_ascii=False)},
                    ],
                    **_temperature_args(quality_model, 0),
                    response_format=plan_response_format,
                    timeout=settings.openai_timeout_sec,
                )
                plan_repair_usage = _usage_payload(repair_response)
                repaired_plan = _normalize_plan_language_fields(
                    json.loads(repair_response.choices[0].message.content or "{}"), profile
                )
                repaired_segments = list(repaired_plan.get("segments") or [])
                if (
                    len(repaired_segments) == len(source_units)
                    and not _plan_has_incomplete_units(
                        repaired_segments,
                        native_language=native_language,
                        target_language=language,
                    )
                    and not _plan_domain_contract_reason(
                        original_statement,
                        repaired_segments,
                        native_language=native_language,
                        target_language=language,
                    )
                ):
                    reviewed_plan = repaired_plan
                    reviewed_segments = repaired_segments
                    collapse_repaired = True
            except Exception as repair_exc:
                logger.warning("Long plan collapse repair unavailable: %s", repair_exc)
        if reviewed_segments:
            # If the focused split still fails, keep the semantically complete
            # reviewed unit rather than reviving the planner's broken fragments.
            raw_segments = reviewed_segments
            final_plan_incomplete = _plan_has_incomplete_units(
                raw_segments,
                native_language=native_language,
                target_language=language,
                # A bad sibling expression must not invalidate the editor's
                # release decision for every other exact expression in the
                # same composition unit. Individual expression boundaries are
                # filtered below before provenance is attached.
                check_expressions=False,
            )
            final_domain_contract_reason = _plan_domain_contract_reason(
                original_statement,
                raw_segments,
                native_language=native_language,
                target_language=language,
            )
            plan_release_reviewed = not final_plan_incomplete and not (
                collapsed_long_plan and not collapse_repaired
            ) and not final_domain_contract_reason
            if plan_release_reviewed:
                plan_review_model = quality_model
            elif final_domain_contract_reason:
                # A known term rendered with the wrong concept poisons both
                # composition and cloze. Fail closed instead of publishing a
                # fluent but instructionally incorrect bundle.
                raw_segments = []
        tracer.finish_step(plan_qa_step, output={
            "segment_count": len(raw_segments),
            "long_plan_collapse_detected": collapsed_long_plan,
            "incomplete_plan_detected": incomplete_reviewed_plan,
            "domain_contract_reason": domain_contract_reason,
            "long_plan_collapse_repaired": collapse_repaired,
            "usage": {
                "review": _usage_payload(plan_qa_response),
                "repair": plan_repair_usage,
            },
        }, artifacts=[("bundle_plan_reviewed.json", reviewed_plan, "application/json")])
    except Exception as exc:
        logger.warning("Plan quality review unavailable: %s", exc)
        tracer.finish_step(plan_qa_step, error=f"{type(exc).__name__}: {exc}")

    reviewed_normalized: list[dict[str, Any]] = []
    for order, reviewed_segment in enumerate(raw_segments[:4]):
        if not isinstance(reviewed_segment, dict):
            continue
        source_text = str(reviewed_segment.get("source_text") or "").strip()
        if not source_text or source_text not in original_statement:
            source_text = source_units[min(order, len(source_units) - 1)]
        prompt_native = str(reviewed_segment.get("prompt_native") or source_text).strip()
        segment = dict(reviewed_segment)
        segment.update({
            "segment_index": order,
            "source_text": source_text,
            "prompt_native": prompt_native or source_text,
            "grammar_focus": list(reviewed_segment.get("grammar_focus") or []),
            "context_entities": list(reviewed_segment.get("context_entities") or []),
        })
        if native_language == "english" and language == "korean":
            segment["prompt_native"] = _composition_prompt_for_segment(segment)
            for answer in segment.get("reference_answers") or []:
                if not isinstance(answer, dict):
                    continue
                text = str(answer.get("text") or "").strip()
                answer["text"] = re.sub(
                    r"^(?:그래서|하지만|그리고)\s+",
                    "",
                    text,
                    count=1,
                )
        reviewed_normalized.append(segment)
    raw_segments = reviewed_normalized

    # Planning and translation are a different cognitive task from selecting
    # compact reusable expressions. If the reviewed plan lost a unit's useful
    # predicate or merged sibling actions into one invalid target, run one
    # focused inventory pass. This is adaptive: simple plans pay no extra call.
    proposed_expression_chunks = [
        {
            **item,
            "canonical_form": str(item.get("canonical_form") or item.get("text") or "").strip(),
            "quality_score": int(item.get("quality_score") or 80),
            "segment_index": segment_index,
            "expression_id": f"{segment_index}:{item_index}",
        }
        for segment_index, segment in enumerate(raw_segments)
        for item_index, item in enumerate(segment.get("expressions") or [])
        if isinstance(item, dict)
    ]
    usable_expression_count = len(_select_quality_expression_chunks(
        proposed_expression_chunks, language=language, limit=6, native_language=native_language
    ))
    target_language_pack = target_pack(language)
    segment_references = {
        index: [
            str(answer.get("text") or "").strip()
            for answer in segment.get("reference_answers") or []
            if isinstance(answer, dict)
        ]
        for index, segment in enumerate(raw_segments)
        if isinstance(segment, dict)
    }
    has_invalid_expression_alignment = any(
        bool(str(item.get("surface_form") or "").strip())
        and (
            not any(
                target_language_pack.contains_span(
                    reference, str(item.get("surface_form") or "").strip()
                )
                for reference in segment_references.get(int(item.get("segment_index") or 0), [])
            )
            or bool(target_language_pack.teachability_reason(str(item.get("surface_form") or "")))
        )
        for item in proposed_expression_chunks
    )
    native_script = _native_script_re(native_language)
    has_non_native_meaning = any(
        not native_script.search(str(item.get("meaning") or ""))
        or any(
            not native_script.search(str(part.get("native") or ""))
            for part in item.get("meaning_parts") or []
            if isinstance(part, dict)
        )
        for item in proposed_expression_chunks
    )
    expression_count_by_segment: dict[int, int] = {}
    for item in proposed_expression_chunks:
        segment_index = int(item.get("segment_index") or 0)
        expression_count_by_segment[segment_index] = expression_count_by_segment.get(segment_index, 0) + 1
    has_undercovered_parallel_actions = any(
        (
            re.search(r"(?:면서|하며|뿐만 아니라|그리고)", str(segment.get("prompt_native") or segment.get("source_text") or ""))
            or re.search(
                r"\b(?:while|and also|as well as)\b",
                " ".join(
                    str(answer.get("text") or "")
                    for answer in segment.get("reference_answers") or []
                    if isinstance(answer, dict)
                ),
                re.IGNORECASE,
            )
        )
        and expression_count_by_segment.get(segment_index, 0) < 2
        for segment_index, segment in enumerate(raw_segments)
    )
    minimum_inventory = min(2, len(raw_segments))
    if len(raw_segments) and (
        usable_expression_count < minimum_inventory
        or has_non_native_meaning
        or has_undercovered_parallel_actions
        or has_invalid_expression_alignment
    ):
        inventory_step = tracer.begin_step(
            "bundle_expression_inventory_repair", "llm", phase="quiz_path",
            input_data={
                "segment_count": len(raw_segments),
                "usable_expression_count": usable_expression_count,
                "has_non_native_meaning": has_non_native_meaning,
                "has_undercovered_parallel_actions": has_undercovered_parallel_actions,
                "has_invalid_expression_alignment": has_invalid_expression_alignment,
            },
        )
        inventory_step.model = quality_model
        inventory_system = _build_expression_inventory_system_prompt(
            native_label, target_label, level, language, native_language
        )
        inventory_step.system_prompt = inventory_system
        try:
            inventory_response = await _client().chat.completions.create(
                model=quality_model,
                messages=[
                    {"role": "system", "content": inventory_system},
                    {"role": "user", "content": json.dumps({"segments": raw_segments}, ensure_ascii=False)},
                ],
                **_temperature_args(quality_model, 0),
                response_format=plan_response_format,
                timeout=settings.openai_timeout_sec,
            )
            inventory_plan = _normalize_plan_language_fields(
                json.loads(inventory_response.choices[0].message.content or "{}"), profile
            )
            inventory_by_index = _inventory_expressions_by_index(
                list(inventory_plan.get("segments") or [])
            )
            for segment_index, segment in enumerate(raw_segments):
                if inventory_by_index.get(segment_index):
                    segment["expressions"] = inventory_by_index[segment_index]
            tracer.finish_step(inventory_step, output={
                "expression_count": sum(len(segment.get("expressions") or []) for segment in raw_segments),
                "usage": _usage_payload(inventory_response),
            }, artifacts=[("bundle_expression_inventory.json", inventory_plan, "application/json")])
        except Exception as exc:
            logger.warning("Expression inventory repair unavailable: %s", exc)
            tracer.finish_step(inventory_step, error=f"{type(exc).__name__}: {exc}")

    _trim_overlapping_segment_sources(raw_segments)

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
    for segment_index, segment in enumerate(raw_segments):
        prompt = _composition_prompt_for_segment(segment)
        source_text = str(segment.get("source_text") or prompt).strip()
        if not prompt:
            continue
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
            reference_text = str(
                (references[0] if references and isinstance(references[0], dict) else {}).get("text")
                or ""
            )
            if language == "german" and reference_text:
                chunk = _normalize_german_frozen_expression(chunk, reference_text)
            canonical = str(chunk.get("canonical_form") or chunk.get("text") or "").strip()
            key_set = _usable_expression_chunks([chunk], language=language)
            key = _expression_key(canonical)
            # Small planners occasionally leave canonical_form in the source
            # language even though surface_form is a valid target-language
            # realization copied from the reviewed reference. Recover that
            # trusted target span deterministically instead of paying another
            # model call or silently dropping the best expression.
            if key not in key_set or not target_pack(language).is_valid_blank(canonical):
                surface_candidate = str(chunk.get("surface_form") or "").strip()
                candidate_chunk = {**chunk, "canonical_form": surface_candidate}
                candidate_key = _expression_key(surface_candidate)
                if surface_candidate and candidate_key in _usable_expression_chunks(
                    [candidate_chunk], language=language
                ):
                    chunk = candidate_chunk
                    canonical = surface_candidate
                    key_set = {candidate_key}
                    key = candidate_key
            if key not in key_set or key in seen_expression_keys:
                continue
            # Names are not vocabulary. The graph knows who this Statement is
            # about, so a chunk that spells one of them ("es heißt eui-jun und
            # seung-hyun") or glosses one of them ("의준이 승현이다") is dropped
            # here regardless of what the planner scored it.
            entity_leak = entity_guard.reason(
                target=f"{canonical} {chunk.get('surface_form') or ''}",
                native=_native_expression_meaning(chunk, native_language),
            )
            if entity_leak:
                logger.info("expression rejected (%s): %s", entity_leak, canonical)
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
                "source_segment": source_text,
                "meaning": _native_expression_meaning(chunk, native_language),
                "semantic_guardrails": _source_semantic_guardrails(
                    source_text, language, native_language=native_language
                ),
                "reference_answers": references,
                "quality_score": int(chunk.get("quality_score") or 80),
                "quality_reason": str(chunk.get("quality_reason") or "").strip(),
                # The senior plan editor reviewed this exact frozen sentence,
                # expression boundary and bilingual gloss as one release unit.
                # Deferred cloze materialisation may therefore reuse that
                # decision instead of paying for the same semantic review again.
                "release_reviewed": plan_release_reviewed,
                "review_model": plan_review_model,
                "review_contract_version": (
                    _REVIEW_CONTRACT_VERSION if plan_release_reviewed else ""
                ),
            })
            seen_expression_keys.add(key)

    accepted_chunks = _select_quality_expression_chunks(
        accepted_chunks, language=language, limit=6, native_language=native_language
    )
    expression_keys = {
        _expression_key(str(chunk.get("canonical_form") or ""))
        for chunk in accepted_chunks
    }
    if seed_node_id and accepted_chunks:
        from .node_expression_store import save_node_expressions

        await save_node_expressions(
            user.id,
            str(seed_node_id),
            language,
            [
                {
                    # The expression shown on the composition node is the same
                    # exact span the learner will type in the frozen sentence.
                    "expression": chunk.get("surface_form") or chunk["canonical_form"],
                    "canonical_form": chunk["canonical_form"],
                    "meaning": str(chunk.get("meaning") or "").strip(),
                    "example": str(
                        ((chunk.get("reference_answers") or [{}])[0]).get("text") or ""
                    ) if isinstance((chunk.get("reference_answers") or [{}])[0], dict) else "",
                    "surface_form": chunk.get("surface_form"),
                    "meaning_parts": chunk.get("meaning_parts") or [],
                    "kind": chunk.get("kind") or "",
                    "utility_score": _expression_utility_score(chunk),
                    "source_segment": chunk.get("source_segment") or "",
                    "reference_answers": chunk.get("reference_answers") or [],
                    "surface_segments": chunk.get("surface_segments") or [],
                    "release_reviewed": bool(chunk.get("release_reviewed")),
                    "review_model": str(chunk.get("review_model") or ""),
                    "review_contract_version": str(
                        chunk.get("review_contract_version") or ""
                    ),
                }
                for chunk in accepted_chunks
            ],
            node_name=str(seed.get("node_name") or seed.get("content_ko") or ""),
        )

    # Stage two isolates every expression in its own author request, then uses an
    # independent release editor to spot semantic and pedagogical defects.
    cloze_items: list[Any] = []
    quality_rejections: list[str] = []
    # Gate reasons raised while authoring/repairing, as opposed to the final
    # structural pass. Traced separately so a gate that fires and is then
    # repaired is still counted.
    repair_path_rejections: list[str] = []
    if accepted_chunks and materialize_cloze:
        cloze_step = tracer.begin_step(
            "bundle_cloze_from_reviewed_expressions", "policy", phase="quiz_path",
            input_data={
                "expression_count": len(accepted_chunks),
                "expressions": [chunk["canonical_form"] for chunk in accepted_chunks],
                "concurrency": 3,
            },
        )
        cloze_items = [
            item
            for chunk in accepted_chunks
            for item in [
                _cloze_from_reviewed_expression(
                    chunk, native_language=native_language, target_language=language
                )
            ]
            if item is not None
        ]
        author_errors = [
            f"{chunk.get('expression_id')}: reviewed expression is not an exact sentence span"
            for chunk in accepted_chunks
            if str(chunk.get("expression_id") or "") not in {
                str(item.get("expression_id") or "") for item in cloze_items
            }
        ]
        tracer.finish_step(
            cloze_step,
            output={"returned_count": len(cloze_items), "errors": author_errors, "usage": {}},
        )
        initial_cloze_items = list(cloze_items)

        qa_step = tracer.begin_step(
            "bundle_cloze_batch_quality_review", "llm", phase="quiz_path",
            input_data={"candidate_count": len(cloze_items)},
        )
        qa_step.model = quality_model
        reviews: dict[str, dict[str, Any]] = {}
        qa_usage: dict[str, Any] = {}
        repair_feedback = _structural_feedback_by_expression(
            cloze_items,
            chunks=accepted_chunks,
            language=language,
            level=level,
            native_language=native_language,
            sink=repair_path_rejections,
        )
        returned_ids = {str(item.get("expression_id") or "") for item in cloze_items}
        for chunk in accepted_chunks:
            expression_id = str(chunk.get("expression_id") or "")
            if expression_id not in returned_ids:
                repair_feedback.setdefault(expression_id, []).append(
                    "answer_not_contiguous: choose an exact useful span from the frozen target sentence"
                )
        reviewable_items = [
            item for item in cloze_items
            if str(item.get("expression_id")) not in repair_feedback
        ]
        chunks_by_review_id = {
            str(chunk.get("expression_id") or ""): chunk for chunk in accepted_chunks
        }
        needs_llm_review = [
            item for item in reviewable_items
            if not _has_reusable_release_review(
                chunks_by_review_id.get(str(item.get("expression_id") or ""), {})
            )
        ]
        reused_review_count = len(reviewable_items) - len(needs_llm_review)
        if needs_llm_review:
            try:
                reviews, qa_usage = await _review_cloze_quality(
                    needs_llm_review,
                    chunks=accepted_chunks,
                    native_language=native_language,
                    target_language=language,
                    model=quality_model,
                    timeout=settings.openai_timeout_sec,
                )
            except Exception as exc:
                quality_rejections.append(f"quality reviewer unavailable: {type(exc).__name__}")
        # Missing reviews (including a reviewer outage) are failures. Shipping
        # an unchecked card is worse than returning a smaller bundle.
        qa_feedback = _quality_feedback_for_items(needs_llm_review, reviews)
        for expression_id, issues in qa_feedback.items():
            repair_feedback.setdefault(expression_id, []).extend(issues)
        # Provenance, carried through to the saved card. Without it a bundle
        # that authored nothing and fell back for everything is indistinguishable
        # from one that authored cleanly — both just report "N cards". The
        # step-level counters cannot substitute: they count candidates ENTERING
        # a stage, while the saved cards are what survived several more gates,
        # so the two populations do not subtract.
        pass_items = [
            {**item, "_origin": "reviewed_plan"}
            for item in cloze_items
            if str(item.get("expression_id")) not in repair_feedback
        ]
        repaired: list[dict[str, Any]] = []
        repaired_reviews: dict[str, dict[str, Any]] = {}
        if repair_feedback:
            repair_chunks = [
                chunk for chunk in accepted_chunks
                if str(chunk.get("expression_id")) in repair_feedback
            ]
            repaired, repair_errors, repair_usage = await _author_individual_cloze_items(
                repair_chunks,
                source_statement=str(seed.get("content_ko") or ""),
                native_language=native_language,
                target_language=language,
                level=level,
                model=author_model,
                timeout=settings.openai_timeout_sec,
                feedback=repair_feedback,
            )
            quality_rejections.extend(repair_errors)
            repaired_feedback = _structural_feedback_by_expression(
                repaired,
                chunks=repair_chunks,
                language=language,
                level=level,
                native_language=native_language,
                sink=repair_path_rejections,
            )
            reviewable_repaired = [
                item for item in repaired
                if str(item.get("expression_id")) not in repaired_feedback
            ]
            repaired_review_usage: dict[str, Any] = {}
            try:
                repaired_reviews, repaired_review_usage = await _review_cloze_quality(
                    reviewable_repaired,
                    chunks=repair_chunks,
                    native_language=native_language,
                    target_language=language,
                    model=quality_model,
                    timeout=settings.openai_timeout_sec,
                )
            except Exception as exc:
                quality_rejections.append(
                    f"repair quality reviewer unavailable: {type(exc).__name__}"
                )
            for expression_id, issues in _quality_feedback_for_items(
                reviewable_repaired, repaired_reviews
            ).items():
                repaired_feedback.setdefault(expression_id, []).extend(issues)
            pass_items.extend(
                {**item, "_origin": "repair"}
                for item in repaired
                if str(item.get("expression_id")) not in repaired_feedback
            )
            quality_rejections.extend(
                f"{expression_id}: {'; '.join(issues)}"
                for expression_id, issues in repaired_feedback.items()
            )
            qa_usage = {
                "review": qa_usage,
                "repair": repair_usage,
                "repair_review": repaired_review_usage,
            }
        cloze_items = pass_items

        # A rewrite is still untrusted output. Re-run the deterministic contract
        # before counting its expression as emitted, otherwise one malformed
        # repair can occupy the slot and silently reduce the final card count.
        post_repair_feedback = _structural_feedback_by_expression(
            cloze_items,
            chunks=accepted_chunks,
            language=language,
            level=level,
            native_language=native_language,
            sink=repair_path_rejections,
        )
        if post_repair_feedback:
            cloze_items = [
                item for item in cloze_items
                if str(item.get("expression_id")) not in post_repair_feedback
            ]
            quality_rejections.extend(
                f"{expression_id}: {'; '.join(issues)}"
                for expression_id, issues in post_repair_feedback.items()
            )

        tracer.finish_step(qa_step, output={
            "review_count": len(reviews),
            "reused_plan_review_count": reused_review_count,
            "release_score": _CLOZE_RELEASE_SCORE,
            "fail_closed": True,
            "initial_candidates": initial_cloze_items,
            "initial_reviews": list(reviews.values()),
            "repair_candidates": repaired,
            "repair_reviews": list(repaired_reviews.values()),
            "repair_count": len(repair_feedback),
            "final_candidate_count": len(cloze_items),
            "issues": quality_rejections,
            "usage": qa_usage,
        })

    cloze_candidates, structural_reasons = _prepare_cloze_candidates(
        cloze_items,
        language=language,
        level=level,
        source_meta=base_source_meta,
        expression_contracts={
            str(chunk["expression_id"]): chunk for chunk in accepted_chunks
        },
        native_language=native_language,
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
            "meaning": str(
                candidate["spec"]["quiz_data"].get("target_ko")
                or chunk.get("meaning")
                or ""
            ),
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
        "repair_path_rejections": repair_path_rejections,
        "quality_rejections": quality_rejections,
        "llm_quality_gate": "individual_author_batch_review_repair",
    })
    if materialize_cloze and not any(q["quiz_type"] == "cloze" for q in to_create):
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
        if (
            spec["quiz_type"] == "cloze"
            and not allow_existing_expressions
            and identity in active_expression_keys
        ):
            logger.info(
                "Skipping existing vocabulary target: language=%s expression=%s",
                language,
                identity,
            )
            continue
        generation_identity = (
            f"{user.id}|{language}|{identity_scope}|{spec['quiz_type']}|{identity}"
        )
        if generation_version:
            generation_identity = f"{generation_identity}|{generation_version}"
        generation_key = hashlib.sha256(generation_identity.encode()).hexdigest()
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
        if spec["quiz_type"] == "cloze" and synthesize_audio:
            audio_url, answer_audio_url, tts_error = await synthesize_quiz_audio_assets(
                quiz.id,
                spec["quiz_type"],
                {"sentence_en": spec["sentence_en"], "quiz_data": spec["quiz_data"]},
                language=language,
            )
            if audio_url:
                quiz.quiz_data = {
                    **(quiz.quiz_data or {}),
                    "audio_url": audio_url,
                    **({"answer_audio_url": answer_audio_url} if answer_audio_url else {}),
                }
                await crud.sync_quiz_audio_links(session, [quiz])
                await session.commit()
                await session.refresh(quiz)
            elif tts_error:
                logger.warning("Bundle quiz audio unavailable for quiz=%s: %s", quiz.id, tts_error)
        created.append(quiz)
        if spec["quiz_type"] == "cloze":
            active_expression_keys.add(identity)

    return created, trace


async def materialize_expression_clozes(
    session: AsyncSession,
    user: User,
    *,
    node_id: str,
    language: str,
    expressions: list[dict[str, Any]] | None = None,
    limit: int = 8,
    generation_version: str | None = None,
) -> tuple[list[Quiz], dict]:
    """Turn already analysed wordbook entries into cloze cards.

    Unlike :func:`generate_quiz_bundle`, this never runs the composition/LLM
    planning pass again.  It is the deferred second stage used by the automatic
    queue and by an explicit wordbook selection.
    """
    from .node_expression_store import (
        list_available_node_expressions,
        set_expression_quiz_status,
    )

    language = (language or "english").lower()
    level = crud.get_language_level(user, language)
    native_language = (getattr(user, "native_language", None) or "korean").lower()
    native_label = _lang_label(native_language)
    target_label = _lang_label(language)
    node_uuid = uuid.UUID(str(node_id))
    source = next(
        (
            row for row in await crud.get_all_statement_nodes(session, user.id)
            if str(row.get("node_id")) == str(node_id)
        ),
        None,
    )
    if source is None:
        raise BundleSeedError("Statement node not found")
    picked = list(expressions or await list_available_node_expressions(user.id, str(node_id), language))[:max(1, min(limit, 8))]
    if not picked:
        return [], {"status": "no_available_expressions", "steps": []}

    names = [str(item.get("expression") or "") for item in picked]
    await set_expression_quiz_status(user.id, str(node_id), language, names, "generating")
    bundle_id = uuid.uuid4()
    tracer = PipelineTracer(bundle_id)
    tracer.run.current_phase = "quiz_materialize"
    tracer.run.status = "quiz_materialize"
    chunks: list[dict[str, Any]] = []
    for index, item in enumerate(picked):
        refs = item.get("reference_answers") or []
        if not refs and item.get("example"):
            refs = [{"text": str(item["example"])}]
        normalized_refs = [
            value if isinstance(value, dict) else {"text": str(value)}
            for value in refs
        ]
        segment = str(item.get("source_segment") or source.get("content_ko") or "")
        chunks.append({
            "expression_id": f"stored:{index}",
            "stored_expression": str(item.get("expression") or "").strip(),
            "canonical_form": str(item.get("canonical_form") or item.get("expression") or "").strip(),
            "surface_form": str(item.get("surface_form") or item.get("expression") or "").strip(),
            "surface_segments": item.get("surface_segments") or [],
            "meaning": str(item.get("meaning") or "").strip(),
            "meaning_parts": item.get("meaning_parts") or [],
            "kind": str(item.get("kind") or "collocation"),
            "excluded_native_terms": [],
            "excluded_target_terms": [],
            "segment_index": index,
            "source_segment": segment,
            "semantic_guardrails": _source_semantic_guardrails(
                segment, language, native_language=native_language
            ),
            "reference_answers": normalized_refs,
            "release_reviewed": bool(item.get("release_reviewed")),
            "review_model": str(item.get("review_model") or ""),
            "review_contract_version": str(
                item.get("review_contract_version") or ""
            ),
        })
    step = tracer.begin_step(
        "deferred_cloze_from_reviewed_expressions", "policy", phase="quiz_materialize",
        input_data={"node_id": str(node_id), "expression_count": len(chunks), "expressions": names},
    )
    settings = get_settings()
    author_model, quality_model = _quiz_role_models(settings, native_language, language)
    items = [
        item
        for chunk in chunks
        for item in [
            _cloze_from_reviewed_expression(
                chunk, native_language=native_language, target_language=language
            )
        ]
        if item is not None
    ]
    returned_ids = {str(item.get("expression_id") or "") for item in items}
    author_errors = [
        f"{chunk.get('expression_id')}: reviewed expression is not an exact sentence span"
        for chunk in chunks
        if str(chunk.get("expression_id") or "") not in returned_ids
    ]
    tracer.finish_step(step, output={"returned_count": len(items), "errors": author_errors, "usage": {}})

    quality_step = tracer.begin_step(
        "deferred_cloze_batch_quality_review", "llm", phase="quiz_materialize",
        input_data={"candidate_count": len(items)},
    )
    quality_step.model = quality_model
    quality_rejections: list[str] = []
    reviews: dict[str, dict[str, Any]] = {}
    qa_usage: dict[str, Any] = {}
    feedback = _structural_feedback_by_expression(
        items,
        chunks=chunks,
        language=language,
        level=level,
        native_language=native_language,
    )
    for chunk in chunks:
        expression_id = str(chunk.get("expression_id") or "")
        if expression_id not in returned_ids:
            feedback.setdefault(expression_id, []).append(
                "answer_not_contiguous: choose an exact useful span from the frozen target sentence"
            )
    reviewable_items = [
        item for item in items if str(item.get("expression_id")) not in feedback
    ]
    chunks_by_review_id = {
        str(chunk.get("expression_id") or ""): chunk for chunk in chunks
    }
    needs_llm_review = [
        item for item in reviewable_items
        if not _has_reusable_release_review(
            chunks_by_review_id.get(str(item.get("expression_id") or ""), {})
        )
    ]
    reused_review_count = len(reviewable_items) - len(needs_llm_review)
    if needs_llm_review:
        try:
            reviews, qa_usage = await _review_cloze_quality(
                needs_llm_review,
                chunks=chunks,
                native_language=native_language,
                target_language=language,
                model=quality_model,
                timeout=settings.openai_timeout_sec,
            )
        except Exception as exc:
            quality_rejections.append(f"quality reviewer unavailable: {type(exc).__name__}")
    qa_feedback = _quality_feedback_for_items(needs_llm_review, reviews)
    for expression_id, issues in qa_feedback.items():
        feedback.setdefault(expression_id, []).extend(issues)
    kept = [
        {**item, "_origin": "reviewed_plan"}
        for item in items
        if str(item.get("expression_id")) not in feedback
    ]
    if feedback:
        repair_chunks = [chunk for chunk in chunks if str(chunk.get("expression_id")) in feedback]
        repaired, repair_errors, repair_usage = await _author_individual_cloze_items(
            repair_chunks,
            source_statement=str(source.get("content_ko") or ""),
            native_language=native_language,
            target_language=language,
            level=level,
            model=author_model,
            timeout=settings.openai_timeout_sec,
            feedback=feedback,
        )
        quality_rejections.extend(repair_errors)
        repaired_feedback = _structural_feedback_by_expression(
            repaired,
            chunks=repair_chunks,
            language=language,
            level=level,
            native_language=native_language,
        )
        reviewable_repaired = [
            item for item in repaired
            if str(item.get("expression_id")) not in repaired_feedback
        ]
        repaired_reviews: dict[str, dict[str, Any]] = {}
        repaired_review_usage: dict[str, Any] = {}
        try:
            repaired_reviews, repaired_review_usage = await _review_cloze_quality(
                reviewable_repaired,
                chunks=repair_chunks,
                native_language=native_language,
                target_language=language,
                model=quality_model,
                timeout=settings.openai_timeout_sec,
            )
        except Exception as exc:
            quality_rejections.append(
                f"repair quality reviewer unavailable: {type(exc).__name__}"
            )
        for expression_id, issues in _quality_feedback_for_items(
            reviewable_repaired, repaired_reviews
        ).items():
            repaired_feedback.setdefault(expression_id, []).extend(issues)
        kept.extend(
            {**item, "_origin": "repair"} for item in repaired
            if str(item.get("expression_id")) not in repaired_feedback
        )
        quality_rejections.extend(
            f"{expression_id}: {'; '.join(issues)}"
            for expression_id, issues in repaired_feedback.items()
        )
        qa_usage = {
            "review": qa_usage,
            "repair": repair_usage,
            "repair_review": repaired_review_usage,
        }
    items = kept
    post_repair_feedback = _structural_feedback_by_expression(
        items,
        chunks=chunks,
        language=language,
        level=level,
        native_language=native_language,
    )
    if post_repair_feedback:
        items = [
            item for item in items
            if str(item.get("expression_id")) not in post_repair_feedback
        ]
        quality_rejections.extend(
            f"{expression_id}: {'; '.join(issues)}"
            for expression_id, issues in post_repair_feedback.items()
        )
    tracer.finish_step(quality_step, output={
        "review_count": len(reviews),
        "reused_plan_review_count": reused_review_count,
        "release_score": _CLOZE_RELEASE_SCORE,
        "fail_closed": True,
        "repair_count": len(feedback),
        "final_candidate_count": len(items),
        "issues": quality_rejections,
        "usage": qa_usage,
    })

    source_meta = {"node_id": str(node_id), "bundle_id": str(bundle_id), "mode": "statement", "language": language, "materialized": True}
    candidates, reasons = _prepare_cloze_candidates(
        items,
        language=language,
        level=level,
        source_meta=source_meta,
        expression_contracts={str(chunk["expression_id"]): chunk for chunk in chunks},
        native_language=native_language,
    )
    chunks_by_id = {str(chunk["expression_id"]): chunk for chunk in chunks}
    trace_step = tracer.begin_step("deferred_cloze_validation", "policy", phase="quiz_materialize", input_data={"candidate_count": len(items)})
    trace_step_output = {
        "accepted_count": len(candidates),
        "structural_rejections": reasons,
        "quality_rejections": quality_rejections,
        "llm_quality_gate": "individual_author_batch_review_repair",
    }
    tracer.finish_step(trace_step, output=trace_step_output)
    trace = tracer.finish(status="completed")
    created: list[Quiz] = []
    emitted: list[str] = []
    for candidate in candidates:
        chunk = chunks_by_id.get(str(candidate["expression_id"]))
        if chunk is None:
            continue
        expression_key = _expression_key(chunk["canonical_form"])
        existing = await session.scalar(
            select(Quiz).where(
                Quiz.user_id == user.id,
                Quiz.language == language,
                Quiz.quiz_type == "cloze",
                Quiz.queue_kind != "archived",
                Quiz.generation_key == hashlib.sha256(
                    f"{user.id}|{language}|vocabulary|cloze|{expression_key}".encode()
                ).hexdigest(),
            )
        )
        if existing is not None:
            emitted.append(chunk.get("stored_expression") or chunk["canonical_form"])
            continue
        spec = candidate["spec"]
        spec["quiz_data"].update({
            "canonical_form": chunk["canonical_form"],
            "surface_form": candidate["blank"],
            "meaning": str(
                spec["quiz_data"].get("target_ko")
                or chunk.get("meaning")
                or ""
            ),
            "meaning_parts": chunk["meaning_parts"],
            "source_segment": chunk["source_segment"],
            "surface_segments": chunk["surface_segments"],
        })
        identity = f"{user.id}|{language}|vocabulary|cloze|{expression_key}"
        if generation_version:
            identity = f"{identity}|{generation_version}"
        quiz = await crud.create_quiz(
            session,
            user_id=user.id,
            quiz_type="cloze",
            question_ko=spec["question_ko"],
            sentence_en=spec["sentence_en"],
            quiz_data=spec["quiz_data"],
            difficulty_level=level,
            queue_kind="new",
            language=language,
            source_nodes=[node_uuid],
            pipeline_trace=trace,
            debug_run_dir=tracer.debug_dir_relative,
            generation_key=hashlib.sha256(identity.encode()).hexdigest(),
        )
        created.append(quiz)
        emitted.append(chunk.get("stored_expression") or chunk["canonical_form"])

    if emitted:
        await set_expression_quiz_status(user.id, str(node_id), language, emitted, "emitted")
    rejected = [name for name in names if name not in emitted]
    if rejected:
        await set_expression_quiz_status(user.id, str(node_id), language, rejected, "available")
    return created, trace
