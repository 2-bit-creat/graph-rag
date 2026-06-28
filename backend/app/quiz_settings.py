"""Quiz generation / selection settings snapshot for trace IO."""

from __future__ import annotations

from .config import get_settings


def quiz_selection_settings(current_level: int | None = None) -> dict:
    settings = get_settings()
    level = current_level if current_level is not None else 10
    return settings.quiz_selection_snapshot(level)
