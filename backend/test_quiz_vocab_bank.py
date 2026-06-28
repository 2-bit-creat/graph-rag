"""Tests for Oxford CEFR vocab bank."""

import json
from pathlib import Path

from app.quiz_vocab_bank import (
    _EMBEDDED_FALLBACK,
    _parse_oxford_json,
    _pool_for_level,
    get_random_vocab_seed,
    level_to_cefr,
    rebuild_vocab_cache,
    reset_vocab_cache,
)


def test_level_to_cefr_tiers():
    assert level_to_cefr(10) == "a1"
    assert level_to_cefr(20) == "a1"
    assert level_to_cefr(21) == "a2"
    assert level_to_cefr(40) == "a2"
    assert level_to_cefr(41) == "b1"
    assert level_to_cefr(60) == "b1"
    assert level_to_cefr(61) == "b2"
    assert level_to_cefr(75) == "b2"
    assert level_to_cefr(76) == "c1"
    assert level_to_cefr(97) == "c1"


def test_parse_oxford_json_cefr(tmp_path: Path):
    sample = {
        "0": {"word": "a", "cefr": "a1"},
        "1": {"word": "abandon", "cefr": "b2"},
        "2": {"word": "ability", "cefr": "a2"},
        "3": {"word": "sophisticated", "cefr": "c1"},
    }
    path = tmp_path / "sample.json"
    path.write_text(json.dumps(sample), encoding="utf-8")
    mapping = _parse_oxford_json(path)
    assert mapping["a"] == "a1"
    assert mapping["abandon"] == "b2"
    assert mapping["sophisticated"] == "c1"


def test_get_random_vocab_seed_from_fixture(tmp_path, monkeypatch):
    reset_vocab_cache()
    vocab_dir = tmp_path / "vocab"
    vocab_dir.mkdir()
    sample = {
        "0": {"word": "hello", "cefr": "a1"},
        "1": {"word": "achieve", "cefr": "b1"},
        "2": {"word": "precarious", "cefr": "c1"},
    }
    (vocab_dir / "oxford_5000_cefr.json").write_text(json.dumps(sample), encoding="utf-8")
    monkeypatch.setattr("app.quiz_vocab_bank._VOCAB_DIR", vocab_dir)
    monkeypatch.setattr("app.quiz_vocab_bank._pools", None)

    seed = get_random_vocab_seed(90)
    assert seed["word"] == "precarious"
    assert seed["cefr"] == "c1"

    seed_low = get_random_vocab_seed(15)
    assert seed_low["word"] == "hello"
    assert seed_low["cefr"] == "a1"


def test_pool_fallback_to_lower_cefr(tmp_path, monkeypatch):
    reset_vocab_cache()
    vocab_dir = tmp_path / "vocab"
    vocab_dir.mkdir()
    pools = {"a1": ["alpha"], "a2": [], "b1": [], "b2": [], "c1": [], "c2": []}
    (vocab_dir / "cefr_pools.json").write_text(json.dumps(pools), encoding="utf-8")
    monkeypatch.setattr("app.quiz_vocab_bank._VOCAB_DIR", vocab_dir)
    monkeypatch.setattr("app.quiz_vocab_bank._pools", None)

    cefr, pool = _pool_for_level(40)
    assert cefr == "a1"
    assert pool == ["alpha"]


def test_embedded_fallback_nonempty():
    for cefr in ("a1", "a2", "b1", "b2", "c1"):
        assert len(_EMBEDDED_FALLBACK[cefr]) >= 3


if __name__ == "__main__":
    test_level_to_cefr_tiers()
    test_parse_oxford_json_cefr(Path("."))
    test_embedded_fallback_nonempty()
    print("OK")
