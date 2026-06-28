"""Tests for per-user vocabulary store (no pytest required)."""

import asyncio
import json
import tempfile
import uuid
from pathlib import Path

from app.user_vocab_store import (
    DEFAULT_VOCAB_ID,
    IELTS_VOCAB_ID,
    VocabularyConflictError,
    VocabularyForbiddenError,
    VocabularyNotFoundError,
    add_word,
    create_vocabulary,
    delete_vocabulary,
    delete_word,
    get_vocab_seed,
    get_vocabulary,
    list_vocabularies,
    update_vocabulary,
    update_word,
)

DEV_USER = uuid.UUID("00000000-0000-0000-0000-000000000001")


class _FakeSettings:
    def __init__(self, upload_dir: str) -> None:
        self.upload_dir = upload_dir


def _patch_upload_dir(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setattr(
        "app.user_vocab_store.get_settings",
        lambda: _FakeSettings(str(tmp_path)),
    )


def _patch_ielts_entries(monkeypatch) -> None:
    sample = [
        {"word": "abandon", "definition": "give up"},
        {"word": "zeal", "definition": "enthusiasm"},
    ]
    monkeypatch.setattr(
        "app.ielts_vocab_bank.get_ielts_entries",
        lambda: sample,
    )


async def test_list_includes_default_and_ielts(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    items = await list_vocabularies(DEV_USER)
    assert items[0]["id"] == DEFAULT_VOCAB_ID
    assert items[0]["is_default"] is True
    assert items[1]["id"] == IELTS_VOCAB_ID
    assert items[1]["is_default"] is False
    assert items[1]["word_count"] == 2


async def test_crud_roundtrip(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    created = await create_vocabulary(DEV_USER, name="Travel", description="trip words")
    vocab_id = created["id"]
    assert created["word_count"] == 0

    word = await add_word(
        DEV_USER,
        vocab_id,
        word="Itinerary",
        meaning="여행 일정",
    )
    assert word["word"] == "itinerary"

    detail = await get_vocabulary(DEV_USER, vocab_id)
    assert detail["word_count"] == 1
    assert detail["words"][0]["meaning"] == "여행 일정"

    await delete_word(DEV_USER, vocab_id, "itinerary")
    detail2 = await get_vocabulary(DEV_USER, vocab_id)
    assert detail2["word_count"] == 0

    await delete_vocabulary(DEV_USER, vocab_id)
    items = await list_vocabularies(DEV_USER)
    assert all(i["id"] != vocab_id for i in items)


async def test_default_protected(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    try:
        await delete_vocabulary(DEV_USER, DEFAULT_VOCAB_ID)
        raise AssertionError("expected forbidden")
    except VocabularyForbiddenError:
        pass
    try:
        await add_word(DEV_USER, DEFAULT_VOCAB_ID, word="x", meaning="y")
        raise AssertionError("expected forbidden")
    except VocabularyForbiddenError:
        pass


async def test_ielts_crud_allowed(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    await list_vocabularies(DEV_USER)

    await delete_word(DEV_USER, IELTS_VOCAB_ID, "abandon")
    detail = await get_vocabulary(DEV_USER, IELTS_VOCAB_ID)
    assert detail["word_count"] == 1
    assert detail["words"][0]["word"] == "zeal"

    await add_word(DEV_USER, IELTS_VOCAB_ID, word="custom", meaning="커스텀")
    detail2 = await get_vocabulary(DEV_USER, IELTS_VOCAB_ID)
    assert detail2["word_count"] == 2

    await delete_vocabulary(DEV_USER, IELTS_VOCAB_ID)
    items = await list_vocabularies(DEV_USER)
    assert all(i["id"] != IELTS_VOCAB_ID for i in items)


async def test_ielts_seed_ignores_level(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    await list_vocabularies(DEV_USER)

    seed_low = await get_vocab_seed(DEV_USER, IELTS_VOCAB_ID, 1)
    seed_high = await get_vocab_seed(DEV_USER, IELTS_VOCAB_ID, 100)
    assert seed_low["word"] in ("abandon", "zeal")
    assert seed_high["word"] in ("abandon", "zeal")
    assert seed_low["cefr"] == "custom"
    assert seed_high["cefr"] == "custom"


async def test_duplicate_word_conflict(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    created = await create_vocabulary(DEV_USER, name="Dup")
    vid = created["id"]
    await add_word(DEV_USER, vid, word="hello", meaning="안녕")
    try:
        await add_word(DEV_USER, vid, word="Hello", meaning="다시")
        raise AssertionError("expected conflict")
    except VocabularyConflictError:
        pass


async def test_empty_vocab_seed_fails(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    created = await create_vocabulary(DEV_USER, name="Empty")
    try:
        await get_vocab_seed(DEV_USER, created["id"], 50)
        raise AssertionError("expected empty vocab error")
    except ValueError as exc:
        assert "no words" in str(exc).lower()


async def test_vocab_seed_increments_review_count(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    created = await create_vocabulary(DEV_USER, name="Review")
    vid = created["id"]
    await add_word(DEV_USER, vid, word="alpha", meaning="알파")
    await add_word(DEV_USER, vid, word="beta", meaning="베타")

    seed = await get_vocab_seed(DEV_USER, vid, 50)
    assert seed["word"] in ("alpha", "beta")
    assert seed["cefr"] == "custom"

    store_path = tmp_path / str(DEV_USER) / "user_vocabularies.json"
    data = json.loads(store_path.read_text(encoding="utf-8"))
    vocab = next(v for v in data["vocabularies"] if v["id"] == vid)
    picked = next(w for w in vocab["words"] if w["word"] == seed["word"])
    assert picked["review_count"] == 1


async def test_vocab_not_found(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    try:
        await get_vocabulary(DEV_USER, "missing-id")
        raise AssertionError("expected not found")
    except VocabularyNotFoundError:
        pass


async def test_update_vocab_and_word(tmp_path: Path, monkeypatch) -> None:
    _patch_upload_dir(monkeypatch, tmp_path)
    _patch_ielts_entries(monkeypatch)
    created = await create_vocabulary(DEV_USER, name="Before", description="desc")
    vid = created["id"]
    await add_word(DEV_USER, vid, word="alpha", meaning="알파")

    updated_vocab = await update_vocabulary(DEV_USER, vid, name="After", description="new desc")
    assert updated_vocab["name"] == "After"
    assert updated_vocab["description"] == "new desc"

    updated_word = await update_word(DEV_USER, vid, "alpha", meaning="수정된 뜻")
    assert updated_word["meaning"] == "수정된 뜻"

    detail = await get_vocabulary(DEV_USER, vid)
    assert detail["name"] == "After"
    assert detail["words"][0]["meaning"] == "수정된 뜻"


class _Monkey:
    def setattr(self, target: str, value) -> None:
        import importlib

        mod_name, attr = target.rsplit(".", 1)
        mod = importlib.import_module(mod_name)
        setattr(mod, attr, value)


async def _run_all() -> None:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        monkey = _Monkey()
        await test_list_includes_default_and_ielts(tmp, monkey)
        await test_crud_roundtrip(tmp, monkey)
        await test_default_protected(tmp, monkey)
        await test_ielts_seed_ignores_level(tmp, monkey)
        await test_ielts_crud_allowed(tmp, monkey)
        await test_duplicate_word_conflict(tmp, monkey)
        await test_empty_vocab_seed_fails(tmp, monkey)
        await test_vocab_seed_increments_review_count(tmp, monkey)
        await test_vocab_not_found(tmp, monkey)
        await test_update_vocab_and_word(tmp, monkey)


def main() -> None:
    asyncio.run(_run_all())
    print("All user vocabulary tests passed.")


if __name__ == "__main__":
    main()
