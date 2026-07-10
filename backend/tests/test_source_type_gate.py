"""Content-type gate: speaker count is a hard signal that overrides the LLM guess.

A single voice can never be 대화/회의록 (defaults to 개인일기 but keeps an explicit
monologue medium), and multiple voices can never be a personal 일기.
"""

import pytest

from app.journal_pipeline import DIARY_CATEGORY, gate_source_type


@pytest.mark.parametrize(
    "content_type,expected",
    [
        ("일기", DIARY_CATEGORY),      # normalize alias → canonical
        ("개인일기", DIARY_CATEGORY),
        ("대화", DIARY_CATEGORY),       # impossible for one voice → diary
        ("회의록", DIARY_CATEGORY),
        ("", DIARY_CATEGORY),          # no guess → diary default
        (None, DIARY_CATEGORY),
        ("강연", "강연"),               # explicit monologue medium kept
        ("책", "책"),
        ("뉴스", "뉴스"),
        ("논문", "논문"),
    ],
)
def test_single_speaker(content_type, expected):
    assert gate_source_type(content_type, single_speaker=True) == expected


@pytest.mark.parametrize(
    "content_type,expected",
    [
        ("일기", "대화"),               # impossible for many voices → 대화
        ("개인일기", "대화"),
        ("", "대화"),                   # no guess → 대화 default
        (None, "대화"),
        ("대화", "대화"),
        ("회의록", "회의록"),
        ("강연", "강연"),               # a lecture may have multiple voices
        ("책", "책"),
    ],
)
def test_multi_speaker(content_type, expected):
    assert gate_source_type(content_type, single_speaker=False) == expected
