"""English-thinking composition tutor (라이브아카데미式 드릴).

The tutor gives the learner a native-language sentence to render into the target
language, then coaches the attempt: it judges whether the attempt communicates,
offers natural rewrites with nuance, and surfaces the "why English thinks this
way" insight that a generic translation would miss.

What makes this different from a plain LLM tutor is *where the drill sentences
come from* and *what gets remembered*:

- Prompts are seeded from the user's own knowledge graph — the Korean sentences
  they actually wrote (``journal`` mode) or a fresh sentence engineered to reuse
  an expression they previously fumbled (``review`` mode). Self-referential
  material sticks far better than textbook examples.
- Drill sentences are NOT written back to the graph (they are practice, not
  lived facts). Only the expressions the learner got stuck on are saved — into a
  dedicated tutor vocabulary — closing the loop diary → graph → drill → vocab.

Everything here is stateless per request: the client echoes the drill context
back on evaluate, so no drill rows are persisted.
"""

from __future__ import annotations

import json
import random
import uuid
from functools import lru_cache
from typing import Any, Literal

from openai import AsyncOpenAI

from . import crud
from .config import get_settings
from .level_guidelines import cefr_label, get_level_band
from .models import User
from .user_vocab_store import list_tutor_expressions
from sqlalchemy.ext.asyncio import AsyncSession

# Reuse the canonical language-label map so tutor output naming never drifts from
# the quiz pipeline.
from .quiz_generator import _LANG_DISPLAY_NAMES
from .quiz_bundle import lang_guide as _lang_guide

SourceMode = Literal["journal", "review"]


class DrillSeedError(ValueError):
    """No usable seed material to generate a drill from (empty journal / vocab)."""


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


def _lang_label(language: str) -> str:
    return _LANG_DISPLAY_NAMES.get(language.lower(), language.title())


def _target_level(user: User, language: str) -> int:
    """Per-language level (falls back to the global current_level)."""
    levels = getattr(user, "language_levels", None) or {}
    lvl = levels.get(language)
    if isinstance(lvl, int) and 1 <= lvl <= 100:
        return lvl
    return user.current_level


def _native_language(user: User) -> str:
    return getattr(user, "native_language", "korean") or "korean"


def _level_line(level: int, target_label: str) -> str:
    band = get_level_band(level)
    return (
        f"Learner level: {level}/100 (CEFR {band.cefr}). "
        f"Target-language vocabulary scope: {band.vocabulary}; grammar scope: {band.grammar}. "
        f"Keep every {target_label} sentence you produce within roughly this level — "
        f"comprehensible input, never showing off with rare words."
    )


# ── Drill prompt selection ────────────────────────────────────────────────────

_DRILL_SCHEMA_HINT = (
    '{"prompt": "<one natural sentence in the NATIVE language for the learner to '
    'translate>", "source_label": "<short 2-4 word badge in the native language '
    'describing where this came from>", "target_expressions": ["<target-language '
    'expression the ideal answer would use>", "..."], "glossary": [{"term": '
    '"<proper noun or domain term appearing in the prompt, in the native '
    'language>", "target": "<how to write/say it in the TARGET language>"}], '
    '"hints": [{"note": "<coaching, in the NATIVE language>", "snippet": '
    '"<optional target-language word/phrase to try, or empty string>"}], '
    '"model_answers": [{"text": "<natural target-language answer>", '
    '"register": "casual|neutral|formal", "note": "<native-language nuance note>"}], '
    '"key_expressions": [{"expression": "<target-language>", "meaning": '
    '"<native-language>", "example": "<target-language example sentence>"}], '
    '"thinking_tip": "<one native-language line on how the target language frames '
    'this idea differently from a literal translation>"}'
)


