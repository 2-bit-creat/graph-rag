"""Per-node, per-language expression storage (JSON file per user).

Structure of user_node_expressions.json:
{
  "expressions": {
    "<node_id>": {
      "english": [{"expression": "...", "meaning": "...", "example_en": "...", "added_at": "..."}],
      "german": [...]
    }
  },
  "extraction_done": {
    "<node_id>": ["english", "german"]
  }
}
"""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .config import get_settings

_FILENAME = "user_node_expressions.json"

# German definite/indefinite articles to strip from the front of expressions.
# This ensures quiz blanks test the noun/verb itself, not the article.
_DE_ARTICLES = frozenset(
    ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines"]
)


def _strip_german_article(expr: str) -> str:
    """Remove leading article from a German expression (lowercase input expected)."""
    parts = expr.split(None, 1)
    if len(parts) == 2 and parts[0] in _DE_ARTICLES:
        return parts[1]
    return expr


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _store_path(user_id: uuid.UUID) -> Path:
    root = Path(get_settings().upload_dir) / str(user_id)
    root.mkdir(parents=True, exist_ok=True)
    return root / _FILENAME


def _empty_store() -> dict[str, Any]:
    return {"expressions": {}, "extraction_done": {}}


def _read_store_sync(user_id: uuid.UUID) -> dict[str, Any]:
    path = _store_path(user_id)
    if not path.is_file():
        return _empty_store()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return _empty_store()
        data.setdefault("expressions", {})
        data.setdefault("extraction_done", {})
        return data
    except (json.JSONDecodeError, OSError):
        return _empty_store()


def _write_store_sync(user_id: uuid.UUID, data: dict[str, Any]) -> None:
    path = _store_path(user_id)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


# ── Public async API ────────────────────────────────────────────────────────


async def is_extracted(user_id: uuid.UUID, node_id: str, language: str) -> bool:
    def _check() -> bool:
        store = _read_store_sync(user_id)
        done = store.get("extraction_done", {})
        return language in (done.get(node_id) or [])
    return await asyncio.to_thread(_check)


async def get_node_expressions(
    user_id: uuid.UUID,
    node_id: str,
    language: str,
) -> list[dict[str, Any]]:
    def _get() -> list[dict[str, Any]]:
        store = _read_store_sync(user_id)
        return list(
            store.get("expressions", {}).get(node_id, {}).get(language, [])
        )
    return await asyncio.to_thread(_get)


async def get_node_expressions_all_languages(
    user_id: uuid.UUID,
    node_id: str,
) -> dict[str, list[dict[str, Any]]]:
    """Return {language: [expressions]} for all extracted languages for a node."""
    def _get() -> dict[str, list[dict[str, Any]]]:
        store = _read_store_sync(user_id)
        raw = dict(store.get("expressions", {}).get(node_id, {}))
        # Exclude non-language metadata keys stored alongside expressions
        return {k: v for k, v in raw.items() if isinstance(v, list)}
    return await asyncio.to_thread(_get)


async def save_node_expressions(
    user_id: uuid.UUID,
    node_id: str,
    language: str,
    expressions: list[dict[str, Any]],
    *,
    node_name: str = "",
) -> None:
    is_german = (language or "").strip().lower() == "german"

    def _save() -> None:
        store = _read_store_sync(user_id)
        node_exprs = store["expressions"].setdefault(node_id, {})
        if node_name:
            node_exprs["node_name"] = node_name
        lang_exprs = node_exprs.get(language, [])
        seen = {e.get("expression", "").lower() for e in lang_exprs}
        now = _utc_now()
        for item in expressions:
            expr_key = (item.get("expression") or "").strip().lower()
            if is_german:
                expr_key = _strip_german_article(expr_key)
            if not expr_key or expr_key in seen:
                continue
            cefr = (item.get("cefr") or "").strip().upper()
            if cefr not in {"A1", "A2", "B1", "B2", "C1", "C2"}:
                cefr = ""
            lang_exprs.append({
                "expression": expr_key,
                "meaning": (item.get("meaning_ko") or item.get("meaning") or "").strip(),
                "example": (item.get("example_en") or item.get("example") or "").strip(),
                "surface_form": (item.get("surface_form") or "").strip(),
                "meaning_parts": item.get("meaning_parts") or [],
                "cefr": cefr,
                "added_at": now,
            })
            seen.add(expr_key)
        node_exprs[language] = lang_exprs
        done = store["extraction_done"].setdefault(node_id, [])
        if language not in done:
            done.append(language)
        _write_store_sync(user_id, store)
    await asyncio.to_thread(_save)


