"""Per-user custom vocabulary lists stored as JSON under upload_dir."""

from __future__ import annotations

import asyncio
import json
import random
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import unquote

from .config import get_settings

DEFAULT_VOCAB_ID = "default"          # legacy alias → english
DEFAULT_VOCAB_ID_ENGLISH = "default:english"
DEFAULT_VOCAB_ID_GERMAN = "default:german"
IELTS_VOCAB_ID = "ielts"
STATEMENT_VOCAB_ID = "statement_expressions"
# Expressions the learner fumbled during tutor composition drills. A system
# vocabulary (read-mostly): populated by the tutor, browsable in the vocab hub,
# and re-fed into 'review' drills to close the confused → practiced loop.
# Surfaced per language as "tutor_conversation:<language>"; the bare id is a
# legacy alias meaning "all languages".
TUTOR_VOCAB_ID = "tutor_conversation"

_TUTOR_LANG_DISPLAY = {
    "english": "영어", "german": "독일어", "japanese": "일본어",
    "chinese": "중국어", "spanish": "스페인어", "french": "프랑스어",
}

_DEFAULT_IDS = {DEFAULT_VOCAB_ID, DEFAULT_VOCAB_ID_ENGLISH, DEFAULT_VOCAB_ID_GERMAN}
_STORE_VERSION = 1
_FILENAME = "user_vocabularies.json"


class VocabularyNotFoundError(ValueError):
    pass


class VocabularyForbiddenError(ValueError):
    pass


class VocabularyConflictError(ValueError):
    pass


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _store_path(user_id: uuid.UUID) -> Path:
    root = Path(get_settings().upload_dir) / str(user_id)
    root.mkdir(parents=True, exist_ok=True)
    return root / _FILENAME


def _empty_store() -> dict[str, Any]:
    return {"version": _STORE_VERSION, "vocabularies": []}


def _normalize_word(raw: str) -> str:
    return raw.strip().lower()


def _read_store_sync(user_id: uuid.UUID) -> dict[str, Any]:
    path = _store_path(user_id)
    if not path.is_file():
        return _empty_store()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return _empty_store()
    if data.get("version") != _STORE_VERSION:
        data["version"] = _STORE_VERSION
    if not isinstance(data.get("vocabularies"), list):
        data["vocabularies"] = []
    return data


def _write_store_sync(user_id: uuid.UUID, data: dict[str, Any]) -> None:
    path = _store_path(user_id)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _find_vocab(store: dict[str, Any], vocab_id: str) -> dict[str, Any] | None:
    for vocab in store.get("vocabularies") or []:
        if isinstance(vocab, dict) and vocab.get("id") == vocab_id:
            return vocab
    return None


def _vocab_summary(vocab: dict[str, Any]) -> dict[str, Any]:
    words = vocab.get("words") or []
    return {
        "id": vocab["id"],
        "name": vocab.get("name", ""),
        "description": vocab.get("description", ""),
        "created_at": vocab.get("created_at"),
        "word_count": len(words) if isinstance(words, list) else 0,
        "is_default": False,
        "language": vocab.get("language", "english"),
    }


def _default_english_summary() -> dict[str, Any]:
    from .quiz_vocab_bank import estimate_default_word_count

    return {
        "id": DEFAULT_VOCAB_ID_ENGLISH,
        "name": "Oxford CEFR 5000",
        "description": "Oxford CEFR 단어 풀에서 레벨 기반 랜덤 선택",
        "created_at": None,
        "word_count": estimate_default_word_count(),
        "is_default": True,
        "language": "english",
    }


def _default_german_summary() -> dict[str, Any]:
    from .german_vocab_bank import estimate_default_word_count

    return {
        "id": DEFAULT_VOCAB_ID_GERMAN,
        "name": "Goethe CEFR Wortschatz",
        "description": "Goethe-Institut 기반 독일어 CEFR 단어 풀에서 레벨 기반 랜덤 선택",
        "created_at": None,
        "word_count": estimate_default_word_count(),
        "is_default": True,
        "language": "german",
    }