async def _pick_journal_seed(
    session: AsyncSession,
    user: User,
    exclude_node_ids: set[str] | None = None,
) -> dict[str, Any] | None:
    """A random real Statement the user wrote, with Korean content long enough to drill.

    ``exclude_node_ids`` keeps recently-drilled statements out of rotation so
    repeated generation doesn't keep hitting the same sentences; when exclusion
    would empty the pool, it falls back to the full pool.
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


async def _pick_review_seed(user: User, language: str) -> dict[str, Any] | None:
    """A previously-confused expression to re-drill (reverse-engineered prompt)."""
    exprs = await list_tutor_expressions(user.id)
    same_lang = [e for e in exprs if (e.get("language") or "english") == language]
    pool = same_lang or exprs
    if not pool:
        return None
    return random.choice(pool)


# Prompt-side variation, rotated randomly per drill so repeated generation from
# the same seed pool still produces different sentences. Zero extra API cost.
_STYLE_FOCUS = [
    "recalling a past event (past tenses)",
    "describing an emotion or mood",
    "explaining a reason or cause",
    "a hypothetical or conditional twist (what if / if only)",
    "comparing two things or moments",
    "time expressions (before/after/while/by the time)",
    "expressing a plan or intention",
    "an opinion with a soft hedge (I feel like / it seems)",
]
_STYLE_REGISTER = ["casual", "neutral", "formal"]
_STYLE_LENGTH = [
    "one short, punchy sentence",
    "one sentence with two clauses (a complex sentence)",
]

_DIFFICULTY_LEVEL_SHIFT = {"easy": -10, "normal": 0, "hard": 12}

_STYLE_FOCUS_KO = {
    "recalling a past event (past tenses)": "과거 회상",
    "describing an emotion or mood": "감정 묘사",
    "explaining a reason or cause": "이유 설명",
    "a hypothetical or conditional twist (what if / if only)": "가정/조건",
    "comparing two things or moments": "비교",
    "time expressions (before/after/while/by the time)": "시간 표현",
    "expressing a plan or intention": "계획 말하기",
    "an opinion with a soft hedge (I feel like / it seems)": "의견 표현",
}


def _pick_style() -> dict[str, str]:
    focus = random.choice(_STYLE_FOCUS)
    return {
        "focus": focus,
        "focus_ko": _STYLE_FOCUS_KO.get(focus, focus),
        "register": random.choice(_STYLE_REGISTER),
        "length": random.choice(_STYLE_LENGTH),
    }


async def generate_drill(
    session: AsyncSession,
    user: User,
    *,
    language: str,
    source_mode: SourceMode = "journal",
    exclude_node_ids: set[str] | None = None,
    difficulty: str = "normal",
) -> dict[str, Any]:
    """Produce one drill: a native-language sentence to translate + hidden targets.

    Returns {drill_id, prompt, source_label, target_expressions, hints,
    model_answers, key_expressions, thinking_tip, source_mode, seed_node_id,
    style, difficulty, base_level}.
    ``target_expressions`` and model-answer fields are hidden from the learner
    until they submit an attempt. ``difficulty`` shifts only the prompt-level
    language scope; the caller stamps the queue row with ``base_level`` so the
    session level-window filter keeps serving it.
    """
    settings = get_settings()
    target_label = _lang_label(language)
    native_language = _native_language(user)
    native_label = _lang_label(native_language)
    base_level = _target_level(user, language)
    shift = _DIFFICULTY_LEVEL_SHIFT.get((difficulty or "normal").lower(), 0)
    level = max(1, min(100, base_level + shift))
    style = _pick_style()

    seed_kind = source_mode
    seed_node_id: str | None = None
    seed_block = ""

    if source_mode == "journal":
        seed = await _pick_journal_seed(session, user, exclude_node_ids)
        if seed is None:
            raise DrillSeedError("일기에서 출제할 문장이 없어요. 먼저 일기를 작성해 주세요.")
        seed_node_id = seed.get("node_id")
        seed_block = (
            "SEED — the learner actually wrote this in their diary (native "
            f"language). Turn it into ONE clean, self-contained sentence for "
            f"translation practice, staying true to its meaning:\n"
            f"「{seed.get('content_ko')}」"
        )
    elif source_mode == "review":
        seed = await _pick_review_seed(user, language)
        if seed is None:
            raise DrillSeedError("복습할 표현이 아직 없어요.")
        expr = seed.get("word") or seed.get("expression") or ""
        meaning = seed.get("meaning") or ""
        seed_block = (
            "SEED — the learner previously got stuck on this target-language "
            f"expression: 「{expr}」 (meaning: {meaning or 'n/a'}). Secretly design "
            "a fresh, natural native-language sentence whose most natural "
            "translation would use this expression. Do NOT reveal the expression "
            "in the prompt; include it in target_expressions."
        )
    else:
        raise DrillSeedError(f"지원하지 않는 출제 모드입니다: {source_mode}")

    system = (
        "You are a warm, encouraging language tutor running an 'English-thinking' "
        "style composition drill (the learner translates a native-language sentence "
        "into the target language, then gets coached). "
        f"NATIVE language: {native_label}. TARGET language: {target_label}. "
        f"{_level_line(level, target_label)} "
        f"TARGET-LANGUAGE TEACHING FOCUS: {_lang_guide(language)} "
        "Produce a single drill sentence that is natural, concrete, and worth "
        "practicing — avoid textbook blandness. "
        f"VARIATION for this drill (bend the seed toward it while staying true to "
        f"its meaning): focus on {style['focus']}; register: {style['register']}; "
        f"shape: {style['length']}. "
        "In 'glossary', list any PROPER NOUNS (people, places, org/product names) or "
        "domain-specific terms in the prompt that the learner likely can't render on "
        "their own, each with its target-language spelling/equivalent — so they aren't "
        "blocked before they start. Omit ordinary words. Empty list if none. "
        "In 'hints', give exactly three progressively stronger nudges (structure → "
        "key expression → near-skeleton). Each hint is an object with 'note' and "
        f"'snippet'. CRITICAL: 'note' is coaching written in {native_label} (the "
        f"learner's own language) and MUST NOT be in {target_label}. 'snippet' is an "
        f"optional short {target_label} word/phrase to try (or empty string). "
        "Also pre-generate 1-2 natural model answers in 'model_answers', the "
        "most important expressions in 'key_expressions', and one concise "
        "'thinking_tip'. These fields are answer-independent and will be reused "
        "during fast quiz review; do not wait for the learner's attempt to write them. "
        "Example when native=Korean, target=English: "
        '[{"note": "\\"~할 수 있다\\"를 어떻게 표현할지 생각해 보세요", "snippet": ""}, '
        '{"note": "핵심 동사를 떠올려 보세요", "snippet": "unveiled"}, '
        '{"note": "이렇게 문장을 시작해 보세요", "snippet": "You can check ..."}]. '
        f"Respond ONLY with JSON of the exact shape: {_DRILL_SCHEMA_HINT}. "
        f"'prompt', 'source_label', hint 'note', and glossary 'term' MUST be in {native_label}. "
        f"'target_expressions', hint 'snippet', glossary 'target', model answer "
        f"'text', key expression 'expression', and target-language examples MUST be in {target_label}. "
        f"Model-answer/key-expression notes and 'thinking_tip' MUST be in {native_label}."
    )

    resp = await _client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": seed_block},
        ],
        temperature=0.8,
        response_format={"type": "json_object"},
        timeout=settings.openai_timeout_sec,
    )
    data = json.loads(resp.choices[0].message.content or "{}")

    prompt = (data.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("드릴 생성에 실패했어요. 다시 시도해 주세요.")
    source_label = (data.get("source_label") or "").strip() or (
        "내 일기에서" if seed_kind == "journal" else "복습 표현"
    )
    targets = [
        str(t).strip() for t in (data.get("target_expressions") or []) if str(t).strip()
    ][:5]

    glossary: list[dict[str, str]] = []
    for item in data.get("glossary") or []:
        if isinstance(item, dict):
            term = str(item.get("term") or "").strip()
            tgt = str(item.get("target") or "").strip()
            if term and tgt:
                glossary.append({"term": term, "target": tgt})
    glossary = glossary[:6]

    hints: list[dict[str, str]] = []
    for h in data.get("hints") or []:
        if isinstance(h, dict):
            note = str(h.get("note") or "").strip()
            snippet = str(h.get("snippet") or "").strip()
            if note:
                hints.append({"note": note, "snippet": snippet})
        elif isinstance(h, str) and h.strip():  # back-compat with flat strings
            hints.append({"note": h.strip(), "snippet": ""})
    hints = hints[:3]

    def _clean_dict_list(items: Any, keys: tuple[str, ...], limit: int) -> list[dict[str, str]]:
        out: list[dict[str, str]] = []
        if isinstance(items, list):
            for it in items:
                if isinstance(it, dict):
                    cleaned = {k: str(it.get(k) or "").strip() for k in keys}
                    if any(cleaned.values()):
                        out.append(cleaned)
        return out[:limit]

    model_answers = [
        {"text": a["text"], "tone": a["register"], "note": a["note"]}
        for a in _clean_dict_list(
            data.get("model_answers"), ("text", "register", "note"), 2
        )
        if a.get("text")
    ]
    key_expressions = _clean_dict_list(
        data.get("key_expressions"), ("expression", "meaning", "example"), 6
    )
    thinking_tip = str(data.get("thinking_tip") or "").strip()

    return {
        "drill_id": str(uuid.uuid4()),
        "prompt": prompt,
        "source_label": source_label,
        "source_mode": seed_kind,
        "seed_node_id": seed_node_id,
        "target_expressions": targets,
        "glossary": glossary,
        "hints": hints,
        "model_answers": model_answers,
        "key_expressions": key_expressions,
        "thinking_tip": thinking_tip,
        "language": language,
        "level": level,
        "base_level": base_level,
        "difficulty": (difficulty or "normal").lower(),
        "style": style,
        "cefr": cefr_label(level),
    }


# ── Attempt evaluation ────────────────────────────────────────────────────────

_REFERENCE_EVAL_SCHEMA_HINT = (
    '{"verdict": "natural|understandable|awkward|off", '
    '"verdict_label": "<short native-language label>", '
    '"encouragement": "<one warm native-language line>", '
    '"attempt_note": "<native-language note on the learner attempt only>", '
    '"corrections": [{"issue": "<native-language issue>", "suggestion": '
    '"<target-language corrected phrase/sentence>", "note": "<native-language why>"}], '
    '"save_suggestions": [{"expression": "<target-language>", "meaning": '
    '"<native-language>", "example": "<target-language>", "reason": '
    '"<native-language: why this is worth saving>"}]}'
)


def _empty_eval(native_hint: str) -> dict[str, Any]:
    return {
        "verdict": "understandable",
        "verdict_label": "확인 완료",
        "encouragement": "좋아요, 계속 해봐요!",
        "natural_versions": [],
        "key_expressions": [],
        "thinking_tip": "",
        "save_suggestions": [],
    }


async def evaluate_attempt_against_reference(
    user: User,
    *,
    prompt: str,
    user_answer: str,
    language: str,
    model_answers: list[dict[str, Any]] | None = None,
    target_expressions: list[str] | None = None,
    key_expressions: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Evaluate only the learner-dependent part of a pre-generated drill.

    The prompt, ideal answers, key expressions, and thinking tip were already
    generated into the Quiz row. This call therefore only judges the attempt and
    proposes personalized save suggestions.
    """
    settings = get_settings()
    target_label = _lang_label(language)
    native_language = _native_language(user)
    native_label = _lang_label(native_language)
    level = _target_level(user, language)
    targets = [t for t in (target_expressions or []) if str(t).strip()]

    def _reference_lines() -> str:
        lines: list[str] = []
        for idx, ans in enumerate(model_answers or [], start=1):
            if isinstance(ans, dict) and (ans.get("text") or "").strip():
                lines.append(
                    f"{idx}. {ans.get('text')} "
                    f"({ans.get('tone') or ans.get('register') or 'neutral'}; "
                    f"{ans.get('note') or ''})"
                )
        return "\n".join(lines) or "(none)"

    key_line = "; ".join(
        f"{e.get('expression')} = {e.get('meaning')}"
        for e in (key_expressions or [])
        if isinstance(e, dict) and e.get("expression")
    )

    system = (
        "You are evaluating a composition-drill attempt against pre-generated "
        "reference answers. Do NOT generate a new drill or new model answer. "
        f"NATIVE language: {native_label}. TARGET language: {target_label}. "
        f"{_level_line(level, target_label)} "
        f"TARGET-LANGUAGE TEACHING FOCUS: {_lang_guide(language)} "
        "Judge communication generously first, then point out only learner-specific "
        "issues. 'corrections' should contain concrete fixes for the submitted "
        "attempt. 'save_suggestions' must list ONLY expressions the learner clearly "
        "did not know or got wrong. If the answer is already natural, it may be empty. "
        f"Respond ONLY with JSON of the exact shape: {_REFERENCE_EVAL_SCHEMA_HINT}."
    )
    content = (
        f"Native-language prompt: 「{prompt}」\n"
        f"Learner attempt ({target_label}): 「{user_answer}」\n"
        f"Reference answers ({target_label}):\n{_reference_lines()}\n"
        f"Target expressions: {', '.join(targets) or '(none)'}\n"
        f"Key expressions: {key_line or '(none)'}"
    )

    try:
        resp = await _client().chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": content},
            ],
            temperature=0.25,
            response_format={"type": "json_object"},
            timeout=settings.openai_timeout_sec,
        )
        data = json.loads(resp.choices[0].message.content or "{}")
    except Exception:  # noqa: BLE001
        return {
            **_empty_eval(native_label),
            "attempt_note": "",
            "corrections": [],
            "language": language,
        }

    def _clean_list(items: Any, keys: tuple[str, ...]) -> list[dict[str, str]]:
        out: list[dict[str, str]] = []
        if isinstance(items, list):
            for it in items:
                if isinstance(it, dict):
                    out.append({k: str(it.get(k) or "").strip() for k in keys})
        return out

    verdict = str(data.get("verdict") or "understandable").strip().lower()
    if verdict not in ("natural", "understandable", "awkward", "off"):
        verdict = "understandable"

    return {
        "verdict": verdict,
        "verdict_label": str(data.get("verdict_label") or "").strip(),
        "encouragement": str(data.get("encouragement") or "").strip(),
        "attempt_note": str(data.get("attempt_note") or "").strip(),
        "corrections": _clean_list(
            data.get("corrections"), ("issue", "suggestion", "note")
        ),
        "save_suggestions": _clean_list(
            data.get("save_suggestions"), ("expression", "meaning", "example", "reason")
        ),
        "language": language,
    }


