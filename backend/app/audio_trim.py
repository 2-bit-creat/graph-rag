"""Trim silence / low-energy regions before STT (conservative — avoids cutting speech)."""

from __future__ import annotations

import io
import math
import struct
import wave
from dataclasses import dataclass
from pathlib import Path

from .config import get_settings


@dataclass
class TrimReport:
    applied: bool
    source_path: str
    output_path: str | None
    original_duration_sec: float
    trimmed_duration_sec: float
    saved_sec: float
    saved_ratio: float
    segment_count: int
    segments_sec: list[tuple[float, float]]
    reason: str = ""
    threshold_used: float | None = None
    mode: str = ""

    def to_dict(self) -> dict:
        return {
            "applied": self.applied,
            "source_path": self.source_path,
            "output_path": self.output_path,
            "original_duration_sec": round(self.original_duration_sec, 2),
            "trimmed_duration_sec": round(self.trimmed_duration_sec, 2),
            "saved_sec": round(self.saved_sec, 2),
            "saved_ratio": round(self.saved_ratio, 3),
            "segment_count": self.segment_count,
            "segments_sec": [
                [round(a, 2), round(b, 2)] for a, b in self.segments_sec
            ],
            "reason": self.reason,
            "threshold_used": self.threshold_used,
            "mode": self.mode,
        }


def _rms(chunk: bytes, sample_width: int) -> float:
    if not chunk or sample_width != 2:
        return 0.0
    count = len(chunk) // 2
    if count == 0:
        return 0.0
    samples = struct.unpack(f"<{count}h", chunk[: count * 2])
    mean_sq = sum(s * s for s in samples) / count
    return math.sqrt(mean_sq)


def _boost_pcm_for_stt(
    frames: bytes,
    sampwidth: int,
    *,
    target_peak: int = 12000,
    min_peak: int = 800,
    min_rms: float | None = None,
) -> bytes:
    """Boost quiet web-mic recordings so cloud STT / VAD can detect speech."""
    if sampwidth != 2 or not frames:
        return frames
    count = len(frames) // 2
    samples = list(struct.unpack(f"<{count}h", frames[: count * 2]))
    peak = max((abs(s) for s in samples), default=0)
    if peak <= 0 or peak >= target_peak:
        return frames
    mean_sq = sum(s * s for s in samples) / count
    rms = math.sqrt(mean_sq)
    needs_boost = peak < min_peak
    if min_rms is not None and rms < min_rms:
        needs_boost = True
    if not needs_boost:
        return frames
    scale = min(target_peak / peak, 12.0)
    boosted = [
        max(-32768, min(32767, int(s * scale)))
        for s in samples
    ]
    return struct.pack(f"<{count}h", *boosted)


def _normalize_quiet_pcm(frames: bytes, sampwidth: int, target_peak: int = 12000) -> bytes:
    """Boost quiet web-mic recordings so VAD does not treat speech as silence."""
    return _boost_pcm_for_stt(frames, sampwidth, target_peak=target_peak, min_peak=800)