def _default_summary() -> dict[str, Any]:
    """Legacy alias — returns English default."""
    return _default_english_summary()


def _build_ielts_vocab() -> dict[str, Any]:
    from .ielts_vocab_bank import get_ielts_entries

    seeded_at = _utc_now()
    words = [
        {
            "word": entry["word"],
            "meaning": entry.get("definition") or "",
            "added_at": seeded_at,
            "review_count": 0,
            "linked_diary_id": None,
        }
        for entry in get_ielts_entries()
    ]
    return {
        "id": IELTS_VOCAB_ID,
        "name": "IELTS Academic 4000",
        "description": "IELTS Academic Word List — 일괄 추가된 단어장 (편집·삭제 가능)",
        "created_at": seeded_at,
        "words": words,
    }


def _ensure_ielts_vocab_sync(user_id: uuid.UUID) -> dict[str, Any]:
    store = _read_store_sync(user_id)
    if store.get("ielts_bootstrapped"):
        return store
    if _find_vocab(store, IELTS_VOCAB_ID) is not None:
        store["ielts_bootstrapped"] = True
        _write_store_sync(user_id, store)
        return store
    store.setdefault("vocabularies", []).insert(0, _build_ielts_vocab())
    store["ielts_bootstrapped"] = True
    _write_store_sync(user_id, store)
    return store


def _statement_vocab_summary(store: dict[str, Any]) -> dict[str, Any]:
    words = store.get("statement_expressions") or []
    return {
        "id": STATEMENT_VOCAB_ID,
        "name": "Statement 추출 표현",
        "description": "일기/대화 Statement에서 자동 추출된 영어 표현 (읽기 전용)",
        "created_at": None,
        "word_count": len(words),
        "is_default": False,
        "is_system": True,
    }


def _sorted_user_vocabularies(store: dict[str, Any]) -> list[dict[str, Any]]:
    vocabs = [
        v for v in store.get("vocabularies") or []
        if isinstance(v, dict) and v.get("id")
    ]
    vocabs.sort(
        key=lambda v: (
            0 if v.get("id") == IELTS_VOCAB_ID else 1,
            v.get("name") or "",
        )
    )
    return vocabs


async def list_vocabularies(user_id: uuid.UUID) -> list[dict[str, Any]]:
    store = await asyncio.to_thread(_ensure_ielts_vocab_sync, user_id)
    # Skip legacy statement_expressions (replaced by node_expression_store per-language)
    custom = [
        _vocab_summary(v) for v in _sorted_user_vocabularies(store)
        if v.get("id") not in (STATEMENT_VOCAB_ID,)
    ]
    # Return both language defaults + user-created custom sets
    # statement_bank:* entries are appended by the router (vocabulary.py)
    result = [_default_english_summary(), _default_german_summary(), *custom]
    # Surface the tutor vocabulary once it has collected anything — one entry
    # per language so learners never see mixed-language word lists.
    result.extend(_tutor_vocab_summaries(store))
    return result


def _default_words_english() -> list[dict[str, Any]]:
    from .quiz_vocab_bank import _get_pools
    pools = _get_pools()
    words: list[dict[str, Any]] = []
    for cefr in ("a1", "a2", "b1", "b2", "c1", "c2"):
        for word in pools.get(cefr) or []:
            words.append({"word": word, "meaning": "", "cefr": cefr.upper()})
    return words


def _default_words_german() -> list[dict[str, Any]]:
    from .german_vocab_bank import _get_pools
    pools = _get_pools()
    words: list[dict[str, Any]] = []
    for cefr in ("a1", "a2", "b1", "b2", "c1", "c2"):
        for word in pools.get(cefr) or []:
            words.append({"word": word, "meaning": "", "cefr": cefr.upper()})
    return words


