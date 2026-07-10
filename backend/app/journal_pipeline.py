"""Fast Path: Whisper STT + GPT cleanup/translation."""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

from openai import AsyncOpenAI

from .config import get_settings
from .language_config import lang_label, normalize_native

_LABEL_LINE_RE = re.compile(r"^\s*\[([^\]]+)\]\s*:?\s*(.*)$")
_SENT_SPLIT_RE = re.compile(r"(?<=[.!?。?！])\s+")

_WHISPER_LANG = {"korean": "ko", "english": "en"}

# Content-type categories emitted by cleanup LLM (native-language labels).
_CONTENT_TYPES_KO = ["일기", "대화", "회의록", "책", "뉴스", "강연", "논문"]
_CONTENT_TYPES_EN = [
    "diary",
    "conversation",
    "meeting_notes",
    "book",
    "news",
    "lecture",
    "paper",
]


def apply_cleaned_text_to_segments(
    segments: list[Any], transcript_clean_ko: str
) -> list[Any]:
    """Replace each diarization segment's raw text with its STT-corrected wording.

    The speaker-selection UI and the graph both read segment text, so this maps the
    cleaned transcript (마차→말차) back onto the segments. Only remaps when the
    cleaned text aligns 1:1 with the segments — by [Speaker] lines or, failing that,
    by sentence count — otherwise leaves segments untouched (never a risky guess).
    The original is preserved on `text_raw`.
    """
    clean = (transcript_clean_ko or "").strip()
    seg_dicts = [s for s in segments if isinstance(s, dict)]
    if not seg_dicts or not clean:
        return segments
    n = len(seg_dicts)

    # 1) Labeled lines: "[Speaker_1] text" / "[Speaker_1]: text".
    lines = [ln.strip() for ln in clean.splitlines() if ln.strip()]
    labeled = [_LABEL_LINE_RE.match(ln) for ln in lines]
    texts: list[str] | None = None
    if lines and all(labeled) and len(lines) == n:
        texts = [(m.group(2) or "").strip() for m in labeled]  # type: ignore[union-attr]
    else:
        # 2) Sentence-split fallback on the label-stripped text.
        flat = re.sub(r"\[[^\]]+\]\s*:?\s*", "", clean).strip()
        sentences = [s.strip() for s in _SENT_SPLIT_RE.split(flat) if s.strip()]
        if len(sentences) == n:
            texts = sentences

    if texts is None:
        return segments  # cannot map safely → keep raw

    out: list[Any] = []
    ti = 0
    for s in segments:
        if isinstance(s, dict) and ti < len(texts):
            copy = dict(s)
            if "text_raw" not in copy:
                copy["text_raw"] = copy.get("text", "")
            copy["text"] = texts[ti]
            out.append(copy)
            ti += 1
        else:
            out.append(s)
    return out