def _adaptive_threshold(rms_values: list[float], floor: float) -> float:
    if not rms_values:
        return floor
    sorted_v = sorted(rms_values)
    n = len(sorted_v)
    p10 = sorted_v[max(0, n // 10)]
    p50 = sorted_v[n // 2]
    p90 = sorted_v[min(n - 1, (9 * n) // 10)]
    dynamic = p10 + (p90 - p10) * 0.15
    return max(floor, min(dynamic, p50 * 2.0))


def _merge_segments(
    segments: list[tuple[int, int]],
    max_gap_frames: int,
) -> list[tuple[int, int]]:
    if not segments:
        return []
    merged: list[tuple[int, int]] = [segments[0]]
    for start, end in segments[1:]:
        prev_start, prev_end = merged[-1]
        if start - prev_end <= max_gap_frames:
            merged[-1] = (prev_start, max(end, prev_end))
        else:
            merged.append((start, end))
    return merged


def _to_edges_only(
    speech_segments: list[tuple[int, int]], window_idx: int, pad_frames: int
) -> list[tuple[int, int]]:
    """Keep one continuous span: first detected speech → last detected speech."""
    if not speech_segments:
        return []
    first = min(s for s, _ in speech_segments)
    last = max(e for _, e in speech_segments)
    return [(max(0, first - pad_frames), min(window_idx, last + pad_frames))]


def trim_wav_bytes(data: bytes) -> tuple[bytes, TrimReport]:
    """Detect speech windows; default mode trims leading/trailing silence only."""
    settings = get_settings()
    mode = (settings.audio_trim_mode or "edges").lower()

    if not settings.audio_trim_enabled:
        return data, TrimReport(
            applied=False,
            source_path="",
            output_path=None,
            original_duration_sec=0,
            trimmed_duration_sec=0,
            saved_sec=0,
            saved_ratio=0,
            segment_count=0,
            segments_sec=[],
            reason="disabled",
            mode=mode,
        )

    with wave.open(io.BytesIO(data), "rb") as wf:
        nchannels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        nframes = wf.getnframes()
        frames = wf.readframes(nframes)

    if sampwidth != 2 or nchannels not in (1, 2):
        dur = nframes / framerate if framerate else 0
        return data, TrimReport(
            applied=False,
            source_path="",
            output_path=None,
            original_duration_sec=dur,
            trimmed_duration_sec=dur,
            saved_sec=0,
            saved_ratio=0,
            segment_count=0,
            segments_sec=[],
            reason=f"unsupported_wav_format(ch={nchannels},width={sampwidth})",
            mode=mode,
        )

    if settings.audio_trim_normalize_quiet:
        frames = _normalize_quiet_pcm(frames, sampwidth)

    frame_bytes = int(framerate * settings.audio_trim_window_ms / 1000) * nchannels * sampwidth
    if frame_bytes <= 0:
        frame_bytes = nchannels * sampwidth

    rms_values: list[float] = []
    for offset in range(0, len(frames), frame_bytes):
        rms_values.append(_rms(frames[offset : offset + frame_bytes], sampwidth))

    if settings.audio_trim_adaptive:
        thresh = _adaptive_threshold(rms_values, settings.audio_trim_rms_threshold_floor)
    else:
        thresh = settings.audio_trim_rms_threshold

    min_speech_frames = max(
        1, int(settings.audio_trim_min_speech_ms / settings.audio_trim_window_ms)
    )
    max_gap_frames = max(
        1, int(settings.audio_trim_max_gap_ms / settings.audio_trim_window_ms)
    )
    pad_frames = max(
        0, int(settings.audio_trim_padding_ms / settings.audio_trim_window_ms)
    )

    speech_segments: list[tuple[int, int]] = []
    run_start: int | None = None
    run_len = 0
    window_idx = 0

    for rms in rms_values:
        if rms >= thresh:
            if run_start is None:
                run_start = window_idx
            run_len += 1
        elif run_start is not None:
            if run_len >= min_speech_frames:
                speech_segments.append((run_start, window_idx))
            run_start = None
            run_len = 0
        window_idx += 1

    if run_start is not None and run_len >= min_speech_frames:
        speech_segments.append((run_start, window_idx))

    original_duration = nframes / framerate
    if not speech_segments:
        return data, TrimReport(
            applied=False,
            source_path="",
            output_path=None,
            original_duration_sec=original_duration,
            trimmed_duration_sec=original_duration,
            saved_sec=0,
            saved_ratio=0,
            segment_count=0,
            segments_sec=[],
            reason="no_speech_detected",
            threshold_used=round(thresh, 1),
            mode=mode,
        )

    if mode == "edges":
        padded = _to_edges_only(speech_segments, window_idx, pad_frames)
    else:
        merged = _merge_segments(speech_segments, max_gap_frames)
        padded = [
            (max(0, start - pad_frames), min(window_idx, end + pad_frames))
            for start, end in merged
        ]

    out = io.BytesIO()
    with wave.open(out, "wb") as wo:
        wo.setnchannels(nchannels)
        wo.setsampwidth(sampwidth)
        wo.setframerate(framerate)
        for start, end in padded:
            byte_start = start * frame_bytes
            byte_end = min(len(frames), end * frame_bytes)
            wo.writeframes(frames[byte_start:byte_end])

    trimmed = out.getvalue()
    trimmed_duration = sum(
        (end - start) * settings.audio_trim_window_ms / 1000 for start, end in padded
    )
    saved = max(0.0, original_duration - trimmed_duration)
    saved_ratio = saved / original_duration if original_duration else 0.0

    segments_sec = [
        (
            s * settings.audio_trim_window_ms / 1000,
            e * settings.audio_trim_window_ms / 1000,
        )
        for s, e in padded
    ]

    max_remove = settings.audio_trim_max_remove_ratio
    if saved_ratio > max_remove:
        return data, TrimReport(
            applied=False,
            source_path="",
            output_path=None,
            original_duration_sec=original_duration,
            trimmed_duration_sec=original_duration,
            saved_sec=0,
            saved_ratio=0,
            segment_count=len(padded),
            segments_sec=segments_sec,
            reason=f"trim_too_aggressive(saved_ratio={saved_ratio:.2f}>max={max_remove})",
            threshold_used=round(thresh, 1),
            mode=mode,
        )

    if trimmed_duration < settings.audio_trim_min_duration_sec:
        return data, TrimReport(
            applied=False,
            source_path="",
            output_path=None,
            original_duration_sec=original_duration,
            trimmed_duration_sec=original_duration,
            saved_sec=0,
            saved_ratio=0,
            segment_count=len(padded),
            segments_sec=segments_sec,
            reason="trimmed_too_short",
            threshold_used=round(thresh, 1),
            mode=mode,
        )

    min_keep = settings.audio_trim_min_keep_ratio
    if saved_ratio < (1 - min_keep):
        return data, TrimReport(
            applied=False,
            source_path="",
            output_path=None,
            original_duration_sec=original_duration,
            trimmed_duration_sec=original_duration,
            saved_sec=0,
            saved_ratio=0,
            segment_count=len(padded),
            segments_sec=segments_sec,
            reason="insufficient_savings",
            threshold_used=round(thresh, 1),
            mode=mode,
        )

    return trimmed, TrimReport(
        applied=True,
        source_path="",
        output_path=None,
        original_duration_sec=original_duration,
        trimmed_duration_sec=trimmed_duration,
        saved_sec=saved,
        saved_ratio=saved_ratio,
        segment_count=len(padded),
        segments_sec=segments_sec,
        threshold_used=round(thresh, 1),
        mode=mode,
    )


def trim_audio_file(source: Path, output_dir: Path | None = None) -> tuple[Path, TrimReport]:
    """Trim WAV; other formats pass through unchanged."""
    data = source.read_bytes()
    suffix = source.suffix.lower()

    if suffix != ".wav":
        return source, TrimReport(
            applied=False,
            source_path=str(source),
            output_path=str(source),
            original_duration_sec=0,
            trimmed_duration_sec=0,
            saved_sec=0,
            saved_ratio=0,
            segment_count=0,
            segments_sec=[],
            reason=f"skip_non_wav({suffix})",
        )

    trimmed, report = trim_wav_bytes(data)
    report.source_path = str(source.resolve())

    if not report.applied:
        report.output_path = str(source.resolve())
        return source, report

    dest_dir = output_dir or source.parent
    dest = dest_dir / f"{source.stem}_trimmed.wav"
    dest.write_bytes(trimmed)
    report.output_path = str(dest.resolve())
    return dest, report


def wav_bytes_for_diarization(path: Path) -> tuple[bytes, str]:
    """Read WAV for Deepgram; boost quiet web-mic levels when normalize is enabled."""
    try:
        with wave.open(str(path), "rb") as wf:
            params = wf.getparams()
            frames = wf.readframes(wf.getnframes())
    except wave.Error:
        return path.read_bytes(), "raw"

    if not get_settings().audio_trim_normalize_quiet:
        return path.read_bytes(), "raw"

    boosted = _boost_pcm_for_stt(
        frames,
        params.sampwidth,
        min_peak=800,
        min_rms=450.0,
    )
    if boosted is frames:
        return path.read_bytes(), "raw"

    buf = io.BytesIO()
    with wave.open(buf, "wb") as out:
        out.setparams(params)
        out.writeframes(boosted)
    return buf.getvalue(), "peak_normalized"
