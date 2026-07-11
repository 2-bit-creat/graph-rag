"""Fast Path: Whisper STT + GPT cleanup/translation."""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

from openai import AsyncOpenAI

from .config import get_settings

_LABEL_LINE_RE = re.compile(r"^\s*\[([^\]]+)\]\s*:?\s*(.*)$")
_SENT_SPLIT_RE = re.compile(r"(?<=[.!?。?！])\s+")


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
_CLEANUP_BODY = """[STT CLEANUP]
Fix phonetic mishearings, fillers, and grammar. Apply real-world logic:
- Consumption verbs (먹다/마시다) need edible/drinkable objects. If absurd, find the closest phonetic correction.
  Example: 마차 + 마시다 → 말차 (matcha), NOT 마차 (carriage)
- Commerce verbs need purchasable objects. Movement verbs must match noun type.
- Unify cross-speaker references: if Speaker A makes X and Speaker B drinks X, both must use the same corrected word.

[SPEAKER LABELS]
- Keep [Speaker_N] labels unchanged in all outputs — never replace with names.
- One line per speaker turn; fix only the text, not the label.

[TEXT STRUCTURE]
- Preserve meaningful paragraph breaks from typed text. Do not collapse a multi-paragraph
  input into one long line.
- For one-speaker essays/notes, structure the cleaned Korean into readable short
  paragraphs when the input is dense: keep numbered items and headings on their own
  lines, and add paragraph breaks between distinct reasons, definitions, examples,
  or conclusions.
- For multi-speaker text, keep one line per speaker turn.

[CONTENT CLASSIFICATION]
Also classify the content so the app can suggest a type and detect over-split:
- "content_type": exactly one of [일기, 대화, 회의록, 책, 뉴스, 강연, 논문].
  일기 = personal first-person diary/monologue; 대화 = a conversation between people.
- "single_speaker": true ONLY if this is ONE first-person narrator talking (a personal
  diary/monologue). false for any real multi-person conversation or external source.
  Note: [Speaker_N] tags are automatic diarization labels, NOT proof of a real
  conversation. If only ONE distinct speaker actually talks, set single_speaker=true
  and choose a monologue type (일기 by default, or 강연/책/뉴스/논문 if it is clearly
  that medium) — never 대화/회의록."""


def build_cleanup_only_system_prompt() -> str:
    """Cleanup + classification only — NO translation.

    Fast write path: producing translations for long text (esp. multiple target
    languages) triples output tokens and dominates latency. Diary writing wants the
    refined Korean immediately; translation is deferred to an on-demand step.
    """
    return f"""You are a linguistic engine for Korean STT/text cleanup.

{_CLEANUP_BODY}

[OUTPUT FORMAT]
Respond with valid JSON only (no markdown). Keys:
- "transcript_clean_ko": refined Korean, speaker labels preserved
- "content_type": one of the categories above
- "single_speaker": boolean

Example:
Input: "당뇨랑 저녁을 먹고 와서 왔는데 상사가 없었어..."
Output: {{"transcript_clean_ko": "동료랑 저녁을 먹고 돌아왔는데 상사가 없었어요...", "content_type": "일기", "single_speaker": true}}"""