async def get_statement_bank_for_language(
    user_id: uuid.UUID,
    language: str,
) -> list[dict[str, Any]]:
    """Return expressions for a language, MERGED by lemma across all nodes.

    The same word (e.g. "matcha") extracted from several Statement nodes — common
    when two speakers share a concept — collapses into ONE entry whose ``origins``
    lists every source node (+ its example). Back-compat top-level fields
    (source_node_id / source_node_name / example) mirror the first origin so older
    consumers keep working. Deleting one origin (its node) drops that badge; the
    entry disappears only when the last origin is gone (merge is purely read-time).
    """
    def _get() -> list[dict[str, Any]]:
        store = _read_store_sync(user_id)
        # Preserve first-seen order of lemmas.
        merged: dict[str, dict[str, Any]] = {}
        for node_id, lang_map in store.get("expressions", {}).items():
            node_name = lang_map.get("node_name") or ""
            for item in lang_map.get(language, []):
                lemma = (item.get("expression") or "").strip().lower()
                if not lemma:
                    continue
                example = (item.get("example") or "").strip()
                origin = {
                    "node_id": node_id,
                    "node_name": node_name or None,
                    "example": example or None,
                }
                entry = merged.get(lemma)
                if entry is None:
                    merged[lemma] = {
                        **item,
                        "language": language,
                        # Back-compat: representative (first) origin.
                        "source_node_id": node_id,
                        "source_node_name": node_name or None,
                        "origins": [origin],
                    }
                else:
                    entry["origins"].append(origin)
                    # Fill gaps from later origins (meaning/cefr/example).
                    if not entry.get("meaning") and item.get("meaning"):
                        entry["meaning"] = item["meaning"]
                    if not entry.get("cefr") and item.get("cefr"):
                        entry["cefr"] = item["cefr"]
                    if not entry.get("example") and example:
                        entry["example"] = example
        return list(merged.values())
    return await asyncio.to_thread(_get)


async def get_pending_node_language_pairs(
    user_id: uuid.UUID,
    node_ids: list[str],
    languages: list[str],
) -> list[tuple[str, str]]:
    """Return (node_id, language) pairs where extraction hasn't been done yet."""
    def _get() -> list[tuple[str, str]]:
        store = _read_store_sync(user_id)
        done = store.get("extraction_done", {})
        pairs: list[tuple[str, str]] = []
        for node_id in node_ids:
            completed = set(done.get(node_id) or [])
            for lang in languages:
                if lang not in completed:
                    pairs.append((node_id, lang))
        return pairs
    return await asyncio.to_thread(_get)


async def clear_user_node_expressions(user_id: uuid.UUID) -> int:
    """Clear only Statement-derived expressions and extraction completion flags.

    Manually managed vocabularies live in ``user_vocab_store`` and are therefore
    intentionally outside this reset.
    """
    def _clear() -> int:
        store = _read_store_sync(user_id)
        deleted = sum(
            len(items)
            for language_map in store.get("expressions", {}).values()
            if isinstance(language_map, dict)
            for items in language_map.values()
            if isinstance(items, list)
        )
        _write_store_sync(user_id, _empty_store())
        return deleted

    return await asyncio.to_thread(_clear)


