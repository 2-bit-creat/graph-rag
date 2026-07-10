"""Native-language awareness in graph chat prompts."""

from __future__ import annotations

from app.graph_chat import build_graph_chat_messages, build_graph_chat_system_prompt


def test_graph_chat_system_prompt_english():
    prompt = build_graph_chat_system_prompt(native_language="english")
    assert "English" in prompt or "english" in prompt.lower()
    assert "한국어" not in prompt


def test_graph_chat_system_prompt_korean():
    prompt = build_graph_chat_system_prompt(native_language="korean")
    assert "한국어" in prompt


def test_graph_chat_messages_english_context_header():
    msgs = build_graph_chat_messages(
        message="hello",
        history=[],
        context="",
        native_language="english",
    )
    system_msgs = [m for m in msgs if m["role"] == "system"]
    assert any("No diary memories" in m["content"] for m in system_msgs)


def test_graph_chat_messages_korean_context_header():
    msgs = build_graph_chat_messages(
        message="안녕",
        history=[],
        context="",
        native_language="korean",
    )
    system_msgs = [m for m in msgs if m["role"] == "system"]
    assert any("일기 기억이 없습니다" in m["content"] for m in system_msgs)
