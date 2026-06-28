"""IELTS 4000 Academic Word List — static JSON source for bulk user-vocab seeding."""

from __future__ import annotations

import json
import logging
import re
import urllib.error
import urllib.request
from pathlib import Path

logger = logging.getLogger(__name__)

_VOCAB_DIR = Path(__file__).resolve().parent.parent / "static" / "vocab"
_IELTS_TXT_URL = "https://raw.githubusercontent.com/lzrk/nglsh/master/IELTS-4000.txt"
_IELTS_JSON_CACHE = "ielts_4000.json"

_EMBEDDED_FALLBACK: list[dict[str, str]] = [
    {"word": "abandon", "definition": "give up completely"},
    {"word": "academic", "definition": "related to education or scholarship"},
    {"word": "accumulate", "definition": "gather or collect"},
    {"word": "adequate", "definition": "sufficient for a purpose"},
    {"word": "advocate", "definition": "publicly support or recommend"},
]

_entries: list[dict[str, str]] | None = None


def _download_url(url: str, dest: Path) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            dest.write_bytes(resp.read())
        return True
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        logger.warning("IELTS vocab download failed %s: %s", url, exc)
        return False


_WORD_LINE = re.compile(r"^([a-z][a-z' -]*[a-z]|[a-z]):\s*(.*)$", re.IGNORECASE)
_SKIP_PREFIXES = ("Source URL:", "Title:")
_SKIP_CONTAINS = ("IELTS SHARE",)


def parse_ielts_txt(text: str) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if len(line) == 1 and line.isalpha() and line.isupper():
            continue
        if line.startswith(_SKIP_PREFIXES) or any(s in line for s in _SKIP_CONTAINS):
            continue
        if line.startswith("IELTS") or line.startswith("4000 Academic"):
            continue

        match = _WORD_LINE.match(line)
        if match:
            if current:
                entries.append(current)
            word = re.sub(r"\s+", " ", match.group(1).strip().lower())
            current = {"word": word, "definition": match.group(2).strip()}
        elif current is not None:
            current["definition"] += " " + line

    if current:
        entries.append(current)
    return entries


def _normalize_word(raw: str) -> str:
    text = raw.strip().lower()
    text = re.sub(r"\([^)]*\)", "", text).strip()
    text = text.split(",")[0].strip()
    text = re.sub(r"\s+", " ", text)
    return text


def _is_valid_word(text: str) -> bool:
    if not text or len(text) < 1:
        return False
    return bool(re.match(r"^[a-z][a-z' -]*[a-z]$|^[a-z]$", text))


def _load_json_entries(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        return []
    entries: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        word = _normalize_word(item.get("word") or "")
        definition = (item.get("definition") or "").strip()
        if not _is_valid_word(word) or word in seen:
            continue
        seen.add(word)
        entries.append({"word": word, "definition": definition})
    return entries


def ensure_ielts_vocab_file() -> None:
    """Ensure IELTS JSON exists under static/vocab."""
    _VOCAB_DIR.mkdir(parents=True, exist_ok=True)
    cache = _VOCAB_DIR / _IELTS_JSON_CACHE
    if cache.is_file() and cache.stat().st_size > 0:
        return

    txt_dest = _VOCAB_DIR / "IELTS-4000.txt"
    if _download_url(_IELTS_TXT_URL, txt_dest):
        entries = parse_ielts_txt(txt_dest.read_text(encoding="utf-8"))
        if entries:
            cache.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
            return

    cache.write_text(json.dumps(_EMBEDDED_FALLBACK, ensure_ascii=False, indent=2), encoding="utf-8")
    logger.warning("IELTS vocab using embedded fallback only (%d words)", len(_EMBEDDED_FALLBACK))


def get_ielts_entries() -> list[dict[str, str]]:
    """Return all IELTS word entries (word + definition)."""
    global _entries
    if _entries is None:
        ensure_ielts_vocab_file()
        loaded = _load_json_entries(_VOCAB_DIR / _IELTS_JSON_CACHE)
        _entries = loaded if loaded else list(_EMBEDDED_FALLBACK)
        logger.info("IELTS entries loaded: %d words", len(_entries))
    return _entries


def reset_ielts_cache() -> None:
    global _entries
    _entries = None