async def delete_node_expression(
    user_id: uuid.UUID,
    node_id: str,
    language: str,
    expression: str,
) -> bool:
    """Delete a single expression from a node's language bank. Returns True if found & removed."""
    expr_key = expression.strip().lower()

    def _delete() -> bool:
        store = _read_store_sync(user_id)
        lang_map = store.get("expressions", {}).get(node_id, {})
        lang_exprs = lang_map.get(language, [])
        new_exprs = [e for e in lang_exprs if (e.get("expression") or "").lower() != expr_key]
        if len(new_exprs) == len(lang_exprs):
            return False
        store["expressions"].setdefault(node_id, {})[language] = new_exprs
        # Reset extraction_done so the node can be re-extracted if all exprs are removed.
        if not new_exprs:
            done = store.get("extraction_done", {})
            done_langs = done.get(node_id, [])
            done[node_id] = [l for l in done_langs if l != language]
            store["extraction_done"] = done
        _write_store_sync(user_id, store)
        return True

    return await asyncio.to_thread(_delete)


async def delete_expression_all_origins(
    user_id: uuid.UUID,
    language: str,
    expression: str,
) -> int:
    """Delete a lemma from EVERY node's bank for a language. Returns count removed.

    The statement-bank card merges a lemma across origins, so its trash icon means
    "remove this word from my vocab" — one call clears all origins so the merged
    card doesn't reappear from a surviving copy. (Per-origin removal is done by
    deleting the source graph node instead.)
    """
    expr_key = (expression or "").strip().lower()

    def _delete() -> int:
        if not expr_key:
            return 0
        store = _read_store_sync(user_id)
        removed = 0
        for node_id, lang_map in store.get("expressions", {}).items():
            lang_exprs = lang_map.get(language)
            if not isinstance(lang_exprs, list):
                continue
            kept = [e for e in lang_exprs if (e.get("expression") or "").lower() != expr_key]
            if len(kept) == len(lang_exprs):
                continue
            removed += len(lang_exprs) - len(kept)
            lang_map[language] = kept
            # If this node has no more expressions for the language, reset its
            # done-flag so it can be re-extracted later (matches single-delete).
            if not kept:
                done = store.get("extraction_done", {})
                done_langs = done.get(node_id, [])
                done[node_id] = [l for l in done_langs if l != language]
        if removed:
            _write_store_sync(user_id, store)
        return removed

    return await asyncio.to_thread(_delete)


_CEFR_RANK = {"A1": 1, "A2": 2, "B1": 3, "B2": 4, "C1": 5, "C2": 6}


def _cefr_rank(item: dict[str, Any]) -> int:
    return _CEFR_RANK.get((item.get("cefr") or "").upper(), 3)


def _level_to_cefr_rank(level: int) -> float:
    """Convert numeric level (1-100) to a target CEFR rank (1.0–6.0)."""
    # 1-15→A1(1), 16-35→A2(2), 36-55→B1(3), 56-75→B2(4), 76-90→C1(5), 91-100→C2(6)
    if level <= 15:
        return 1.0
    if level <= 35:
        return 2.0
    if level <= 55:
        return 3.0
    if level <= 75:
        return 4.0
    if level <= 90:
        return 5.0
    return 6.0


async def pick_random_expression_for_quiz(
    user_id: uuid.UUID,
    language: str,
    target_level: int = 50,
) -> dict[str, Any] | None:
    """Pick an expression from the statement bank, weighted toward the user's level.

    Higher-level expressions get higher probability. Expressions at or above the
    user's CEFR rank get a 3× boost; those far below get reduced weight.
    """
    import random

    def _pick() -> dict[str, Any] | None:
        store = _read_store_sync(user_id)
        # Dedup by lemma so a word shared across nodes isn't weighted N× — the
        # first occurrence wins (keeps a source_node_id for provenance).
        seen: set[str] = set()
        candidates: list[dict[str, Any]] = []
        for node_id, lang_map in store.get("expressions", {}).items():
            for item in lang_map.get(language, []):
                lemma = (item.get("expression") or "").strip().lower()
                if not lemma or lemma in seen:
                    continue
                seen.add(lemma)
                candidates.append({**item, "source_node_id": node_id, "language": language})
        if not candidates:
            return None

        user_rank = _level_to_cefr_rank(target_level)

        # Weight: items at user's rank get 3×, above get 4×, below get 0.5×
        weights: list[float] = []
        for c in candidates:
            rank = _cefr_rank(c)
            if rank == 0:          # no CEFR label → neutral
                weights.append(1.0)
            elif rank >= user_rank:
                weights.append(4.0 if rank > user_rank else 3.0)
            else:
                weights.append(max(0.3, 1.0 - (user_rank - rank) * 0.3))

        return random.choices(candidates, weights=weights, k=1)[0]

    return await asyncio.to_thread(_pick)