# Shared cleanup/classification rules — identical whether or not we translate.
def _cleanup_body(native_language: str = "korean") -> str:
    native = normalize_native(native_language)
    if native == "english":
        structure_note = (
            "- For one-speaker essays/notes, structure the cleaned English into readable short "
            "paragraphs when the input is dense: keep numbered items and headings on their "
            "own lines, and add paragraph breaks between distinct reasons, definitions, examples, "
            "or conclusions."
        )
        content_types = ", ".join(_CONTENT_TYPES_EN)
        diary_type = "diary"
        conv_type = "conversation"
        meeting_type = "meeting_notes"
        default_monologue = diary_type
        forbidden_multi = f"{conv_type}/{meeting_type}"
    else:
        structure_note = (
            "- For one-speaker essays/notes, structure the cleaned Korean into readable short "
            "paragraphs when the input is dense: keep numbered items and headings on their own "
            "lines, and add paragraph breaks between distinct reasons, definitions, examples, "
            "or conclusions."
        )
        content_types = ", ".join(_CONTENT_TYPES_KO)
        diary_type = "일기"
        conv_type = "대화"
        meeting_type = "회의록"
        default_monologue = diary_type
        forbidden_multi = f"{conv_type}/{meeting_type}"

    return f"""[STT CLEANUP]
Fix phonetic mishearings, fillers, and grammar. Apply real-world logic:
- Consumption verbs need edible/drinkable objects. If absurd, find the closest phonetic correction.
- Commerce verbs need purchasable objects. Movement verbs must match noun type.
- Unify cross-speaker references: if Speaker A makes X and Speaker B drinks X, both must use the same corrected word.

[SPEAKER LABELS]
- Keep [Speaker_N] labels unchanged in all outputs — never replace with names.
- One line per speaker turn; fix only the text, not the label.

[TEXT STRUCTURE]
- Preserve meaningful paragraph breaks from typed text. Do not collapse a multi-paragraph
  input into one long line.
{structure_note}
- For multi-speaker text, keep one line per speaker turn.

[CONTENT CLASSIFICATION]
Also classify the content so the app can suggest a type and detect over-split:
- "content_type": exactly one of [{content_types}].
  {diary_type} = personal first-person diary/monologue; {conv_type} = a conversation between people.
- "single_speaker": true ONLY if this is ONE first-person narrator talking (a personal
  diary/monologue). false for any real multi-person conversation or external source.
  Note: [Speaker_N] tags are automatic diarization labels, NOT proof of a real
  conversation. If only ONE distinct speaker actually talks, set single_speaker=true
  and choose a monologue type ({default_monologue} by default, or lecture/book/news/paper
  if it is clearly that medium) — never {forbidden_multi}."""


def build_cleanup_only_system_prompt(*, native_language: str = "korean") -> str:
    """Cleanup + classification only — NO translation."""
    native = normalize_native(native_language)
    native_label = lang_label(native)
    body = _cleanup_body(native)
    if native == "english":
        example_in = (
            'I came back after having dinner with a colleague, but my boss was not there...'
        )
        example_out = (
            '{"transcript_clean_ko": "I came back after having dinner with a colleague, '
            'but my boss was not there...", "content_type": "diary", "single_speaker": true}'
        )
    else:
        example_in = "당뇨랑 저녁을 먹고 와서 왔는데 상사가 없었어..."
        example_out = (
            '{"transcript_clean_ko": "동료랑 저녁을 먹고 돌아왔는데 상사가 없었어요...", '
            '"content_type": "일기", "single_speaker": true}'
        )
    return f"""You are a linguistic engine for {native_label} STT/text cleanup.

{body}

[OUTPUT FORMAT]
Respond with valid JSON only (no markdown). Keys:
- "transcript_clean_ko": refined {native_label} text, speaker labels preserved
- "content_type": one of the categories above
- "single_speaker": boolean

Example:
Input: "{example_in}"
Output: {example_out}"""


