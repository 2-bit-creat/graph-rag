"""Tests for central language allowlists."""

from __future__ import annotations

import pytest

from app.language_config import (
    ALLOWED_NATIVE,
    ALLOWED_TARGET,
    filter_target_languages,
    validate_native,
    validate_target_list,
)
from app.crud import get_effective_target_languages


def test_allowed_sets():
    assert ALLOWED_NATIVE == frozenset({"korean", "english"})
    assert ALLOWED_TARGET == frozenset({"english", "korean", "german"})


def test_filter_target_languages():
    assert filter_target_languages(["english", "japanese", "german"]) == ["english", "german"]
    assert filter_target_languages([]) == ["english"]


def test_validate_native_rejects_unknown():
    with pytest.raises(ValueError):
        validate_native("japanese")


def test_validate_target_list():
    assert validate_target_list(["english", "korean"]) == ["english", "korean"]


class _UserStub:
    target_languages = ["english", "japanese", "german"]
    target_language = "english"


def test_get_effective_target_languages_filters():
    langs = get_effective_target_languages(_UserStub())
    assert langs == ["english", "german"]
