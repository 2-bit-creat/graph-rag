"""Unified quiz bundle — one LLM call turns a single Statement node into all four
quiz types at once, per target language.

Design goals (replaces the old per-type, expression-extraction pipeline):

- **One statement → one LLM call → a bundle of quizzes.** ``composition`` and
  ``scramble`` have exactly one natural form each (a sentence has one meaning and
  one word order), so we ask for one of each. ``cloze`` and ``mcq_nuance`` can
  target different key expressions in the same statement, so we allow a few
  variants per bundle.
- **No expression extraction.** The seed is the learner's own Statement content;
  quizzes are generated straight from it. Nothing is written back to the graph.
- **Reuse, not reinvent.** Word-quiz payloads run through the canonical
  :func:`quiz_generator.validate_quiz_payload` so scramble tokenization, cloze
  malheoboca hints, and mcq coherence checks behave exactly like before. The
  composition item mirrors :mod:`composition_quiz`'s ``quiz_data`` shape so the
  same submit/evaluate path grades it.
- **Cheap.** gpt-4o-mini, one call for 4–8 questions.
"""

from __future__ import annotations

import json
import random
import uuid
from functools import lru_cache
from typing import Any

from openai import AsyncOpenAI
from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .config import get_settings
from .level_guidelines import cefr_label, get_level_band
from .models import Quiz, User
from .pipeline_trace import PipelineTracer
from .quiz_generator import (
    _LANG_DISPLAY_NAMES,
    _default_question_ko,
    validate_quiz_payload,
)

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


def lang_guide(language: str) -> str:
    return LANG_GUIDES.get((language or "").lower(), LANG_GUIDES["english"])


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
) -> dict[str, Any] | None:
    """A random real Statement the learner wrote, long enough to drill.

    ``exclude_node_ids`` keeps recently-used statements out of rotation so the
    queue fills from across the whole diary instead of the same few sentences.
    """
    stmts = await crud.get_all_statement_nodes(session, user.id)
    usable = [s for s in stmts if len((s.get("content_ko") or "").strip()) >= 6]
    if not usable:
        return None
    if exclude_node_ids:
        fresh = [s for s in usable if s.get("node_id") not in exclude_node_ids]
        if fresh:
            usable = fresh
    return random.choice(usable)


_BUNDLE_SCHEMA_HINT = """{
  "composition": {
    "prompt": "<ONE natural sentence in the NATIVE language for the learner to translate>",
    "source_label": "<2-4 word native-language badge>",
    "target_expressions": ["<target-language expression the ideal answer uses>"],
    "glossary": [{"term": "<native proper noun/term>", "target": "<target spelling>"}],
    "hints": [{"note": "<native coaching>", "snippet": "<optional target word or empty>"}],
    "model_answers": [{"text": "<natural target answer>", "register": "casual|neutral|formal", "note": "<native nuance>"}],
    "key_expressions": [{"expression": "<target>", "meaning": "<native>", "example": "<target example>"}],
    "thinking_tip": "<one native line on how the target language frames this differently>"
  },
  "scramble": {"question_ko": "<native instruction>", "sentence_target": "<ONE natural target sentence, 4-10 words>"},
  "cloze": [{"question_ko": "<native instruction>", "sentence_target": "<target sentence CONTAINING the blank word>", "blank": "<the single target word to blank out, present verbatim in sentence_target>", "accepted_answers": ["<blank>", "<optional variant>"]}],
  "mcq": [{"prompt_ko": "<native context describing the situation>", "options": ["<target opt A>", "<opt B>", "<opt C>", "<opt D>"], "correct_index": 0, "explanation": "<native: why the correct option is most natural>"}]
}"""


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
        "Produce EXACTLY one 'composition' (translate the native sentence) and one "
        "'scramble' (a natural target sentence to reorder). Produce 1-3 'cloze' items "
        "and 1-3 'mcq' items, each targeting a DIFFERENT key expression or nuance from "
        "the statement — do not let two variants share the same answer word. "
        "For cloze, 'blank' MUST appear verbatim inside 'sentence_target'. For mcq, all "
        "four options must express the SAME situation set by 'prompt_ko'; exactly one is "
        "the most natural, the other three each carry one plausible flaw. "
        "Native-language fields (prompt, notes, prompt_ko, explanation, hints.note, "
        "glossary.term) MUST be in the native language; target-language fields "
        "(sentence_target, blank, options, model_answers.text, key_expressions.expression, "
        "hints.snippet) MUST be in the target language. "
        f"Respond ONLY with JSON of this exact shape: {_BUNDLE_SCHEMA_HINT}"
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


