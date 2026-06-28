"""German CEFR vocabulary bank — Goethe-based JSON source.

Source: abdullahbutt/deutsch-lernen-goethe-a1-c2 (words_final.json)
Each entry has: {"de": "...", "level": "A1", "article": "m.", "en": "..."}
"""

from __future__ import annotations

import json
import logging
import random
import re
import urllib.error
import urllib.request
from pathlib import Path

from .level_guidelines import clamp_level

logger = logging.getLogger(__name__)

_VOCAB_DIR = Path(__file__).resolve().parent.parent / "static" / "vocab"

_GERMAN_JSON_URL = (
    "https://raw.githubusercontent.com/abdullahbutt/deutsch-lernen-goethe-a1-c2/"
    "main/words_final.json"
)
_GERMAN_JSON_CACHE = "german_cefr.json"
_GERMAN_POOLS_CACHE = "german_cefr_pools.json"

_CEFR_ORDER = ("a1", "a2", "b1", "b2", "c1", "c2")
_CEFR_RANK = {c: i for i, c in enumerate(_CEFR_ORDER)}

# Curated embedded fallback — used if download fails
_EMBEDDED_FALLBACK: dict[str, list[str]] = {
    "a1": ["gehen", "kommen", "essen", "trinken", "haben", "sein", "machen", "sehen",
           "Haus", "Familie", "Arbeit", "Zeit", "Wasser", "Brot", "gut", "groß"],
    "a2": ["wohnen", "kaufen", "helfen", "brauchen", "sprechen", "fahren", "denken",
           "Wohnung", "Supermarkt", "Freund", "Schule", "wichtig", "schön", "nett"],
    "b1": ["erklären", "entscheiden", "beschreiben", "entwickeln", "erreichen",
           "Erfahrung", "Möglichkeit", "Problem", "Situation", "Gesellschaft",
           "obwohl", "deshalb", "trotzdem", "allerdings"],
    "b2": ["berücksichtigen", "analysieren", "feststellen", "beeinflussen", "vergleichen",
           "Zusammenhang", "Konsequenz", "Herausforderung", "Bedeutung", "Einfluss",
           "aufgrund", "hinsichtlich", "inzwischen"],
    "c1": ["differenzieren", "implizieren", "manifestieren", "präzisieren",
           "Auseinandersetzung", "Perspektive", "Tendenz", "Eigenschaft", "Konzept",
           "Paradigma", "diesbezüglich", "nichtsdestotrotz"],
    "c2": ["konstatieren", "exemplifizieren", "substantiieren", "perpetuieren",
           "Konnotation", "Prämisse", "Diskrepanz", "Paradoxon", "Quintessenz",
           "Paradigmenwechsel", "ungeachtet", "gleichwohl"],
}

_pools: dict[str, list[str]] | None = None


def _download_url(url: str, dest: Path) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            dest.write_bytes(resp.read())
        return True
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        logger.warning("German vocab download failed %s: %s", url, exc)
        return False


def ensure_german_vocab_files() -> None:
    _VOCAB_DIR.mkdir(parents=True, exist_ok=True)
    cache = _VOCAB_DIR / _GERMAN_JSON_CACHE
    if not cache.is_file() or cache.stat().st_size == 0:
        logger.info("Downloading German CEFR vocab from GitHub…")
        _download_url(_GERMAN_JSON_URL, cache)


def _normalize_word(raw: str) -> str:
    """Extract base lemma — strip article/plural/notes."""
    text = raw.strip()
    # Remove parenthetical plural/note like "der Abend, -e" → "Abend"
    text = text.split(",")[0].strip()
    text = re.sub(r"\([^)]*\)", "", text).strip()
    # Remove article if present at start (der/die/das/ein)
    text = re.sub(r"^(der|die|das|ein|eine)\s+", "", text, flags=re.IGNORECASE).strip()
    return text


def _is_valid_german_word(text: str) -> bool:
    if not text or len(text) < 2:
        return False
    return bool(re.match(r"^[a-zA-ZäöüÄÖÜß][a-zA-ZäöüÄÖÜß\-' ]*$", text))