def build_cleanup_system_prompt(
    languages: list[str] | None = None,
    *,
    native_language: str = "korean",
) -> str:
    """Build the STT cleanup + translation system prompt for given target languages."""
    from .language_config import filter_target_languages, lang_label as _lang_label

    if not languages:
        languages = ["english"]
    languages = filter_target_languages(languages)

    native = normalize_native(native_language)
    native_label = lang_label(native)
    body = _cleanup_body(native)

    lang_map = {
        "english": ("en", "English"),
        "german": ("de", "German (Deutsch)"),
        "korean": ("ko", "Korean"),
    }
    lang_lines = "\n".join(
        f'  - "{code}": natural {label} translation'
        for lang in languages
        for code, label in [lang_map.get(lang, (lang[:2], _lang_label(lang)))]
    )

    example_translations: dict[str, str] = {}
    for lang in languages:
        code, _ = lang_map.get(lang, (lang[:2], _lang_label(lang)))
        if lang == "english":
            example_translations[code] = (
                "I came back after having dinner with a colleague, but my boss wasn't there..."
            )
        elif lang == "german":
            example_translations[code] = (
                "Ich bin nach dem Abendessen mit einem Kollegen zurückgekommen, "
                "aber mein Chef war nicht da..."
            )
        elif lang == "korean":
            example_translations[code] = (
                "동료랑 저녁을 먹고 돌아왔는데 상사가 없었어요..."
            )
    ex_json = "{" + ", ".join(f'"{k}": "{v}"' for k, v in example_translations.items()) + "}"

    if native == "english":
        example_in = (
            "I came back after having dinner with a colleague, but my boss was not there..."
        )
        example_clean = (
            "I came back after having dinner with a colleague, but my boss was not there..."
        )
        content_type = "diary"
    else:
        example_in = "당뇨랑 저녁을 먹고 와서 왔는데 상사가 없었어..."
        example_clean = "동료랑 저녁을 먹고 돌아왔는데 상사가 없었어요..."
        content_type = "일기"

    return f"""You are a linguistic engine for {native_label} STT cleanup and multilingual translation.

{body}

[OUTPUT FORMAT]
Respond with valid JSON only (no markdown). Keys:
- "transcript_clean_ko": refined {native_label}, speaker labels preserved
- "translations": object with ISO codes → natural idiomatic translation
- "content_type": one of the categories above
- "single_speaker": boolean
{lang_lines}

Example:
Input: "{example_in}"
Output: {{"transcript_clean_ko": "{example_clean}", "content_type": "{content_type}", "single_speaker": true, "translations": {ex_json}}}"""


# Default prompt (for pipeline_trace display and backward compat)
CLEANUP_SYSTEM_PROMPT = build_cleanup_system_prompt(["english", "german"])

# ─── Content-type gate ────────────────────────────────────────────────────────
# Speaker count is a hard structural signal the classification LLM tends to ignore
# (it sees [Speaker_N] diarization labels and drifts toward 대화). These sets let us
# reconcile the LLM's guess with the actual number of distinct speakers.

# Canonical display category for a personal single-speaker diary.
DIARY_CATEGORY = "개인일기"
DIARY_CATEGORY_EN = "personal_diary"
# Types that structurally require more than one speaker — never valid for a monologue.
_MULTI_SPEAKER_TYPES = {"대화", "회의록", "conversation", "meeting_notes"}
# Diary aliases that structurally require a single speaker.
_DIARY_ALIASES = {"일기", "개인일기", "diary", "personal_diary"}


# Default for external-source material that doesn't fit a traditional medium —
# AI 답변·요약·여러 출처를 섞은 노트 등 "정리된 참고 지식". 붙여넣기 출처의 기본값.
_SOURCE_FALLBACK_TYPE = "자료"
_SOURCE_FALLBACK_TYPE_EN = "reference"
_SOURCE_KEEP_TYPES = {"뉴스", "논문", "강연", "news", "paper", "lecture"}


def gate_source_type(
    content_type: str | None,
    *,
    single_speaker: bool,
    source_attributed: bool = False,
    native_language: str = "korean",
) -> str | None:
    """Reconcile the LLM's content_type guess with the real speaker count."""
    native = normalize_native(native_language)
    diary_cat = DIARY_CATEGORY_EN if native == "english" else DIARY_CATEGORY
    fallback = _SOURCE_FALLBACK_TYPE_EN if native == "english" else _SOURCE_FALLBACK_TYPE
    multi_default = "conversation" if native == "english" else "대화"

    ct = (content_type or "").strip()
    if source_attributed:
        return ct if ct in _SOURCE_KEEP_TYPES else fallback
    if single_speaker:
        if ct == "" or ct in _MULTI_SPEAKER_TYPES or ct in _DIARY_ALIASES:
            return diary_cat
        return ct
    if ct == "" or ct in _DIARY_ALIASES:
        return multi_default
    return ct

_MAX_CLEANUP_ATTEMPTS = 3

