"""Fast Path: Whisper STT + GPT cleanup/translation."""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path

from openai import AsyncOpenAI

from .config import get_settings

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

[OUTPUT FORMAT]
Respond with valid JSON only (no markdown). Keys:
- "transcript_clean_ko": refined Korean, speaker labels preserved
- "translations": object with ISO codes → natural idiomatic translation
{lang_lines}

Example:
Input: "당뇨랑 저녁을 먹고 와서 왔는데 상사가 없었어..."
Output: {{"transcript_clean_ko": "동료랑 저녁을 먹고 돌아왔는데 상사가 없었어요...", "translations": {ex_json}}}"""


# Default prompt (for pipeline_trace display and backward compat)
CLEANUP_SYSTEM_PROMPT = build_cleanup_system_prompt(["english", "german"])

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
    return {
        "transcript_clean_ko": data.get("transcript_clean_ko", korean_text),
        "translation_en": translation_en,
        "translation_de": translation_de,
        "translations": translations,
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