async def get_vocabulary(user_id: uuid.UUID, vocab_id: str) -> dict[str, Any]:
    if vocab_id in _DEFAULT_IDS:
        is_german = vocab_id == DEFAULT_VOCAB_ID_GERMAN
        summary = _default_german_summary() if is_german else _default_english_summary()
        summary["words"] = await asyncio.to_thread(
            _default_words_german if is_german else _default_words_english
        )
        return summary

    store = await asyncio.to_thread(_ensure_ielts_vocab_sync, user_id)

    if vocab_id == STATEMENT_VOCAB_ID:
        words = store.get("statement_expressions") or []
        summary = _statement_vocab_summary(store)
        summary["words"] = list(words)
        return summary

    if vocab_id == TUTOR_VOCAB_ID or vocab_id.startswith(f"{TUTOR_VOCAB_ID}:"):
        language = (
            vocab_id.split(":", 1)[1] if ":" in vocab_id else None
        ) or None
        summary = _tutor_vocab_summary(store, language)
        items = [
            e for e in (store.get("tutor_expressions") or [])
            if isinstance(e, dict)
            and (language is None or (e.get("language") or "english") == language)
        ]
        summary["words"] = list(reversed(items))
        return summary

    vocab = _find_vocab(store, vocab_id)
    if vocab is None:
        raise VocabularyNotFoundError(f"Vocabulary not found: {vocab_id}")
    return {
        **_vocab_summary(vocab),
        "words": list(vocab.get("words") or []),
    }


async def create_vocabulary(
    user_id: uuid.UUID,
    *,
    name: str,
    description: str = "",
) -> dict[str, Any]:
    name = name.strip()
    if not name:
        raise ValueError("Vocabulary name is required")

    def _create() -> dict[str, Any]:
        store = _ensure_ielts_vocab_sync(user_id)
        vocab_id = str(uuid.uuid4())
        vocab = {
            "id": vocab_id,
            "name": name,
            "description": description.strip(),
            "created_at": _utc_now(),
            "words": [],
        }
        store.setdefault("vocabularies", []).append(vocab)
        _write_store_sync(user_id, store)
        return _vocab_summary(vocab)

    return await asyncio.to_thread(_create)


async def upsert_statement_expressions(
    user_id: uuid.UUID,
    expressions: list[dict[str, Any]],
) -> None:
    """Merge newly extracted Statement expressions into the system bank (no duplicates)."""
    if not expressions:
        return

    def _upsert() -> None:
        store = _ensure_ielts_vocab_sync(user_id)
        existing: list[dict[str, Any]] = store.get("statement_expressions") or []
        seen_exprs = {e.get("expression", "").lower() for e in existing if isinstance(e, dict)}
        now = _utc_now()
        for item in expressions:
            expr = (item.get("expression") or "").strip().lower()
            if not expr or expr in seen_exprs:
                continue
            existing.append({
                "expression": expr,
                "meaning_ko": (item.get("meaning_ko") or "").strip(),
                "example_en": (item.get("example_en") or "").strip(),
                "source_node_id": item.get("source_node_id") or "",
                "source_node_name": (item.get("source_node_name") or "").strip(),
                "added_at": now,
            })
            seen_exprs.add(expr)
        store["statement_expressions"] = existing
        _write_store_sync(user_id, store)

    await asyncio.to_thread(_upsert)


# ── Tutor conversation vocabulary ─────────────────────────────────────────────


def _tutor_vocab_summary(
    store: dict[str, Any], language: str | None = None
) -> dict[str, Any]:
    words = [
        e for e in (store.get("tutor_expressions") or [])
        if isinstance(e, dict)
        and (language is None or (e.get("language") or "english") == language)
    ]
    if language:
        label = _TUTOR_LANG_DISPLAY.get(language, language.title())
        name = f"튜터와 배운 표현 ({label})"
        vocab_id = f"{TUTOR_VOCAB_ID}:{language}"
    else:
        name = "튜터와 배운 표현"
        vocab_id = TUTOR_VOCAB_ID
    return {
        "id": vocab_id,
        "name": name,
        "description": "작문 드릴에서 헷갈렸던 표현 모음 (튜터가 추천 · 복습에 재출제)",
        "created_at": None,
        "word_count": len(words),
        "is_default": False,
        "is_system": True,
        "language": language or "mixed",
    }