def build_cleanup_system_prompt(languages: list[str] | None = None) -> str:
    """Build the STT cleanup + translation system prompt for given target languages."""
    if not languages:
        languages = ["english"]

    lang_map = {
        "english": ("en", "English"),
        "german": ("de", "German (Deutsch)"),
        "japanese": ("ja", "Japanese"),
        "chinese": ("zh", "Chinese"),
        "french": ("fr", "French"),
        "spanish": ("es", "Spanish"),
    }
    lang_lines = "\n".join(
        f'  - "{code}": natural {label} translation'
        for lang in languages
        for code, label in [lang_map.get(lang, (lang[:2], lang.title()))]
    )

    example_translations: dict[str, str] = {}
    for lang in languages:
        code, _ = lang_map.get(lang, (lang[:2], lang.title()))
        if lang == "english":
            example_translations[code] = "I came back after having dinner with a colleague, but my boss wasn't there..."
        elif lang == "german":
            example_translations[code] = "Ich bin nach dem Abendessen mit einem Kollegen zurückgekommen, aber mein Chef war nicht da..."
    ex_json = "{" + ", ".join(f'"{k}": "{v}"' for k, v in example_translations.items()) + "}"

    return f"""You are a linguistic engine for Korean STT cleanup and multilingual translation.

[STT CLEANUP]
Fix phonetic mishearings, fillers, and grammar. Apply real-world logic:
- Consumption verbs (먹다/마시다) need edible/drinkable objects. If absurd, find the closest phonetic correction.
  Example: 마차 + 마시다 → 말차 (matcha), NOT 마차 (carriage)
- Commerce verbs need purchasable objects. Movement verbs must match noun type.
- Unify cross-speaker references: if Speaker A makes X and Speaker B drinks X, both must use the same corrected word.

[SPEAKER LABELS]
- Keep [Speaker_N] labels unchanged in all outputs — never replace with names.
- One line per speaker turn; fix only the text, not the label.

[CONTENT CLASSIFICATION]
Also classify the content so the app can suggest a type and detect over-split:
- "content_type": exactly one of [일기, 대화, 회의록, 책, 뉴스, 강연, 논문].
  일기 = personal first-person diary/monologue; 대화 = a conversation between people.
- "single_speaker": true ONLY if this is ONE first-person narrator talking (a personal
  diary/monologue). false for any real multi-person conversation or external source.
  Note: [Speaker_N] tags are automatic diarization labels, NOT proof of a real
  conversation. If only ONE distinct speaker actually talks, set single_speaker=true
  and choose a monologue type (일기 by default, or 강연/책/뉴스/논문 if it is clearly
  that medium) — never 대화/회의록.

[OUTPUT FORMAT]
Respond with valid JSON only (no markdown). Keys:
- "transcript_clean_ko": refined Korean, speaker labels preserved
- "translations": object with ISO codes → natural idiomatic translation
- "content_type": one of the categories above
- "single_speaker": boolean
{lang_lines}

Example:
Input: "당뇨랑 저녁을 먹고 와서 왔는데 상사가 없었어..."
Output: {{"transcript_clean_ko": "동료랑 저녁을 먹고 돌아왔는데 상사가 없었어요...", "content_type": "일기", "single_speaker": true, "translations": {ex_json}}}"""


# Default prompt (for pipeline_trace display and backward compat)
CLEANUP_SYSTEM_PROMPT = build_cleanup_system_prompt(["english", "german"])

# ─── Content-type gate ────────────────────────────────────────────────────────
# Speaker count is a hard structural signal the classification LLM tends to ignore
# (it sees [Speaker_N] diarization labels and drifts toward 대화). These sets let us
# reconcile the LLM's guess with the actual number of distinct speakers.

# Canonical display category for a personal single-speaker diary. The rest of the
# app (timeline colors, graph context_type) uses '개인일기'; the cleanup LLM emits
# the shorter '일기'. Normalize to the canonical form here.
DIARY_CATEGORY = "개인일기"
# Types that structurally require more than one speaker — never valid for a monologue.
_MULTI_SPEAKER_TYPES = {"대화", "회의록"}
# Diary aliases that structurally require a single speaker.
_DIARY_ALIASES = {"일기", "개인일기"}


# Default for external-source material that doesn't fit a traditional medium —
# AI 답변·요약·여러 출처를 섞은 노트 등 "정리된 참고 지식". 붙여넣기 출처의 기본값.
_SOURCE_FALLBACK_TYPE = "자료"
# Specific media worth preserving when the user attributes an external source — a
# real pasted article/paper/lecture. Everything else collapses to 자료.
_SOURCE_KEEP_TYPES = {"뉴스", "논문", "강연"}


def gate_source_type(
    content_type: str | None,
    *,
    single_speaker: bool,
    source_attributed: bool = False,
) -> str | None:
    """Reconcile the LLM's content_type guess with the real speaker count.

    - single speaker  → forbid 대화/회의록; default to 개인일기, but keep an explicit
      monologue medium (강연/책/뉴스/논문) when the LLM chose one.
    - multiple speakers → forbid 일기/개인일기; fall back to 대화.
    - source_attributed (user marked the text as 외부 출처 자료) → never a personal
      diary or real conversation; default to 자료 (정리된 지식) unless the LLM
      recognized a specific medium (뉴스/논문/강연) worth keeping.

    Returns the canonical category, or None when there's nothing to suggest.
    """
    ct = (content_type or "").strip()
    if source_attributed:
        return ct if ct in _SOURCE_KEEP_TYPES else _SOURCE_FALLBACK_TYPE
    if single_speaker:
        if ct == "" or ct in _MULTI_SPEAKER_TYPES or ct in _DIARY_ALIASES:
            return DIARY_CATEGORY
        return ct  # 강연 / 책 / 뉴스 / 논문
    # multi-speaker: a personal diary is impossible
    if ct == "" or ct in _DIARY_ALIASES:
        return "대화"
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
    source_ko: str,
    transcript_clean_ko: str,
    translation_en: str,
) -> list[str]:
    """Return human-readable issues that should trigger a cleanup retry."""
    issues: list[str] = []
    combined_ko = f"{source_ko}\n{transcript_clean_ko}"

    if _KO_MACHA_HOMOPHONE_RE.search(combined_ko) and _KO_CONSUME_VERB_RE.search(combined_ko):
        if not _KO_MATCHA_CORRECTED_RE.search(transcript_clean_ko):
            issues.append(
                "Korean lines use 마차 with a consumption verb (마시다/먹다) — "
                "this must be corrected to 말차 (matcha tea), not carriage (수레)."
            )

    if _EN_IMPOSSIBLE_RE.search(translation_en):
        issues.append(
            "English translation contains a physically impossible consumption action "
            "(e.g. drink/eat + carriage/computer/person). "
            "Re-read the Korean dialogue, fix the STT homophone in transcript_clean_ko, "
            "then re-translate."
        )

    if re.search(r"drink\s+(the\s+)?carriage", translation_en, re.IGNORECASE):
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


