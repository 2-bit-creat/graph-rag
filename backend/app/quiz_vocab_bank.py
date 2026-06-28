"""Oxford CEFR vocabulary bank — JSON source with embedded fallback."""

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

# Verified open-source JSON with explicit per-entry CEFR (winterdl / Oxford wordlists).
_OXFORD_5000_JSON_URL = (
    "https://raw.githubusercontent.com/winterdl/oxford-5000-vocabulary-audio-definition/"
    "master/data/oxford_5000.json"
)
_OXFORD_JSON_CACHE = "oxford_5000_cefr.json"
_CEFR_POOLS_CACHE = "cefr_pools.json"

_CEFR_ORDER = ("a1", "a2", "b1", "b2", "c1", "c2")
_CEFR_RANK = {c: i for i, c in enumerate(_CEFR_ORDER)}

# Offline emergency fallback only (no PDF parsing).
_EMBEDDED_FALLBACK: dict[str, list[str]] = {
    "a1": ["hello", "friend", "happy", "coffee", "family"],
    "a2": ["visit", "weather", "important", "remember", "different"],
    "b1": ["achieve", "environment", "although", "suggest", "purpose"],
    "b2": ["confident", "negotiate", "significant", "consequence", "establish"],
    "c1": ["precarious", "sophisticated", "undermine", "compelling", "paradigm"],
    "c2": ["quintessential", "unprecedented", "conundrum", "ephemeral", "juxtapose"],
}

_pools: dict[str, list[str]] | None = None


def _download_url(url: str, dest: Path) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            dest.write_bytes(resp.read())
        return True
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        logger.warning("Vocab download failed %s: %s", url, exc)
        return False


def ensure_vocab_files() -> None:
    """Ensure Oxford CEFR JSON exists under static/vocab."""
    _VOCAB_DIR.mkdir(parents=True, exist_ok=True)
    cache = _VOCAB_DIR / _OXFORD_JSON_CACHE
    if not cache.is_file() or cache.stat().st_size == 0:
        _download_url(_OXFORD_5000_JSON_URL, cache)


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


def _merge_word_cefr(word_cefr: dict[str, str], word: str, cefr: str) -> None:
    cefr = cefr.lower()
    if cefr not in _CEFR_RANK or not _is_valid_word(word):
        return
    prev = word_cefr.get(word)
    if prev is None or _CEFR_RANK[cefr] > _CEFR_RANK[prev]:
        word_cefr[word] = cefr


def _pools_from_word_cefr(word_cefr: dict[str, str]) -> dict[str, list[str]]:
    pools: dict[str, list[str]] = {c: [] for c in _CEFR_ORDER}
    for word, cefr in sorted(word_cefr.items()):
        pools.setdefault(cefr, []).append(word)
    for cefr in _CEFR_ORDER:
        if not pools.get(cefr):
            pools[cefr] = list(_EMBEDDED_FALLBACK.get(cefr, []))
    return pools


def _parse_oxford_json(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    word_cefr: dict[str, str] = {}
    items = raw.values() if isinstance(raw, dict) else raw
    for entry in items:
        if not isinstance(entry, dict):
            continue
        word = _normalize_word(entry.get("word") or "")
        cefr = (entry.get("cefr") or "").strip().lower()
        _merge_word_cefr(word_cefr, word, cefr)
    return word_cefr


def _load_cached_pools() -> dict[str, list[str]] | None:
    cache = _VOCAB_DIR / _CEFR_POOLS_CACHE
    if not cache.is_file():
        return None
    try:
        data = json.loads(cache.read_text(encoding="utf-8"))
        if isinstance(data, dict) and all(isinstance(v, list) for v in data.values()):
            return {k: list(v) for k, v in data.items()}
    except (json.JSONDecodeError, OSError):
        pass
    return None


def _save_cached_pools(pools: dict[str, list[str]]) -> None:
    cache = _VOCAB_DIR / _CEFR_POOLS_CACHE
    cache.write_text(json.dumps(pools, ensure_ascii=False, indent=2), encoding="utf-8")


def _build_pools() -> dict[str, list[str]]:
    cached = _load_cached_pools()
    if cached:
        return cached

    ensure_vocab_files()
    json_path = _VOCAB_DIR / _OXFORD_JSON_CACHE
    word_cefr = _parse_oxford_json(json_path)

    if not word_cefr:
        logger.warning("No CEFR vocab loaded from JSON — using embedded fallback only")
        pools = {c: list(_EMBEDDED_FALLBACK.get(c, [])) for c in _CEFR_ORDER}
        _save_cached_pools(pools)
        return pools

    pools = _pools_from_word_cefr(word_cefr)
    _save_cached_pools(pools)
    logger.info(
        "CEFR pools: a1=%d a2=%d b1=%d b2=%d c1=%d",
        len(pools.get("a1", [])),
        len(pools.get("a2", [])),
        len(pools.get("b1", [])),
        len(pools.get("b2", [])),
        len(pools.get("c1", [])),
    )
    return pools


def _get_pools() -> dict[str, list[str]]:
    global _pools
    if _pools is None:
        _pools = _build_pools()
    return _pools


def level_to_cefr(user_level: int) -> str:
    """Map user Lv.1–100 to a strict Oxford CEFR tier."""
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
    """Return (resolved_cefr, word pool) with fallback to adjacent lower tiers."""
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
    """Pick one random word for the user's exact CEFR tier (with lower-tier fallback)."""
    cefr, pool = _pool_for_level(user_level)
    word = random.choice(pool)
    return {"word": word, "cefr": cefr}


def estimate_default_word_count() -> int:
    """Approximate total words in the Oxford CEFR pools (for API summaries)."""
    pools = _get_pools()
    return sum(len(pool) for pool in pools.values())


def reset_vocab_cache() -> None:
    """Clear in-memory pools (for tests)."""
    global _pools
    _pools = None


def rebuild_vocab_cache() -> dict[str, list[str]]:
    """Force rebuild from Oxford JSON and refresh cefr_pools.json."""
    global _pools
    cache = _VOCAB_DIR / _CEFR_POOLS_CACHE
    if cache.is_file():
        cache.unlink()
    _pools = None
    return _get_pools()