def _tutor_vocab_summaries(store: dict[str, Any]) -> list[dict[str, Any]]:
    """One summary per language present in the tutor vocabulary."""
    languages = sorted({
        (e.get("language") or "english")
        for e in (store.get("tutor_expressions") or [])
        if isinstance(e, dict)
    })
    return [_tutor_vocab_summary(store, lang) for lang in languages]


async def list_tutor_expressions(
    user_id: uuid.UUID, language: str | None = None
) -> list[dict[str, Any]]:
    """Newest-first list of expressions saved from tutor drills.

    ``language`` filters to a single target language (None = all).
    """
    lang = (language or "").strip().lower() or None

    def _get() -> list[dict[str, Any]]:
        store = _read_store_sync(user_id)
        items = [
            e for e in (store.get("tutor_expressions") or [])
            if isinstance(e, dict)
            and (lang is None or (e.get("language") or "english") == lang)
        ]
        return list(reversed(items))

    return await asyncio.to_thread(_get)


async def save_tutor_expression(
    user_id: uuid.UUID,
    *,
    expression: str,
    meaning: str = "",
    example: str = "",
    language: str = "english",
    note: str = "",
    prompt_ko: str = "",
    user_attempt: str = "",
) -> dict[str, Any]:
    """Save (or refresh) a confused expression into the tutor vocabulary.

    Dedupes by (language, lowercased expression). Stores the drill context —
    the native-language prompt and the learner's attempt — so the entry can later
    remind them *how* they got it wrong, not just the word.
    """
    expr = expression.strip()
    if not expr:
        raise ValueError("Expression is required")
    key = expr.lower()
    lang = (language or "english").strip().lower()

    def _save() -> dict[str, Any]:
        store = _read_store_sync(user_id)
        items: list[dict[str, Any]] = store.get("tutor_expressions") or []
        for existing in items:
            if (
                isinstance(existing, dict)
                and (existing.get("word") or "").lower() == key
                and (existing.get("language") or "english") == lang
            ):
                # Refresh gaps + bump last-seen without duplicating.
                if meaning.strip():
                    existing["meaning"] = meaning.strip()
                if example.strip():
                    existing["example"] = example.strip()
                existing["updated_at"] = _utc_now()
                _write_store_sync(user_id, store)
                return existing
        entry = {
            "word": expr,
            "meaning": meaning.strip(),
            "example": example.strip(),
            "language": lang,
            "note": note.strip(),
            "prompt_ko": prompt_ko.strip(),
            "user_attempt": user_attempt.strip(),
            "added_at": _utc_now(),
            "review_count": 0,
            "source": "tutor",
        }
        items.append(entry)
        store["tutor_expressions"] = items
        _write_store_sync(user_id, store)
        return entry

    return await asyncio.to_thread(_save)


# Recent tutor drill rounds — a lightweight activity log (NOT the knowledge
# graph). Lives in its own file so the vocab store stays focused. Capped so it
# never grows unbounded.
_TUTOR_HISTORY_FILENAME = "tutor_history.json"
_TUTOR_HISTORY_CAP = 60


def _tutor_history_path(user_id: uuid.UUID) -> Path:
    root = Path(get_settings().upload_dir) / str(user_id)
    root.mkdir(parents=True, exist_ok=True)
    return root / _TUTOR_HISTORY_FILENAME


def _read_tutor_history_sync(user_id: uuid.UUID) -> list[dict[str, Any]]:
    path = _tutor_history_path(user_id)
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    return [x for x in data if isinstance(x, dict)] if isinstance(data, list) else []


