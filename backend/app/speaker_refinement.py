"""Embedding-based speaker boundary refinement when diarization under-segments."""

from __future__ import annotations

import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path

from .config import get_settings
from .speaker_diarization import SpeakerSegment
from .voice_embedding import (
    compute_voice_embedding,
    cosine_similarity,
    embed_speaker_segments,
    load_audio_mono,
    slice_samples,
)


@dataclass
class _Window:
    start_sec: float
    end_sec: float
    embedding: list[float]


def _compute_windows(
    audio_path: Path,
    *,
    window_sec: float = 1.2,
    hop_sec: float = 0.4,
) -> tuple[list[_Window], float]:
    samples, sample_rate = load_audio_mono(audio_path)
    duration_sec = len(samples) / sample_rate
    windows: list[_Window] = []
    cursor = 0.0
    while cursor + window_sec <= duration_sec + 1e-6:
        clip = slice_samples(samples, sample_rate, cursor, cursor + window_sec)
        embedding = compute_voice_embedding(clip, sample_rate)
        if embedding is not None:
            windows.append(
                _Window(
                    start_sec=round(cursor, 2),
                    end_sec=round(min(cursor + window_sec, duration_sec), 2),
                    embedding=embedding,
                )
            )
        cursor += hop_sec
    return windows, duration_sec


def _adjacent_similarities(windows: list[_Window]) -> list[tuple[float, int]]:
    pairs: list[tuple[float, int]] = []
    for idx in range(1, len(windows)):
        sim = cosine_similarity(windows[idx - 1].embedding, windows[idx].embedding)
        pairs.append((sim, idx))
    return pairs


def _local_minima_change_points(
    similarities: list[tuple[float, int]],
    *,
    threshold: float,
) -> list[int]:
    if not similarities:
        return []

    points: list[int] = []
    for pos, (sim, idx) in enumerate(similarities):
        if sim >= threshold:
            continue
        prev_sim = similarities[pos - 1][0] if pos > 0 else 1.0
        next_sim = similarities[pos + 1][0] if pos + 1 < len(similarities) else 1.0
        if sim <= prev_sim and sim <= next_sim:
            points.append(idx)
    return points


def _merge_short_regions(
    boundaries: list[float],
    duration_sec: float,
    *,
    min_region_sec: float,
) -> list[float]:
    if not boundaries:
        return []

    cuts = [0.0, *boundaries, duration_sec]
    merged: list[float] = []
    idx = 1
    while idx < len(cuts) - 1:
        start = cuts[idx - 1]
        end = cuts[idx]
        if end - start < min_region_sec and idx + 1 < len(cuts):
            cuts[idx + 1] = end
            idx += 1
            continue
        if end - start >= min_region_sec:
            merged.append(end)
        idx += 1
    return merged[:-1] if merged and merged[-1] >= duration_sec - 0.05 else merged


def find_voice_change_boundaries(
    audio_path: Path,
    *,
    threshold: float | None = None,
    min_region_sec: float = 1.5,
    max_splits: int | None = None,
) -> list[float]:
    """Return split timestamps (seconds) where voice identity likely changes."""
    settings = get_settings()
    threshold = threshold if threshold is not None else settings.speaker_refinement_threshold

    windows, duration_sec = _compute_windows(audio_path)
    if len(windows) < 3:
        return []

    sims = _adjacent_similarities(windows)
    if not sims:
        return []

    if max_splits == 1:
        best_sim, best_idx = min(sims, key=lambda item: item[0])
        if best_sim >= threshold:
            return []
        boundaries = [windows[best_idx].start_sec]
        return _merge_short_regions(boundaries, duration_sec, min_region_sec=min_region_sec)

    change_idxs = _local_minima_change_points(sims, threshold=threshold)
    if not change_idxs:
        best_sim, best_idx = min(sims, key=lambda item: item[0])
        if best_sim < threshold:
            change_idxs = [best_idx]

    boundaries = [windows[idx].start_sec for idx in change_idxs]
    boundaries = sorted(set(boundaries))
    if max_splits is not None and len(boundaries) > max_splits:
        ranked = sorted(
            ((sims[i - 1][0], windows[i].start_sec) for i in change_idxs if i > 0),
            key=lambda item: item[0],
        )
        boundaries = sorted(point for _, point in ranked[:max_splits])

    return _merge_short_regions(boundaries, duration_sec, min_region_sec=min_region_sec)


def distinct_speaker_labels(segments: list[SpeakerSegment]) -> set[str]:
    return {seg.speaker for seg in segments if seg.speaker}