# Post-LLM sanity patterns — catch literal translations the model still misses.
_EN_IMPOSSIBLE_RE = re.compile(
    r"\b(drink|drank|drinking|eat|ate|eating|swallow|swallowed|taste|tasted)\b"
    r"[^.\n]{0,40}\b("
    r"carriage|cart|computer|laptop|phone|building|car|bus|train|person|friend|money|desk|chair"
    r")\b",
    re.IGNORECASE,
)
_KO_CONSUME_VERB_RE = re.compile(r"(마시|마실|먹|드시|섭취)")
_KO_MACHA_HOMOPHONE_RE = re.compile(r"마차")
_KO_MATCHA_CORRECTED_RE = re.compile(r"말차")


def _detect_cleanup_anomalies(
    source_text: str,
    transcript_clean_ko: str,
    translation_en: str,
    *,
    native_language: str = "korean",
) -> list[str]:
    """Return human-readable issues that should trigger a cleanup retry."""
    issues: list[str] = []
    native = normalize_native(native_language)

    if native == "korean":
        combined_ko = f"{source_text}\n{transcript_clean_ko}"
        if _KO_MACHA_HOMOPHONE_RE.search(combined_ko) and _KO_CONSUME_VERB_RE.search(combined_ko):
            if not _KO_MATCHA_CORRECTED_RE.search(transcript_clean_ko):
                issues.append(
                    "Korean lines use 마차 with a consumption verb (마시다/먹다) — "
                    "this must be corrected to 말차 (matcha tea), not carriage (수레)."
                )

    if translation_en and _EN_IMPOSSIBLE_RE.search(translation_en):
        issues.append(
            "English translation contains a physically impossible consumption action "
            "(e.g. drink/eat + carriage/computer/person). "
            "Re-read the source dialogue, fix the STT homophone in transcript_clean_ko, "
            "then re-translate."
        )

    if translation_en and re.search(r"drink\s+(the\s+)?carriage", translation_en, re.IGNORECASE):
        issues.append(
            "Never output 'drink the carriage'. If Korean had 마차 + 마시다, use matcha."
        )

    return issues


def _build_cleanup_correction(issues: list[str]) -> str:
    bullets = "\n".join(f"- {issue}" for issue in issues)
    return (
        "\n\n[VALIDATION FAILED — fix before responding]\n"
        f"{bullets}\n"
        "Apply Physical & Logical Sanity Check and Multi-turn Keyword Sync. "
        "Return corrected JSON only."
    )


async def _call_cleanup_llm(
    source_text: str,
    system_prompt: str | None = None,
    *,
    native_language: str = "korean",
) -> dict[str, str]:
    settings = get_settings()
    client = _client()
    native = normalize_native(native_language)
    prompt = system_prompt or build_cleanup_system_prompt(native_language=native)
    resp = await client.chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": prompt},
            {"role": "user", "content": source_text},
        ],
        temperature=0.2,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or "{}"
    data = json.loads(raw)
    translations: dict = dict(data.get("translations") or {})
    if not translations:
        for legacy_key, code in (("translation_en", "en"), ("translation_de", "de")):
            legacy_val = data.get(legacy_key)
            if legacy_val:
                translations[code] = legacy_val
    translations = {
        code: text
        for code, text in translations.items()
        if isinstance(text, str) and text.strip()
    }
    translation_en = translations.get("en", "")
    translation_de = translations.get("de", "")
    valid_types = set(_CONTENT_TYPES_KO) | set(_CONTENT_TYPES_EN)
    content_type = str(data.get("content_type") or "").strip()
    if content_type not in valid_types:
        content_type = ""
    return {
        "transcript_clean_ko": data.get("transcript_clean_ko", source_text),
        "translation_en": translation_en,
        "translation_de": translation_de,
        "translations": translations,
        "content_type": content_type,
        "single_speaker": bool(data.get("single_speaker")),
    }


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