async def append_tutor_history(user_id: uuid.UUID, record: dict[str, Any]) -> None:
    """Append one completed drill round; keep only the most recent rounds."""
    def _append() -> None:
        items = _read_tutor_history_sync(user_id)
        items.append({**record, "created_at": _utc_now()})
        if len(items) > _TUTOR_HISTORY_CAP:
            items = items[-_TUTOR_HISTORY_CAP:]
        _tutor_history_path(user_id).write_text(
            json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    await asyncio.to_thread(_append)


async def list_tutor_history(
    user_id: uuid.UUID, limit: int = 20
) -> list[dict[str, Any]]:
    """Most-recent-first drill rounds."""
    def _get() -> list[dict[str, Any]]:
        items = _read_tutor_history_sync(user_id)
        return list(reversed(items))[: max(0, limit)]

    return await asyncio.to_thread(_get)


async def delete_tutor_expression(
    user_id: uuid.UUID, expression: str, language: str = "english"
) -> bool:
    key = expression.strip().lower()
    lang = (language or "english").strip().lower()

    def _delete() -> bool:
        store = _read_store_sync(user_id)
        items = store.get("tutor_expressions") or []
        new_items = [
            e for e in items
            if not (
                isinstance(e, dict)
                and (e.get("word") or "").lower() == key
                and (e.get("language") or "english") == lang
            )
        ]
        if len(new_items) == len(items):
            return False
        store["tutor_expressions"] = new_items
        _write_store_sync(user_id, store)
        return True

    return await asyncio.to_thread(_delete)


async def delete_vocabulary(user_id: uuid.UUID, vocab_id: str) -> None:
    if (
        vocab_id in _DEFAULT_IDS
        or vocab_id in (STATEMENT_VOCAB_ID, TUTOR_VOCAB_ID)
        or vocab_id.startswith(f"{TUTOR_VOCAB_ID}:")
    ):
        raise VocabularyForbiddenError("Cannot delete this system vocabulary")

    def _delete() -> None:
        store = _read_store_sync(user_id)
        vocabularies = store.get("vocabularies") or []
        new_list = [v for v in vocabularies if isinstance(v, dict) and v.get("id") != vocab_id]
        if len(new_list) == len(vocabularies):
            raise VocabularyNotFoundError(f"Vocabulary not found: {vocab_id}")
        store["vocabularies"] = new_list
        _write_store_sync(user_id, store)

    await asyncio.to_thread(_delete)


async def update_vocabulary(
    user_id: uuid.UUID,
    vocab_id: str,
    *,
    name: str | None = None,
    description: str | None = None,
) -> dict[str, Any]:
    if vocab_id in _DEFAULT_IDS or vocab_id == STATEMENT_VOCAB_ID:
        raise VocabularyForbiddenError("Cannot edit this system vocabulary")

    if name is not None:
        name = name.strip()
        if not name:
            raise ValueError("Vocabulary name is required")
    if description is not None:
        description = description.strip()

    def _update() -> dict[str, Any]:
        store = _ensure_ielts_vocab_sync(user_id)
        vocab = _find_vocab(store, vocab_id)
        if vocab is None:
            raise VocabularyNotFoundError(f"Vocabulary not found: {vocab_id}")
        if name is not None:
            vocab["name"] = name
        if description is not None:
            vocab["description"] = description
        _write_store_sync(user_id, store)
        return _vocab_summary(vocab)

    return await asyncio.to_thread(_update)


async def add_word(
    user_id: uuid.UUID,
    vocab_id: str,
    *,
    word: str,
    meaning: str,
    linked_diary_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    if vocab_id in _DEFAULT_IDS or vocab_id == STATEMENT_VOCAB_ID:
        raise VocabularyForbiddenError("Cannot add words to this system vocabulary")

    normalized = _normalize_word(word)
    if not normalized:
        raise ValueError("Word is required")
    meaning = meaning.strip()
    if not meaning:
        raise ValueError("Meaning is required")

    def _add() -> dict[str, Any]:
        store = _ensure_ielts_vocab_sync(user_id)
        vocab = _find_vocab(store, vocab_id)
        if vocab is None:
            raise VocabularyNotFoundError(f"Vocabulary not found: {vocab_id}")
        words = vocab.setdefault("words", [])
        for existing in words:
            if isinstance(existing, dict) and _normalize_word(existing.get("word", "")) == normalized:
                raise VocabularyConflictError(f"Word already exists: {normalized}")
        entry = {
            "word": normalized,
            "meaning": meaning,
            "added_at": _utc_now(),
            "review_count": 0,
            "linked_diary_id": str(linked_diary_id) if linked_diary_id else None,
        }
        words.append(entry)
        _write_store_sync(user_id, store)
        return entry

    return await asyncio.to_thread(_add)


async def delete_word(user_id: uuid.UUID, vocab_id: str, word: str) -> None:
    if vocab_id in _DEFAULT_IDS or vocab_id == STATEMENT_VOCAB_ID:
        raise VocabularyForbiddenError("Cannot delete words from this system vocabulary")

    normalized = _normalize_word(unquote(word))
    if not normalized:
        raise ValueError("Word is required")

    def _delete() -> None:
        store = _ensure_ielts_vocab_sync(user_id)
        vocab = _find_vocab(store, vocab_id)
        if vocab is None:
            raise VocabularyNotFoundError(f"Vocabulary not found: {vocab_id}")
        words = vocab.get("words") or []
        new_words = [
            w for w in words
            if not (isinstance(w, dict) and _normalize_word(w.get("word", "")) == normalized)
        ]
        if len(new_words) == len(words):
            raise VocabularyNotFoundError(f"Word not found: {normalized}")
        vocab["words"] = new_words
        _write_store_sync(user_id, store)

    await asyncio.to_thread(_delete)


async def update_word(
    user_id: uuid.UUID,
    vocab_id: str,
    word: str,
    *,
    meaning: str,
) -> dict[str, Any]:
    if vocab_id in _DEFAULT_IDS or vocab_id == STATEMENT_VOCAB_ID:
        raise VocabularyForbiddenError("Cannot edit words in this system vocabulary")

    normalized = _normalize_word(unquote(word))
    if not normalized:
        raise ValueError("Word is required")
    meaning = meaning.strip()
    if not meaning:
        raise ValueError("Meaning is required")

    def _update() -> dict[str, Any]:
        store = _ensure_ielts_vocab_sync(user_id)
        vocab = _find_vocab(store, vocab_id)
        if vocab is None:
            raise VocabularyNotFoundError(f"Vocabulary not found: {vocab_id}")
        words = vocab.get("words") or []
        for existing in words:
            if isinstance(existing, dict) and _normalize_word(existing.get("word", "")) == normalized:
                existing["meaning"] = meaning
                _write_store_sync(user_id, store)
                return existing
        raise VocabularyNotFoundError(f"Word not found: {normalized}")

    return await asyncio.to_thread(_update)


def _pick_custom_seed_sync(user_id: uuid.UUID, vocab_id: str) -> dict[str, str]:
    store = _ensure_ielts_vocab_sync(user_id)
    vocab = _find_vocab(store, vocab_id)
    if vocab is None:
        raise VocabularyNotFoundError(f"Vocabulary not found: {vocab_id}")
    words = [w for w in (vocab.get("words") or []) if isinstance(w, dict) and w.get("word")]
    if not words:
        raise ValueError("Vocabulary has no words")

    chosen = random.choice(words)
    chosen["review_count"] = int(chosen.get("review_count") or 0) + 1
    _write_store_sync(user_id, store)
    return {"word": chosen["word"], "cefr": "custom", "vocab_id": vocab_id}


async def get_vocab_seed(
    user_id: uuid.UUID,
    vocab_id: str,
    user_level: int,
    language: str = "english",
) -> dict[str, str]:
    if vocab_id in _DEFAULT_IDS:
        # Derive language from vocab_id first, then fall back to caller-supplied language
        if vocab_id == DEFAULT_VOCAB_ID_GERMAN:
            from .german_vocab_bank import get_random_vocab_seed
        elif vocab_id == DEFAULT_VOCAB_ID_ENGLISH or vocab_id == DEFAULT_VOCAB_ID:
            from .quiz_vocab_bank import get_random_vocab_seed
        elif language.lower() == "german":
            from .german_vocab_bank import get_random_vocab_seed
        else:
            from .quiz_vocab_bank import get_random_vocab_seed

        seed = get_random_vocab_seed(user_level)
        seed["vocab_id"] = vocab_id
        return seed
    return await asyncio.to_thread(_pick_custom_seed_sync, user_id, vocab_id)