async def generate_quiz_bundle(
    session: AsyncSession,
    user: User,
    *,
    language: str,
    exclude_node_ids: set[str] | None = None,
) -> tuple[list[Quiz], dict]:
    """Generate all four quiz types from one Statement in a single LLM call.

    Returns (created_quizzes, trace). Raises :class:`BundleSeedError` when the
    learner has no usable Statement yet.
    """
    settings = get_settings()
    language = (language or "english").lower()
    native_language = (getattr(user, "native_language", None) or "korean").lower()
    native_label = _lang_label(native_language)
    target_label = _lang_label(language)
    level = crud.get_language_level(user, language)

    seed = await _pick_seed(session, user, exclude_node_ids)
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

    system = _build_system_prompt(native_label, target_label, level, lang_guide(language))
    system += (
        "\n\nPRODUCT RULE: Generate only one cloze word quiz. Do not generate or return "
        "composition, scramble, or multiple-choice content. The native-language "
        "meaning must be a complete sentence and must never be replaced by the "
        "target answer."
    )
    user_content = (
        "SEED — the learner wrote this in their diary (native language). Build the "
        f"quiz bundle from it, staying true to its meaning:\n「{seed.get('content_ko')}」"
    )
    step = tracer.begin_step(
        "bundle_llm_generate", "llm", phase="quiz_path",
        input_data={"language": language, "level": level},
    )
    step.model = settings.openai_model
    step.system_prompt = system
    resp = await _client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ],
        temperature=0.7,
        response_format={"type": "json_object"},
        timeout=settings.openai_timeout_sec,
    )
    raw = json.loads(resp.choices[0].message.content or "{}")
    tracer.finish_step(
        step,
        output={
            "cloze_variants": len(raw.get("cloze") or []),
            "mcq_variants": len(raw.get("mcq") or []),
            "has_composition": bool(raw.get("composition")),
            "has_scramble": bool(raw.get("scramble")),
        },
        artifacts=[("bundle.json", raw, "application/json")],
    )

    source_meta = {"node_id": seed_node_id, "bundle_id": str(bundle_id), "mode": "bundle"}
    to_create: list[dict] = []

    # cloze only: one focused word quiz per generation request.
    for item in (raw.get("cloze") or [])[:1]:
        if not isinstance(item, dict):
            continue
        sentence = str(item.get("sentence_target") or "").strip()
        blank = str(item.get("blank") or "").strip()
        if not sentence or not blank:
            continue
        # Build prompt_en with the blank marker so validate_quiz_payload's
        # non-freedom cloze branch has a "___" to anchor on.
        prompt_en = sentence
        if blank.lower() in sentence.lower():
            idx = sentence.lower().index(blank.lower())
            prompt_en = sentence[:idx] + "___" + sentence[idx + len(blank):]
        accepted = [str(a).strip() for a in (item.get("accepted_answers") or [blank]) if str(a).strip()]
        try:
            validated = validate_quiz_payload(
                "cloze",
                {
                    "question_ko": item.get("question_ko") or _default_question_ko("cloze", language),
                    "sentence_en": sentence,
                    "quiz_data": {
                        "prompt_en": prompt_en,
                        "blank": blank,
                        "accepted_answers": accepted or [blank],
                        "sentence_en": sentence,
                        "context_ko": str(item.get("context_ko") or "").strip(),
                        "hint_ko": str(item.get("hint_ko") or "").strip(),
                    },
                },
                target_level=level,
                target_language=language,
            )
            qd = dict(validated["quiz_data"])
            qd["language"] = language
            qd["_source"] = dict(source_meta)
            to_create.append({
                "quiz_type": "cloze",
                "question_ko": validated["question_ko"],
                "sentence_en": validated["sentence_en"],
                "quiz_data": qd,
            })
        except ValueError:
            continue

    trace = tracer.finish(status="completed")

    created: list[Quiz] = []
    for spec in to_create:
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
        )
        created.append(quiz)

    return created, trace