# ── Follow-up chat ────────────────────────────────────────────────────────────


async def tutor_chat(
    user: User,
    *,
    messages: list[dict[str, str]],
    language: str,
    drill_prompt: str | None = None,
) -> str:
    """Free-form follow-up so the learner can ask 'why X and not Y?' after a drill."""
    settings = get_settings()
    target_label = _lang_label(language)
    native_language = _native_language(user)
    native_label = _lang_label(native_language)
    level = _target_level(user, language)

    system = (
        "You are a warm, concise language tutor. The learner is doing composition "
        f"drills. NATIVE language: {native_label}. TARGET language: {target_label}. "
        f"{_level_line(level, target_label)} "
        "Answer their follow-up questions about expressions, nuance, and usage. "
        f"Explain in {native_label}; give target-language examples in {target_label}. "
        "Keep answers short and practical — no lectures."
    )
    if drill_prompt:
        system += f" Current drill sentence they are working on: 「{drill_prompt}」."

    chat_messages: list[dict[str, str]] = [{"role": "system", "content": system}]
    for m in messages:
        role = m.get("role")
        text = (m.get("content") or "").strip()
        if role in ("user", "assistant") and text:
            chat_messages.append({"role": role, "content": text})

    if len(chat_messages) == 1:
        return ""

    try:
        resp = await _client().chat.completions.create(
            model=settings.openai_model,
            messages=chat_messages,
            temperature=0.4,
            timeout=settings.openai_timeout_sec,
        )
        return resp.choices[0].message.content or ""
    except Exception:  # noqa: BLE001
        return "지금은 답하기 어려워요. 잠시 후 다시 시도해 주세요."
