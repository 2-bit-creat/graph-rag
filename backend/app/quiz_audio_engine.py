"""Edge-TTS synthesis for quiz English sentences."""

from __future__ import annotations

import logging
import re
import tempfile
import uuid
from pathlib import Path

from .config import get_settings
from .storage import public_media_url, save_media

logger = logging.getLogger(__name__)

AUDIO_DIR = Path(__file__).resolve().parent.parent / "static" / "audio"
DEFAULT_VOICE = "en-US-JennyNeural"
MIN_AUDIO_BYTES = 512

_LANGUAGE_VOICES: dict[str, str] = {
    "english":    "en-US-JennyNeural",
    "german":     "de-DE-KatjaNeural",
    "japanese":   "ja-JP-NanamiNeural",
    "chinese":    "zh-CN-XiaoxiaoNeural",
    "french":     "fr-FR-DeniseNeural",
    "spanish":    "es-ES-ElviraNeural",
    "portuguese": "pt-BR-FranciscaNeural",
    "italian":    "it-IT-ElsaNeural",
    "arabic":     "ar-EG-SalmaNeural",
    "russian":    "ru-RU-SvetlanaNeural",
}


def voice_for_language(language: str) -> str:
    return _LANGUAGE_VOICES.get((language or "english").strip().lower(), DEFAULT_VOICE)

_BLANK_RE = re.compile(r"_{2,}|___+")


def quiz_audio_relative_path(quiz_id: uuid.UUID) -> str:
    return f"/static/audio/{quiz_id}.mp3"


def build_complete_cloze_sentence(
    quiz_data: dict,
    blank: str,
    *,
    sentence_en: str = "",
) -> str:
    """Return the filled English sentence (no underscores) for TTS / storage."""
    word = (blank or "").strip()
    prompt = (quiz_data.get("prompt_en") or "").strip()
    raw = (sentence_en or quiz_data.get("sentence_en") or "").strip()

    for source in (raw, prompt):
        if not source:
            continue
        if _BLANK_RE.search(source):
            if not word:
                continue
            return _BLANK_RE.sub(word, source, count=1)
        if word and word.lower() in source.lower():
            return source
    return raw or prompt


def resolve_quiz_tts_text(quiz_type: str, validated: dict) -> str:
    """Pick speakable text — always the completed sentence, never blank markers."""
    qd = validated.get("quiz_data") or {}
    top = (validated.get("sentence_en") or "").strip()

    if quiz_type == "cloze":
        blank = (qd.get("blank") or "").strip()
        if not blank:
            accepted = qd.get("accepted_answers") or []
            blank = str(accepted[0]).strip() if accepted else ""
        complete = build_complete_cloze_sentence(qd, blank, sentence_en=top)
        if complete and not _BLANK_RE.search(complete):
            return complete

    if quiz_type == "scramble":
        sentence = (qd.get("sentence_en") or top or "").strip()
        if sentence:
            return sentence

    if quiz_type == "mcq_nuance":
        options = qd.get("options") or []
        idx = qd.get("correct_index")
        if idx is not None and 0 <= int(idx) < len(options):
            return str(options[int(idx)]).strip()
        if top:
            return top

    if top and not _BLANK_RE.search(top):
        return top
    return build_complete_cloze_sentence(qd, (qd.get("blank") or "").strip(), sentence_en=top)


async def synthesize_quiz_audio(
    quiz_id: uuid.UUID,
    text: str,
    *,
    language: str = "english",
) -> tuple[str | None, str | None]:
    """Synthesize MP3 for a quiz sentence — to S3 (Lambda-safe) when
    ``S3_BUCKET`` is configured, otherwise to the local static/audio dir.

    Returns (audio_url, error_message).
    """
    cleaned = (text or "").strip()
    if not cleaned:
        return None, "empty sentence_en"

    voice = voice_for_language(language)

    # edge_tts only writes to a filesystem path, so synthesize into a temp file
    # either way; the local branch then keeps it, the S3 branch reads it back
    # as bytes to upload and discards it (Lambda's /tmp doesn't persist anyway).
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        import edge_tts

        communicate = edge_tts.Communicate(cleaned, voice)
        await communicate.save(str(tmp_path))
    except Exception as exc:
        logger.exception("Edge-TTS failed for quiz %s", quiz_id)
        tmp_path.unlink(missing_ok=True)
        return None, str(exc)

    if not tmp_path.exists() or tmp_path.stat().st_size < MIN_AUDIO_BYTES:
        tmp_path.unlink(missing_ok=True)
        return None, "TTS produced empty audio file"

    settings = get_settings()
    if settings.s3_bucket:
        data = tmp_path.read_bytes()
        tmp_path.unlink(missing_ok=True)
        key = f"quiz-audio/{quiz_id}.mp3"
        await save_media(data, key)
        return public_media_url(key), None

    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    out_path = AUDIO_DIR / f"{quiz_id}.mp3"
    out_path.unlink(missing_ok=True)
    tmp_path.replace(out_path)
    return quiz_audio_relative_path(quiz_id), None
