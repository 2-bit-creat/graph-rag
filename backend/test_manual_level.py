"""Tests for level guidelines."""

from app.level_guidelines import clamp_level, get_level_band, window_for_level


def test_clamp_level():
    assert clamp_level(0) == 1
    assert clamp_level(150) == 100
    assert clamp_level(35) == 35


def test_level_band():
    band = get_level_band(35)
    assert band.cefr == "A2"


def test_window():
    lo, hi = window_for_level(35, 3)
    assert lo == 32
    assert hi == 38