def _parse_german_json(path: Path) -> dict[str, str]:
    """Parse words_final.json → {word: cefr_level}"""
    if not path.is_file():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}

    word_cefr: dict[str, str] = {}
    items = raw if isinstance(raw, list) else (list(raw.values()) if isinstance(raw, dict) else [])

    for entry in items:
        if not isinstance(entry, dict):
            continue
        word = _normalize_word(entry.get("de") or "")
        cefr = (entry.get("level") or "").strip().lower()
        if cefr not in _CEFR_RANK or not _is_valid_german_word(word):
            continue
        # Keep highest level if duplicate
        prev = word_cefr.get(word)
        if prev is None or _CEFR_RANK[cefr] > _CEFR_RANK[prev]:
            word_cefr[word] = cefr

    return word_cefr


def _build_pools() -> dict[str, list[str]]:
    cached_path = _VOCAB_DIR / _GERMAN_POOLS_CACHE
    if cached_path.is_file():
        try:
            data = json.loads(cached_path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and all(isinstance(v, list) for v in data.values()):
                return {k: list(v) for k, v in data.items()}
        except (json.JSONDecodeError, OSError):
            pass

    ensure_german_vocab_files()
    word_cefr = _parse_german_json(_VOCAB_DIR / _GERMAN_JSON_CACHE)

    if not word_cefr:
        logger.warning("No German CEFR vocab loaded — using embedded fallback only")
        pools = {c: list(_EMBEDDED_FALLBACK.get(c, [])) for c in _CEFR_ORDER}
        cached_path.write_text(json.dumps(pools, ensure_ascii=False, indent=2), encoding="utf-8")
        return pools

    pools: dict[str, list[str]] = {c: [] for c in _CEFR_ORDER}
    for word, cefr in sorted(word_cefr.items()):
        pools.setdefault(cefr, []).append(word)

    # Fill any empty tier from fallback
    for cefr in _CEFR_ORDER:
        if not pools.get(cefr):
            pools[cefr] = list(_EMBEDDED_FALLBACK.get(cefr, []))

    cached_path.write_text(json.dumps(pools, ensure_ascii=False, indent=2), encoding="utf-8")
    logger.info(
        "German CEFR pools: a1=%d a2=%d b1=%d b2=%d c1=%d c2=%d",
        *[len(pools.get(c, [])) for c in _CEFR_ORDER],
    )
    return pools


def _get_pools() -> dict[str, list[str]]:
    global _pools
    if _pools is None:
        _pools = _build_pools()
    return _pools


def level_to_cefr(user_level: int) -> str:
    level = clamp_level(user_level)
    if level <= 20:
        return "a1"
    if level <= 40:
        return "a2"
    if level <= 60:
        return "b1"
    if level <= 75:
        return "b2"
    return "c1"


def _pool_for_level(user_level: int) -> tuple[str, list[str]]:
    primary = level_to_cefr(user_level)
    pools = _get_pools()
    idx = _CEFR_RANK[primary]
    for i in range(idx, -1, -1):
        cefr = _CEFR_ORDER[i]
        pool = pools.get(cefr) or []
        if pool:
            return cefr, pool
    fb = _EMBEDDED_FALLBACK.get(primary) or _EMBEDDED_FALLBACK["a1"]
    return primary, fb


def get_random_vocab_seed(user_level: int) -> dict[str, str]:
    cefr, pool = _pool_for_level(user_level)
    word = random.choice(pool)
    return {"word": word, "cefr": cefr}


def estimate_default_word_count() -> int:
    pools = _get_pools()
    return sum(len(pool) for pool in pools.values())


def reset_vocab_cache() -> None:
    global _pools
    _pools = None


def rebuild_vocab_cache() -> dict[str, list[str]]:
    global _pools
    cache = _VOCAB_DIR / _GERMAN_POOLS_CACHE
    if cache.is_file():
        cache.unlink()
    _pools = None
    return _get_pools()