async def read_node_expressions_snapshot(
    user_id: uuid.UUID,
    node_id: str,
) -> dict[str, Any]:
    """Read a node's full expression entry + extraction_done flags (no mutation).

    Returns a JSON-serializable snapshot ``{"entry": {...}, "extraction_done": [...]}``
    for embedding in a soft-deleted node's ``deleted_context`` so it can be restored
    verbatim. Returns ``{}`` when the node has no expressions.
    """

    def _read() -> dict[str, Any]:
        store = _read_store_sync(user_id)
        entry = store.get("expressions", {}).get(node_id)
        if not entry:
            return {}
        done = list(store.get("extraction_done", {}).get(node_id, []))
        # Deep copy so the snapshot is decoupled from the live store dict.
        return {
            "entry": json.loads(json.dumps(entry, ensure_ascii=False)),
            "extraction_done": done,
        }

    return await asyncio.to_thread(_read)


async def restore_node_expressions(
    user_id: uuid.UUID,
    node_id: str,
    snapshot: dict[str, Any],
) -> None:
    """Write a snapshot from ``read_node_expressions_snapshot`` back into the store."""
    entry = snapshot.get("entry") if isinstance(snapshot, dict) else None
    if not entry:
        return
    done = snapshot.get("extraction_done") or []

    def _write() -> None:
        store = _read_store_sync(user_id)
        store["expressions"][node_id] = entry
        if done:
            store["extraction_done"][node_id] = list(done)
        _write_store_sync(user_id, store)

    return await asyncio.to_thread(_write)


async def delete_node_all_expressions(
    user_id: uuid.UUID,
    node_id: str,
) -> int:
    """Delete ALL expressions for a specific node. Returns count removed."""

    def _delete() -> int:
        store = _read_store_sync(user_id)
        exprs = store.get("expressions", {})
        count = sum(
            len(v) for k, v in exprs.get(node_id, {}).items() if isinstance(v, list)
        )
        exprs.pop(node_id, None)
        store.get("extraction_done", {}).pop(node_id, None)
        _write_store_sync(user_id, store)
        return count

    return await asyncio.to_thread(_delete)


async def prune_expressions_not_in(
    user_id: uuid.UUID,
    valid_node_ids: set[str],
) -> int:
    """Drop expression entries whose node no longer exists.

    Reconciliation safety net: the per-node store is keyed by Statement node id, but
    bulk node deletions (e.g. clearing the whole graph) bypass the per-node cleanup
    and leave the expressions orphaned. Removing every key not in ``valid_node_ids``
    (the user's live node ids) cleans those up — pass an empty set to wipe all.
    Returns the number of expressions removed.
    """

    def _prune() -> int:
        store = _read_store_sync(user_id)
        exprs = store.get("expressions", {})
        done = store.get("extraction_done", {})
        removed = 0
        for node_id in list(exprs.keys()):
            if node_id in valid_node_ids:
                continue
            removed += sum(
                len(v) for v in exprs[node_id].values() if isinstance(v, list)
            )
            exprs.pop(node_id, None)
            done.pop(node_id, None)
        if removed:
            _write_store_sync(user_id, store)
        return removed

    return await asyncio.to_thread(_prune)


async def delete_all_language_expressions(
    user_id: uuid.UUID,
    language: str,
) -> int:
    """Delete ALL expressions for a language across all nodes. Returns count removed."""

    def _delete() -> int:
        store = _read_store_sync(user_id)
        count = 0
        for node_id, lang_map in store.get("expressions", {}).items():
            if language in lang_map:
                count += len(lang_map[language])
                lang_map.pop(language)
        # Reset extraction_done flags for this language
        done = store.get("extraction_done", {})
        for node_id in list(done.keys()):
            done[node_id] = [l for l in done[node_id] if l != language]
        _write_store_sync(user_id, store)
        return count

    return await asyncio.to_thread(_delete)
