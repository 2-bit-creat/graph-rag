"""Central language allowlists and display labels for profile settings."""

from __future__ import annotations

ALLOWED_NATIVE = frozenset({"korean", "english"})
ALLOWED_TARGET = frozenset({"english", "korean", "german"})

NATIVE_LABELS: dict[str, str] = {
    "korean": "Korean",
    "english": "English",
}

TARGET_LABELS: dict[str, str] = {
    "english": "English",
    "korean": "Korean",
    "german": "German (Deutsch)",
}

# Combined display map for prompts (native + target).
LANG_DISPLAY_NAMES: dict[str, str] = {**NATIVE_LABELS, **TARGET_LABELS}

# Korean UI labels for target languages (mobile/backend presenter).
LANG_KO_DISPLAY: dict[str, str] = {
    "english": "영어",
    "korean": "한국어",
    "german": "독일어",
}


def lang_label(code: str) -> str:
    key = (code or "").strip().lower()
    return LANG_DISPLAY_NAMES.get(key, key.title() or "English")


def normalize_native(code: str | None, *, default: str = "korean") -> str:
    key = (code or default).strip().lower()
    return key if key in ALLOWED_NATIVE else default


def normalize_target(code: str | None, *, default: str = "english") -> str:
    key = (code or default).strip().lower()
    return key if key in ALLOWED_TARGET else default


def filter_target_languages(codes: list[str] | None) -> list[str]:
    if not codes:
        return ["english"]
    seen: set[str] = set()
    out: list[str] = []
    for raw in codes:
        if not isinstance(raw, str):
            continue
        key = raw.strip().lower()
        if key in ALLOWED_TARGET and key not in seen:
            seen.add(key)
            out.append(key)
    return out or ["english"]


def validate_native(code: str) -> str:
    key = code.strip().lower()
    if key not in ALLOWED_NATIVE:
        raise ValueError(f"native_language must be one of {sorted(ALLOWED_NATIVE)}")
    return key


def validate_target_list(codes: list[str]) -> list[str]:
    langs = filter_target_languages(codes)
    if not langs:
        raise ValueError("target_languages must be a non-empty list")
    return langs
