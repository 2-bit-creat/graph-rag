"""Optional speaker diarization before STT.

Whisper alone does not identify speakers. When enabled, we use Deepgram (if API key
is set) or pyannote.audio (if HF token set) to split audio by speaker.

Voice embeddings are stored in speaker_profiles and linked to Person graph nodes.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path

import httpx

from .config import get_settings


@dataclass
class SpeakerSegment:
    speaker: str
    start_sec: float
    end_sec: float
    text: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def segments_to_labeled_transcript(segments: list[SpeakerSegment]) -> str:
    lines: list[str] = []
    for seg in segments:
        label = seg.speaker
        text = seg.text.strip()
        if text:
            lines.append(f"[{label}] {text}")
    return "\n".join(lines)


async def diarize_audio(audio_path: Path) -> tuple[list[SpeakerSegment], str, dict]:
    """Return speaker segments, provider note, and optional refinement metadata."""
    settings = get_settings()
    if not settings.speaker_diarization_enabled:
        return [], "disabled", {}

    provider = "none"
    segments: list[SpeakerSegment] = []
    refine_meta: dict = {}

    if settings.deepgram_api_key:
        try:
            segments = await _deepgram_diarize(audio_path, settings.deepgram_api_key)
            provider = "deepgram"
        except Exception as exc:
            return [], f"deepgram_failed:{exc}", {}

    elif settings.pyannote_hf_token:
        try:
            segments = _pyannote_diarize(audio_path, settings.pyannote_hf_token)
            provider = "pyannote"
        except Exception as exc:
            return [], f"pyannote_failed:{exc}", {}

    else:
        return [], "no_provider_configured", {}

    if segments:
        from .speaker_refinement import refine_diarization_segments

        segments, refine_meta = await refine_diarization_segments(audio_path, segments)
        if refine_meta.get("refined"):
            provider = f"{provider}+embedding_refine"

    return segments, provider, refine_meta


def _segments_from_words(words: list) -> list[SpeakerSegment]:
    if not words:
        return []

    segments: list[SpeakerSegment] = []
    current_speaker: int | None = None
    buf: list[str] = []
    start = 0.0
    end = 0.0

    def flush(spk: int) -> None:
        if not buf:
            return
        segments.append(
            SpeakerSegment(
                speaker=f"Speaker_{spk + 1}",
                start_sec=round(start, 2),
                end_sec=round(end, 2),
                text=" ".join(buf).strip(),
            )
        )

    for w in words:
        spk = int(w.get("speaker", 0))
        word = w.get("punctuated_word") or w.get("word") or ""
        ws = float(w.get("start", 0))
        we = float(w.get("end", ws))
        if current_speaker is None:
            current_speaker = spk
            start = ws
        if spk != current_speaker:
            flush(current_speaker)
            buf = []
            current_speaker = spk
            start = ws
        buf.append(word)
        end = we

    if current_speaker is not None:
        flush(current_speaker)

    return segments


def _segments_from_utterances(utterances: list) -> list[SpeakerSegment]:
    segments: list[SpeakerSegment] = []
    for utt in utterances:
        if not isinstance(utt, dict):
            continue
        text = (utt.get("transcript") or "").strip()
        if not text:
            continue
        spk = int(utt.get("speaker", 0))
        segments.append(
            SpeakerSegment(
                speaker=f"Speaker_{spk + 1}",
                start_sec=round(float(utt.get("start", 0)), 2),
                end_sec=round(float(utt.get("end", 0)), 2),
                text=text,
            )
        )
    return segments


def _merge_deepgram_segments(
    words: list,
    utterances: list,
) -> list[SpeakerSegment]:
    """Prefer the richest speaker separation Deepgram returned."""
    word_segments = _segments_from_words(words)
    utt_segments = _segments_from_utterances(utterances)

    word_speakers = {int(w.get("speaker", 0)) for w in words} if words else set()
    utt_speakers = (
        {int(u.get("speaker", 0)) for u in utterances if isinstance(u, dict)}
        if utterances
        else set()
    )

    if len(word_speakers) >= 2:
        return word_segments
    if len(utt_speakers) >= 2:
        return utt_segments
    return word_segments or utt_segments


async def _deepgram_diarize(audio_path: Path, api_key: str) -> list[SpeakerSegment]:
    """Deepgram listen API with diarize=true (Korean)."""
    url = (
        "https://api.deepgram.com/v1/listen"
        "?model=nova-2&language=ko&diarize=true&diarize_version=latest"
        "&utterances=true&punctuate=true&smart_format=true"
    )
    headers = {
        "Authorization": f"Token {api_key}",
        "Content-Type": "audio/wav",
    }

    async def _request(data: bytes) -> list[SpeakerSegment]:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(url, headers=headers, content=data)
            resp.raise_for_status()
            payload = resp.json()

        alt = payload.get("results", {}).get("channels", [{}])[0].get("alternatives", [{}])[0]
        words = alt.get("words") or []
        utterances = alt.get("utterances") or []
        if not words and not utterances:
            return []
        return _merge_deepgram_segments(words, utterances)

    segments = await _request(audio_path.read_bytes())
    if segments:
        return segments

    from .audio_trim import wav_bytes_for_diarization

    boosted, mode = wav_bytes_for_diarization(audio_path)
    if mode == "peak_normalized":
        return await _request(boosted)
    return []


def _pyannote_diarize(audio_path: Path, hf_token: str) -> list[SpeakerSegment]:
    """Local diarization via pyannote — time ranges only (no transcript)."""
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=hf_token,
    )
    diarization = pipeline(str(audio_path))
    segments: list[SpeakerSegment] = []
    speaker_idx: dict[str, int] = {}

    for turn, _, speaker in diarization.itertracks(yield_label=True):
        if speaker not in speaker_idx:
            speaker_idx[speaker] = len(speaker_idx)
        idx = speaker_idx[speaker]
        segments.append(
            SpeakerSegment(
                speaker=f"Speaker_{idx + 1}",
                start_sec=round(float(turn.start), 2),
                end_sec=round(float(turn.end), 2),
                text="",
            )
        )
    return segments


def save_segments_artifact(segments: list[SpeakerSegment], dest: Path) -> None:
    dest.write_text(
        json.dumps([s.to_dict() for s in segments], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def stable_speaker_id(user_id: uuid.UUID, speaker_label: str) -> str:
    """Deterministic id for linking diarized speakers across sessions (future voice memory)."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{user_id}:{speaker_label}"))
