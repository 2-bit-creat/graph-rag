"""Extract language-learning expressions from Statement node content.

One LLM call per node covers ALL target languages simultaneously,
returning {language_key: [expressions]} in a single JSON response.
"""

from __future__ import annotations

import json
import logging
import uuid
from functools import lru_cache

from openai import AsyncOpenAI
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import Node

logger = logging.getLogger(__name__)

_LANGUAGE_LABELS: dict[str, str] = {
    "english":    "English",
    "german":     "German (Deutsch)",
    "japanese":   "Japanese (日本語)",
    "chinese":    "Chinese (中文)",
    "french":     "French (Français)",
    "spanish":    "Spanish (Español)",
    "portuguese": "Portuguese (Português)",
    "italian":    "Italian (Italiano)",
    "arabic":     "Arabic (عربي)",
    "russian":    "Russian (Русский)",
}

_MULTILANG_SYSTEM = """\
You are a multilingual language-learning content creator.

Given a Korean statement, extract vocabulary and expressions worth learning in EACH requested target language.

Core principle: For each language, independently decide what is most valuable for a learner of THAT language to know.
The same Korean text will naturally surface different vocabulary in different languages — that is expected and correct.
Do not force the same items across languages just because the underlying Korean meaning is shared.

Include words and expressions that are: non-trivial, context-relevant, genuinely useful for a learner.
Exclude: very basic words (the, is, have, 있다 equivalents), standalone proper nouns.

Rules:
- 5–20 items per language
- expression: canonical/lemma form (lowercase for alphabetic scripts). For German nouns, omit the article; put gender in meaning_ko (e.g. "회사, f.")
- meaning_ko: Korean meaning
- example: one natural sentence in the target language using the expression
- cefr: A1 / A2 / B1 / B2 / C1 / C2

Output JSON — include ONLY the languages listed in the request:
{
  "english": [{"expression": "...", "meaning_ko": "...", "example": "...", "cefr": "B2"}, ...],
  "german":  [{"expression": "...", "meaning_ko": "...", "example": "...", "cefr": "B1"}, ...]
}
Respond with valid JSON only.
"""


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


def _parse_statement_description(description: str | None) -> str:
    """Extract content text from Statement node description (JSON or legacy format)."""
    if not description:
        return ""
    try:
        data = json.loads(description)
        return (data.get("content") or "").strip()
    except (json.JSONDecodeError, AttributeError):
        parts = description.split("\n", 1)
        return (parts[1].strip() if len(parts) > 1 else parts[0].strip())


async def extract_multilang(
    *,
    node_name: str,
    content_ko: str,
    translation_en: str = "",
    languages: list[str],
) -> dict[str, list[dict]]:
    """Extract expressions for ALL requested languages in a SINGLE LLM call.

    Returns {language_key: [{expression, meaning_ko, example}]}.
    """
    if not languages:
        return {}

    statement_text = content_ko or node_name
    if not statement_text:
        return {lang: [] for lang in languages}

    lang_labels = ", ".join(
        f'"{lang}" ({_LANGUAGE_LABELS.get(lang, lang.title())})'
        for lang in languages
    )
    user_content = (
        f"Target languages: [{lang_labels}]\n\n"
        f"Korean statement:\n{statement_text}\n\n"
        f"English reference (optional):\n{translation_en or '(derive from Korean)'}\n"
    )

    settings = get_settings()
    client = _client()

    try:
        resp = await client.chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": _MULTILANG_SYSTEM},
                {"role": "user", "content": user_content},
            ],
            temperature=0.1,
            response_format={"type": "json_object"},
        )
        raw = resp.choices[0].message.content or "{}"
        data = json.loads(raw)

        result: dict[str, list[dict]] = {}
        for lang in languages:
            items = data.get(lang) or []
            if not isinstance(items, list):
                items = []
            cleaned: list[dict] = []
            seen: set[str] = set()
            for item in items:
                if not isinstance(item, dict):
                    continue
                expr = (item.get("expression") or "").strip().lower()
                meaning = (item.get("meaning_ko") or item.get("meaning") or "").strip()
                example = (item.get("example") or "").strip()
                cefr = (item.get("cefr") or "").strip().upper()
                if cefr not in {"A1", "A2", "B1", "B2", "C1", "C2"}:
                    cefr = ""
                if not expr or not meaning or expr in seen:
                    continue
                cleaned.append({"expression": expr, "meaning_ko": meaning, "example_en": example, "cefr": cefr})
                seen.add(expr)
            result[lang] = cleaned
        return result

    except Exception as exc:
        logger.warning("Multi-language extraction failed: %s", exc)
        return {lang: [] for lang in languages}


# ── Kept for backward-compat callers ──────────────────────────────────────────

async def extract_from_statement_text(
    *,
    node_name: str,
    content_ko: str,
    translation_en: str = "",
    language: str = "english",
) -> list[dict]:
    """Single-language shim — calls extract_multilang internally."""
    result = await extract_multilang(
        node_name=node_name,
        content_ko=content_ko,
        translation_en=translation_en,
        languages=[language],
    )
    return result.get(language, [])


async def extract_expressions_from_statement_nodes(
    session: AsyncSession,
    user_id: uuid.UUID,
    statement_node_ids: list[uuid.UUID],
    journal_translation_en: str = "",
    language: str = "english",
) -> list[dict]:
    """Extract expressions from a list of Statement nodes (single language)."""
    if not statement_node_ids:
        return []
    result_rows = await session.execute(
        select(Node).where(
            Node.id.in_(statement_node_ids),
            Node.user_id == user_id,
            Node.type == "Statement",
        )
    )
    nodes = list(result_rows.scalars().all())
    if not nodes:
        return []

    all_expressions: list[dict] = []
    for node in nodes:
        content_ko = _parse_statement_description(node.description)
        exprs = await extract_from_statement_text(
            node_name=node.name,
            content_ko=content_ko,
            translation_en=journal_translation_en,
            language=language,
        )
        for e in exprs:
            e["source_node_id"] = str(node.id)
            e["source_node_name"] = node.name
        all_expressions.extend(exprs)

    seen: set[str] = set()
    return [
        item for item in all_expressions
        if item["expression"] not in seen and not seen.add(item["expression"])  # type: ignore[func-returns-value]
    ]