async def transcribe_audio(
    file_path: Path,
    *,
    native_language: str = "korean",
) -> str:
    client = _client()
    whisper_lang = _WHISPER_LANG.get(normalize_native(native_language), "ko")
    with file_path.open("rb") as f:
        resp = await client.audio.transcriptions.create(
            model="whisper-1",
            file=f,
            language=whisper_lang,
        )
    return resp.text.strip()


async def cleanup_and_translate(
    source_text: str,
    languages: list[str] | None = None,
    *,
    native_language: str = "korean",
) -> dict[str, str]:
    native = normalize_native(native_language)
    system_prompt = build_cleanup_system_prompt(languages, native_language=native)
    correction = ""
    result: dict = {
        "transcript_clean_ko": source_text,
        "translation_en": "",
        "translation_de": "",
        "translations": {},
        "content_type": "",
        "single_speaker": False,
    }
    for _ in range(_MAX_CLEANUP_ATTEMPTS):
        result = await _call_cleanup_llm(
            source_text + correction, system_prompt, native_language=native
        )
        issues = _detect_cleanup_anomalies(
            source_text,
            result["transcript_clean_ko"],
            result["translation_en"],
            native_language=native,
        )
        if not issues:
            return result
        correction = _build_cleanup_correction(issues)
    return result


async def cleanup_only(
    source_text: str,
    *,
    native_language: str = "korean",
) -> dict[str, Any]:
    """Write path: STT/text cleanup + classification, NO translation."""
    native = normalize_native(native_language)
    system_prompt = build_cleanup_only_system_prompt(native_language=native)
    correction = ""
    result: dict = {
        "transcript_clean_ko": source_text,
        "translation_en": "",
        "translation_de": "",
        "translations": {},
        "content_type": "",
        "single_speaker": False,
    }
    for _ in range(_MAX_CLEANUP_ATTEMPTS):
        result = await _call_cleanup_llm(
            source_text + correction, system_prompt, native_language=native
        )
        issues = _detect_cleanup_anomalies(
            source_text,
            result["transcript_clean_ko"],
            "",
            native_language=native,
        )
        if not issues:
            return result
        correction = _build_cleanup_correction(issues)
    return result


async def generate_quiz_cards(
    translation_en: str,
    graph_context: str,
    premium: bool = False,
) -> list[dict]:
    settings = get_settings()
    client = _client()
    model = settings.openai_premium_model if premium else settings.openai_model
    system = (
        "Create personalized English learning flashcards from the user's journal "
        "entry and their personal knowledge graph facts. "
        'Return JSON: {"cards": [{"question": str, "answer": str, "hint": str, '
        '"grammar_note": str}]} with 3-5 cards.'
    )
    user_content = (
        f"Journal (English):\n{translation_en}\n\n"
        f"Personal graph facts:\n{graph_context or '(none yet)'}"
    )
    resp = await client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ],
        temperature=0.4,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or '{"cards": []}'
    data = json.loads(raw)
    return data.get("cards", [])


async def generate_example_sentences(
    translation_en: str,
    transcript_clean_ko: str,
    graph_context: str,
) -> list[dict]:
    """GraphRAG-backed personalized English example sentences."""
    settings = get_settings()
    client = _client()
    system = (
        "You create personalized English learning example sentences using the user's "
        "journal entry and their personal knowledge graph (GraphRAG context). "
        "Sentences should reflect the user's life topics and vocabulary from the graph. "
        'Return JSON: {"examples": [{"en": str, "ko": str, "note": str, "graph_refs": [str]}]} '
        "with exactly 5 examples. graph_refs lists graph facts used."
    )
    user_content = (
        f"Journal (English):\n{translation_en}\n\n"
        f"Journal (Korean cleaned):\n{transcript_clean_ko}\n\n"
        f"GraphRAG context:\n{graph_context or '(empty — use journal only)'}"
    )
    resp = await client.chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ],
        temperature=0.5,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or '{"examples": []}'
    data = json.loads(raw)
    examples = data.get("examples", [])
    return examples[:5]
