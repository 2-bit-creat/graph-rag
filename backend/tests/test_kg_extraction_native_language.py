"""KG extraction prompt uses native language for output rules."""

from __future__ import annotations

from app.routers.kg_build import _build_extraction_system_prompt


def test_extraction_prompt_english_output():
    prompt = _build_extraction_system_prompt(
        content_type="diary",
        fixed_speaker=None,
        native_language="english",
    )
    assert "English title" in prompt or "5-7 word English" in prompt
    assert "Korean words" not in prompt


def test_extraction_prompt_korean_output():
    prompt = _build_extraction_system_prompt(
        content_type="diary",
        fixed_speaker=None,
        native_language="korean",
    )
    assert "Korean words" in prompt or "한국어" in prompt