async def _call_cleanup_llm(korean_text: str, system_prompt: str | None = None) -> dict[str, str]:
    settings = get_settings()
    client = _client()
    prompt = system_prompt or CLEANUP_SYSTEM_PROMPT
    resp = await client.chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": prompt},
            {"role": "user", "content": korean_text},
        ],
        temperature=0.2,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or "{}"
    data = json.loads(raw)
    translations: dict = dict(data.get("translations") or {})
    # Support both new {"translations": {"en": ...}} and legacy {"translation_en": ...}
    if not translations:
        for legacy_key, code in (("translation_en", "en"), ("translation_de", "de")):
            legacy_val = data.get(legacy_key)
            if legacy_val:
                translations[code] = legacy_val
    # Keep only non-empty string values.
    translations = {
        code: text
        for code, text in translations.items()
        if isinstance(text, str) and text.strip()
    }
    translation_en = translations.get("en", "")
    translation_de = translations.get("de", "")
    _VALID_TYPES = {"일기", "대화", "회의록", "책", "뉴스", "강연", "논문"}
    content_type = str(data.get("content_type") or "").strip()
    if content_type not in _VALID_TYPES:
        content_type = ""
    return {
        "transcript_clean_ko": data.get("transcript_clean_ko", korean_text),
        "translation_en": translation_en,
        "translation_de": translation_de,
        "translations": translations,
        "content_type": content_type,
        "single_speaker": bool(data.get("single_speaker")),
    }


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


async def transcribe_audio(file_path: Path) -> str:
    client = _client()
    with file_path.open("rb") as f:
        resp = await client.audio.transcriptions.create(
            model="whisper-1",
            file=f,
            language="ko",
        )
    return resp.text.strip()


async def cleanup_and_translate(
    korean_text: str,
    languages: list[str] | None = None,
) -> dict[str, str]:
    system_prompt = build_cleanup_system_prompt(languages)
    correction = ""
    result: dict = {
        "transcript_clean_ko": korean_text,
        "translation_en": "",
        "translation_de": "",
        "translations": {},
        "content_type": "",
        "single_speaker": False,
    }
    for _ in range(_MAX_CLEANUP_ATTEMPTS):
        result = await _call_cleanup_llm(korean_text + correction, system_prompt)
        issues = _detect_cleanup_anomalies(
            korean_text,
            result["transcript_clean_ko"],
            result["translation_en"],
        )
        if not issues:
            return result
        correction = _build_cleanup_correction(issues)
    return result


async def cleanup_only(korean_text: str) -> dict[str, Any]:
    """Write path: STT/text cleanup + classification, NO translation.

    2026-07-04 결정으로 일기 통번역 기능 자체를 제거 — 쓰기 경로(음성·텍스트 공통)는
    이 함수만 사용한다. Returns the same shape as [cleanup_and_translate] but with
    empty translations. Anomaly retries still run on the Korean cleanup (마차→말차).
    """
    system_prompt = build_cleanup_only_system_prompt()
    correction = ""
    result: dict = {
        "transcript_clean_ko": korean_text,
        "translation_en": "",
        "translation_de": "",
        "translations": {},
        "content_type": "",
        "single_speaker": False,
    }
    for _ in range(_MAX_CLEANUP_ATTEMPTS):
        result = await _call_cleanup_llm(korean_text + correction, system_prompt)
        issues = _detect_cleanup_anomalies(korean_text, result["transcript_clean_ko"], "")
        if not issues:
            return result
        correction = _build_cleanup_correction(issues)
    return result


