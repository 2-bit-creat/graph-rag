"""Lv.1–100 difficulty bands mapped to CEFR for quiz generation."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class LevelBand:
    level_min: int
    level_max: int
    cefr: str
    vocabulary: str
    grammar: str


BANDS: tuple[LevelBand, ...] = (
    LevelBand(1, 15, "Pre-A1~A1", "~500 words", "be verbs, simple present"),
    LevelBand(16, 35, "A2", "~1500 words", "past tense, frequency adverbs"),
    LevelBand(36, 55, "B1", "~3000 words", "perfect tenses, relative clauses"),
    LevelBand(56, 75, "B2", "~5000 words", "idioms, complex sentences"),
    LevelBand(76, 90, "C1", "advanced", "nuance, collocations"),
    LevelBand(91, 100, "C2", "native-like", "idioms, slang, subtle register"),
)


def clamp_level(level: int) -> int:
    return max(1, min(100, level))


def get_level_band(level: int) -> LevelBand:
    level = clamp_level(level)
    for band in BANDS:
        if band.level_min <= level <= band.level_max:
            return band
    return BANDS[-1]


def level_prompt_context(level: int) -> str:
    level = clamp_level(level)
    band = get_level_band(level)
    return (
        f"Target difficulty: Level {level} (CEFR {band.cefr}). "
        f"Vocabulary scope: {band.vocabulary}. Grammar scope: {band.grammar}. "
        f"Scale the English sentence and quiz content to match this level exactly."
    )


def window_for_level(level: int, half_width: int = 3) -> tuple[int, int]:
    level = clamp_level(level)
    return clamp_level(level - half_width), clamp_level(level + half_width)


def cefr_label(level: int) -> str:
    return get_level_band(level).cefr
