"""Lightweight LLM token-usage logging (log lines only — no DB table)."""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def log_usage(purpose: str, resp: object) -> None:
    """Log prompt/completion/cached token counts from an OpenAI chat response."""
    usage = getattr(resp, "usage", None)
    if usage is None:
        return
    cached = 0
    details = getattr(usage, "prompt_tokens_details", None)
    if details is not None:
        cached = getattr(details, "cached_tokens", 0) or 0
    logger.info(
        "llm_usage purpose=%s prompt=%s cached=%s completion=%s total=%s",
        purpose,
        getattr(usage, "prompt_tokens", None),
        cached,
        getattr(usage, "completion_tokens", None),
        getattr(usage, "total_tokens", None),
    )
