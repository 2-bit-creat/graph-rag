"""Edge-TTS synthesis for quiz English sentences."""

from __future__ import annotations

import asyncio
import hashlib
import logging
import re
import tempfile
import uuid
from pathlib import Path

from .config import get_settings
from .languages import LANGUAGES, DEFAULT_TARGET
from .storage import public_media_url, save_media

logger = logging.getLogger(__name__)

AUDIO_DIR = Path(__file__).resolve().parent.parent / "static" / "audio"
DEFAULT_VOICE = LANGUAGES[DEFAULT_TARGET].tts_voice
MIN_AUDIO_BYTES = 512


def voice_for_language(language: str) -> str:
    lang = (language or DEFAULT_TARGET).strip().lower()
    spec = LANGUAGES.get(lang)
    return spec.tts_voice if spec else DEFAULT_VOICE

_BLANK_RE = re.compile(r"_{2,}|___+")


def quiz_audio_relative_path(quiz_id: uuid.UUID, *, variant: str = "sentence") -> str:
    suffix = "-answer" if variant == "answer" else ""
    return f"/static/audio/{quiz_id}{suffix}.mp3"


def answer_audio_asset_key(text: str, language: str) -> str:
    """Stable shared asset name for a short answer phrase.

    The voice is part of the digest, so two languages never collide. Unlike a
    per-quiz sentence, common targets such as ``has`` can share one durable
    MP3 across the learner's entire quiz collection.
    """
    payload = f"{voice_for_language(language)}\0{(text or '').strip()}".encode("utf-8")
    return f"answer-{hashlib.sha256(payload).hexdigest()[:32]}"


def audio_asset_relative_path(asset_key: str) -> str:
    return f"/static/audio/{asset_key}.mp3"


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


def resolve_cloze_answer_tts_text(validated: dict) -> str:
    """Return the answer phrase for immediate post-success playback.

    A multi-word blank remains one short clip: learners first hear the exact
    target expression, then the full sentence in its natural context.
    """
    qd = validated.get("quiz_data") or {}
    blank = (qd.get("blank") or "").strip()
    if blank:
        return blank
    accepted = qd.get("accepted_answers") or []
    return str(accepted[0]).strip() if accepted else ""


async def synthesize_quiz_audio(
    quiz_id: uuid.UUID,
    text: str,
    *,
    language: str = "english",
    variant: str = "sentence",
    asset_key: str | None = None,
) -> tuple[str | None, str | None]:
    """Synthesize MP3 for a quiz sentence — to S3 (Lambda-safe) when
    ``S3_BUCKET`` is configured, otherwise to the local static/audio dir.

    Returns (audio_url, error_message).
    """
    cleaned = (text or "").strip()
    if not cleaned:
        return None, "empty sentence_en"

    voice = voice_for_language(language)
    output_key = asset_key or f"{quiz_id}{'-answer' if variant == 'answer' else ''}"
    settings = get_settings()
    # Local development can reuse the shared answer asset without another
    # Edge-TTS call. Production/S3 still uses deterministic overwrite-safe
    # keys; a storage HEAD cache can be added there without changing URLs.
    if asset_key and not settings.s3_bucket:
        existing = AUDIO_DIR / f"{output_key}.mp3"
        if existing.exists() and existing.stat().st_size >= MIN_AUDIO_BYTES:
            return audio_asset_relative_path(output_key), None

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

    if settings.s3_bucket:
        data = tmp_path.read_bytes()
        tmp_path.unlink(missing_ok=True)
        key = f"quiz-audio/{output_key}.mp3"
        await save_media(data, key)
        return public_media_url(key), None

    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    out_path = AUDIO_DIR / f"{output_key}.mp3"
    out_path.unlink(missing_ok=True)
    tmp_path.replace(out_path)
    return (
        audio_asset_relative_path(output_key)
        if asset_key
        else quiz_audio_relative_path(quiz_id, variant=variant),
        None,
    )


async def synthesize_cloze_audio_pair(
    quiz_id: uuid.UUID,
    validated: dict,
    *,
    language: str = "english",
) -> tuple[str | None, str | None, str | None]:
    """Generate sentence and answer audio concurrently for a cloze quiz.

    Both clips must exist before the card is delivered, so answer feedback has
    no TTS request on its critical path. A sentence failure is reported as the
    primary error; answer audio remains an optional enhancement for graceful
    compatibility with legacy quizzes.
    """
    sentence_text = resolve_quiz_tts_text("cloze", validated)
    answer_text = resolve_cloze_answer_tts_text(validated)
    sentence_result, answer_result = await asyncio.gather(
        synthesize_quiz_audio(quiz_id, sentence_text, language=language),
        synthesize_quiz_audio(
            quiz_id,
            answer_text,
            language=language,
            variant="answer",
            asset_key=answer_audio_asset_key(answer_text, language),
        ),
    )
    sentence_url, sentence_error = sentence_result
    answer_url, answer_error = answer_result
    return sentence_url, answer_url, sentence_error or answer_error


async def synthesize_quiz_audio_assets(
    quiz_id: uuid.UUID,
    quiz_type: str,
    validated: dict,
    *,
    language: str = "english",
) -> tuple[str | None, str | None, str | None]:
    """Create the audio assets required by a quiz type.

    The second result is the short answer clip, currently meaningful only for
    cloze/word quizzes. Keeping one entry point prevents the three quiz
    generation paths from drifting in their stored audio contract.
    """
    if quiz_type == "cloze":
        return await synthesize_cloze_audio_pair(quiz_id, validated, language=language)
    sentence_url, error = await synthesize_quiz_audio(
        quiz_id,
        resolve_quiz_tts_text(quiz_type, validated),
        language=language,
    )
    return sentence_url, None, error