def should_refine_diarization(
    segments: list[SpeakerSegment],
    audio_path: Path,
) -> bool:
    """Refine when provider collapsed multiple voices into one label."""
    if not segments:
        return False

    settings = get_settings()
    if not settings.speaker_refinement_enabled:
        return False

    windows, duration_sec = _compute_windows(audio_path)
    if len(windows) < 3 or duration_sec < settings.speaker_refinement_min_duration_sec:
        return False

    labels = distinct_speaker_labels(segments)
    if len(labels) >= 2:
        return False

    longest = max(seg.end_sec - seg.start_sec for seg in segments)
    if longest >= settings.speaker_refinement_min_duration_sec:
        return True

    total = sum(seg.end_sec - seg.start_sec for seg in segments)
    return total >= settings.speaker_refinement_min_duration_sec


def _write_wav_clip(
    samples: list[float],
    sample_rate: int,
    start_sec: float,
    end_sec: float,
    dest: Path,
) -> None:
    clip = slice_samples(samples, sample_rate, start_sec, end_sec)
    if not clip:
        raise ValueError("empty audio clip")

    with wave.open(str(dest), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        frames = bytearray()
        for sample in clip:
            val = max(-32768, min(32767, int(sample * 32767)))
            frames.extend(int(val).to_bytes(2, byteorder="little", signed=True))
        wf.writeframes(bytes(frames))


async def transcribe_segment(audio_path: Path, start_sec: float, end_sec: float) -> str:
    """Whisper STT for a single time range."""
    from .journal_pipeline import transcribe_audio

    samples, sample_rate = load_audio_mono(audio_path)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        clip_path = Path(tmp.name)
    try:
        _write_wav_clip(samples, sample_rate, start_sec, end_sec, clip_path)
        return (await transcribe_audio(clip_path)).strip()
    finally:
        clip_path.unlink(missing_ok=True)


def _proposed_split_similarity(
    audio_path: Path,
    boundaries: list[float],
    duration_sec: float,
) -> float | None:
    """Cosine similarity between embeddings of regions separated by boundaries."""
    if not boundaries:
        return None

    cuts = [0.0, *boundaries, duration_sec]
    ranges: list[tuple[str, float, float]] = []
    for idx in range(len(cuts) - 1):
        start = cuts[idx]
        end = cuts[idx + 1]
        if end - start < 0.35:
            continue
        ranges.append((f"_region_{idx}", start, end))

    if len(ranges) < 2:
        return None

    embs = embed_speaker_segments(audio_path, ranges)
    if len(embs) < 2:
        return None

    labels = list(embs.keys())
    return cosine_similarity(embs[labels[0]], embs[labels[1]])


def _split_indicates_different_speakers(
    audio_path: Path,
    boundaries: list[float],
    duration_sec: float,
) -> tuple[bool, float | None]:
    """Only accept a split when separated regions embed as distinct voices."""
    settings = get_settings()
    sim = _proposed_split_similarity(audio_path, boundaries, duration_sec)
    if sim is None:
        return False, None
    return sim < settings.speaker_refinement_same_speaker_sim_cap, sim


async def refine_diarization_segments(
    audio_path: Path,
    segments: list[SpeakerSegment],
) -> tuple[list[SpeakerSegment], dict]:
    """Split under-segmented diarization using voice-embedding change points."""
    meta: dict = {"refined": False, "reason": "not_needed"}
    if not should_refine_diarization(segments, audio_path):
        return segments, meta

    _, duration_sec = _compute_windows(audio_path)
    boundaries = find_voice_change_boundaries(
        audio_path,
        max_splits=1 if len(distinct_speaker_labels(segments)) == 1 else None,
    )
    if not boundaries:
        meta["reason"] = "no_change_points"
        return segments, meta

    different, split_sim = _split_indicates_different_speakers(
        audio_path, boundaries, duration_sec
    )
    if not different:
        meta["reason"] = "split_rejected_same_speaker"
        if split_sim is not None:
            meta["split_similarity"] = round(split_sim, 4)
        return segments, meta

    cuts = [0.0, *boundaries, duration_sec]
    refined: list[SpeakerSegment] = []
    for speaker_idx in range(len(cuts) - 1):
        start = cuts[speaker_idx]
        end = cuts[speaker_idx + 1]
        if end - start < 0.35:
            continue
        text = await transcribe_segment(audio_path, start, end)
        refined.append(
            SpeakerSegment(
                speaker=f"Speaker_{speaker_idx + 1}",
                start_sec=round(start, 2),
                end_sec=round(end, 2),
                text=text,
            )
        )

    if len(refined) < 2:
        meta["reason"] = "refinement_produced_single_speaker"
        return segments, meta

    meta.update(
        {
            "refined": True,
            "reason": "embedding_change_points",
            "boundaries_sec": boundaries,
            "speaker_count": len(refined),
        }
    )
    return refined, meta
