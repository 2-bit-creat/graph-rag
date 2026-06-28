"""Tests for IELTS Academic vocab bank."""

import json
from pathlib import Path

from app.ielts_vocab_bank import (
    _EMBEDDED_FALLBACK,
    get_ielts_entries,
    parse_ielts_txt,
    reset_ielts_cache,
)


def test_parse_ielts_txt_multiline():
    text = """A

abandon: lacking restraint or control
absorption: process of absorbing nutrients; state of mental
concentration
ability: capacity; skill
"""
    entries = parse_ielts_txt(text)
    assert len(entries) == 3
    assert entries[0]["word"] == "abandon"
    assert entries[1]["word"] == "absorption"
    assert "concentration" in entries[1]["definition"]
    assert entries[2]["word"] == "ability"


def test_get_ielts_entries_from_fixture(tmp_path, monkeypatch):
    reset_ielts_cache()
    vocab_dir = tmp_path / "vocab"
    vocab_dir.mkdir()
    sample = [
        {"word": "abandon", "definition": "give up"},
        {"word": "zeal", "definition": "enthusiasm"},
    ]
    (vocab_dir / "ielts_4000.json").write_text(json.dumps(sample), encoding="utf-8")
    monkeypatch.setattr("app.ielts_vocab_bank._VOCAB_DIR", vocab_dir)
    monkeypatch.setattr("app.ielts_vocab_bank._entries", None)

    entries = get_ielts_entries()
    assert len(entries) == 2
    assert entries[0]["word"] == "abandon"


def test_embedded_fallback_nonempty():
    assert len(_EMBEDDED_FALLBACK) >= 3


if __name__ == "__main__":
    test_parse_ielts_txt_multiline()
    test_embedded_fallback_nonempty()
    print("OK")
