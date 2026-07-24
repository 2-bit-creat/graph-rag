"""Central language registry — single source of truth for every language-keyed
table that used to be duplicated (and drift) across quiz_generator, quiz_bundle,
tutor, quiz_audio_engine, quiz_presenter, and the routers.

Two independent axes:
- native_language: the learner's own language (UI copy, chat persona, graph
  content, explanations).
- target_language: the language being learned (quiz answers, drill sentences).

Only ``SUPPORTED_NATIVE`` x ``SUPPORTED_TARGET`` (minus native == target) is a
valid combination.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class LanguageSpec:
    code: str  # ISO 639-1
    label: str  # display label shown regardless of viewer's native language
    whisper: str  # OpenAI Whisper language hint
    deepgram: str  # Deepgram `language` query param
    tts_voice: str  # edge-tts voice name
    script: str  # "hangul" | "latin" | ... — used for native-field validation
    self_label: str  # default self-node name for a fresh graph in this language


LANGUAGES: dict[str, LanguageSpec] = {
    "korean": LanguageSpec(
        code="ko", label="Korean (한국어)", whisper="ko", deepgram="ko",
        tts_voice="ko-KR-SunHiNeural", script="hangul", self_label="나",
    ),
    "english": LanguageSpec(
        code="en", label="English", whisper="en", deepgram="en-US",
        tts_voice="en-US-JennyNeural", script="latin", self_label="Me",
    ),
    "german": LanguageSpec(
        code="de", label="German (Deutsch)", whisper="de", deepgram="de",
        tts_voice="de-DE-KatjaNeural", script="latin", self_label="Ich",
    ),
    # Target-only languages kept for the vocabulary/TTS surfaces that already
    # supported them ad hoc; not offered as a native-language choice.
    "japanese": LanguageSpec(
        code="ja", label="Japanese (日本語)", whisper="ja", deepgram="ja",
        tts_voice="ja-JP-NanamiNeural", script="latin", self_label="",
    ),
    "chinese": LanguageSpec(
        code="zh", label="Chinese (中文)", whisper="zh", deepgram="zh",
        tts_voice="zh-CN-XiaoxiaoNeural", script="latin", self_label="",
    ),
    "spanish": LanguageSpec(
        code="es", label="Spanish (Español)", whisper="es", deepgram="es",
        tts_voice="es-ES-ElviraNeural", script="latin", self_label="",
    ),
    "french": LanguageSpec(
        code="fr", label="French (Français)", whisper="fr", deepgram="fr",
        tts_voice="fr-FR-DeniseNeural", script="latin", self_label="",
    ),
    "portuguese": LanguageSpec(
        code="pt", label="Portuguese (Português)", whisper="pt", deepgram="pt",
        tts_voice="pt-BR-FranciscaNeural", script="latin", self_label="",
    ),
    "italian": LanguageSpec(
        code="it", label="Italian (Italiano)", whisper="it", deepgram="it",
        tts_voice="it-IT-ElsaNeural", script="latin", self_label="",
    ),
    "arabic": LanguageSpec(
        code="ar", label="Arabic (عربي)", whisper="ar", deepgram="ar",
        tts_voice="ar-EG-SalmaNeural", script="latin", self_label="",
    ),
    "russian": LanguageSpec(
        code="ru", label="Russian (Русский)", whisper="ru", deepgram="ru",
        tts_voice="ru-RU-SvetlanaNeural", script="latin", self_label="",
    ),
}

# Languages the user may set as their native (UI/graph/explanation) language.
SUPPORTED_NATIVE: frozenset[str] = frozenset({"korean", "english"})

# Languages the user may pick to learn (quiz target).
SUPPORTED_TARGET: frozenset[str] = frozenset({"english", "german", "korean"})

DEFAULT_NATIVE = "korean"
DEFAULT_TARGET = "english"


def normalize(language: str | None, default: str) -> str:
    lang = (language or "").strip().lower()
    return lang if lang in LANGUAGES else default


def spec(language: str | None, default: str = DEFAULT_TARGET) -> LanguageSpec:
    return LANGUAGES.get(normalize(language, default), LANGUAGES[default])


def label(language: str | None, default: str = DEFAULT_TARGET) -> str:
    return spec(language, default).label


def valid_target_for_native(native_language: str | None) -> frozenset[str]:
    """A learner can't "learn" their own native language."""
    native = normalize(native_language, DEFAULT_NATIVE)
    return frozenset(SUPPORTED_TARGET - {native})
