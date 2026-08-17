"""Journal cleanup must preserve the account's native language."""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest

from app import journal_pipeline
from app.routers.kg_build import _build_extraction_system_prompt


def _fake_client(payload: dict):
    response = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(payload)))]
    )
    client = SimpleNamespace()
    client.chat = SimpleNamespace()
    client.chat.completions = SimpleNamespace(
        create=AsyncMock(return_value=response)
    )
    return client


def test_english_cleanup_prompt_requires_english_output():
    prompt = journal_pipeline.build_cleanup_only_system_prompt("english")

    assert "English STT/text cleanup" in prompt
    assert '"transcript_clean_native": refined English' in prompt
    assert "Korean STT/text cleanup" not in prompt


@pytest.mark.asyncio
async def test_english_cleanup_reads_language_neutral_output_field():
    client = _fake_client(
        {
            "transcript_clean_native": "We got back from our trip yesterday.",
            "content_type": "일기",
            "single_speaker": True,
        }
    )

    with patch.object(journal_pipeline, "_client", return_value=client):
        result = await journal_pipeline.cleanup_only(
            "We got back from our trip yesterday", "english"
        )

    assert result["transcript_clean_ko"] == "We got back from our trip yesterday."
    assert result["content_type"] == "일기"


def test_english_graph_prompt_requires_english_graph_content():
    prompt = _build_extraction_system_prompt(
        content_type="개인일기", fixed_speaker="Me", native_language="english"
    )

    assert "Every user-visible field you create MUST be English" in prompt
    assert '"title": "a concise 5-7 word English title"' in prompt
    assert 'Every claim speaker MUST be exactly "Me"' in prompt
