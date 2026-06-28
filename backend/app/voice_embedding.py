"""Per-segment voice embeddings for speaker memory (numpy spectral or optional resemblyzer)."""

from __future__ import annotations

import math
import struct
import subprocess
import wave
from pathlib import Path

from .config import get_settings

EMBEDDING_DIM = 256
_MIN_SEGMENT_SEC = 0.35
_TARGET_SAMPLE_RATE = 16000


def load_wav_mono(path: Path) -> tuple[list[float], int]:
    """Load WAV as normalized mono float samples."""
    with wave.open(str(path), "rb") as wf:
        nchannels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        nframes = wf.getnframes()
        raw = wf.readframes(nframes)

    if sampwidth != 2:
        raise ValueError(f"unsupported sample width: {sampwidth}")

    count = len(raw) // 2
    ints = struct.unpack(f"<{count}h", raw[: count * 2])

    if nchannels == 2:
        mono = [(ints[i] + ints[i + 1]) / 2 for i in range(0, len(ints), 2)]
    elif nchannels == 1:
        mono = list(ints)
    else:
        raise ValueError(f"unsupported channel count: {nchannels}")

    scale = 32768.0
    return [s / scale for s in mono], framerate


def _ffmpeg_executable() -> str:
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError as exc:
        raise ValueError(
            "install imageio-ffmpeg to decode webm/mp3/m4a recordings"
        ) from exc


def load_audio_mono(path: Path) -> tuple[list[float], int]:
    """Load mono float samples from WAV or browser formats (webm/mp3/m4a) via ffmpeg."""
    try:
        return load_wav_mono(path)
    except (wave.Error, ValueError):
        pass

    cmd = [
        _ffmpeg_executable(),
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(path),
        "-f",
        "s16le",
        "-acodec",
        "pcm_s16le",
        "-ac",
        "1",
        "-ar",
        str(_TARGET_SAMPLE_RATE),
        "pipe:1",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, check=True)
    except FileNotFoundError as exc:
        raise ValueError("ffmpeg executable not found") from exc
    except subprocess.CalledProcessError as exc:
        err = exc.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(err or "ffmpeg failed to decode audio") from exc

    raw = proc.stdout
    if len(raw) < 2:
        raise ValueError("empty audio after ffmpeg decode")

    count = len(raw) // 2
    ints = struct.unpack(f"<{count}h", raw[: count * 2])
    scale = 32768.0
    return [s / scale for s in ints], _TARGET_SAMPLE_RATE


def slice_samples(
    samples: list[float], sample_rate: int, start_sec: float, end_sec: float
) -> list[float]:
    start = max(0, int(start_sec * sample_rate))
    end = min(len(samples), int(end_sec * sample_rate))
    if end <= start:
        return []
    return samples[start:end]


def cosine_similarity(a: list[float], b: list[float]) -> float:
    if len(a) != len(b) or not a:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def compute_voice_embedding(samples: list[float], sample_rate: int) -> list[float] | None:
    if len(samples) < int(_MIN_SEGMENT_SEC * sample_rate):
        return None

    backend = get_settings().speaker_embedding_backend.lower()
    if backend == "resemblyzer":
        emb = _resemblyzer_embedding(samples, sample_rate)
        if emb is not None:
            return emb

    return _spectral_embedding(samples, sample_rate)


def _resemblyzer_embedding(samples: list[float], sample_rate: int) -> list[float] | None:
    try:
        import numpy as np
        from resemblyzer import VoiceEncoder

        wav = np.array(samples, dtype=np.float32)
        if sample_rate != 16000:
            ratio = 16000 / sample_rate
            idx = np.arange(0, len(wav), 1 / ratio).astype(int)
            idx = idx[idx < len(wav)]
            wav = wav[idx]
        encoder = VoiceEncoder()
        emb = encoder.embed_utterance(wav)
        return [float(x) for x in emb.tolist()]
    except Exception:
        return None


def _spectral_embedding(samples: list[float], sample_rate: int) -> list[float]:
    """Lightweight spectral fingerprint (256-dim) — no torch required."""
    try:
        import numpy as np

        wav = np.array(samples, dtype=np.float64)
        frame = max(256, sample_rate // 32)
        hop = frame // 2
        if len(wav) < frame:
            wav = np.pad(wav, (0, frame - len(wav)))

        frames: list[np.ndarray] = []
        for i in range(0, len(wav) - frame + 1, hop):
            chunk = wav[i : i + frame] * np.hanning(frame)
            mag = np.abs(np.fft.rfft(chunk))
            frames.append(mag[:128])

        if not frames:
            return _zero_embedding()

        spec = np.stack(frames)
        mean = spec.mean(axis=0)
        std = spec.std(axis=0)
        feat = np.concatenate([mean, std])
        if len(feat) < EMBEDDING_DIM:
            feat = np.pad(feat, (0, EMBEDDING_DIM - len(feat)))
        else:
            feat = feat[:EMBEDDING_DIM]
        norm = np.linalg.norm(feat)
        if norm > 0:
            feat = feat / norm
        return [float(x) for x in feat.tolist()]
    except ImportError:
        return _python_spectral_embedding(samples, sample_rate)


def _python_spectral_embedding(samples: list[float], sample_rate: int) -> list[float]:
    frame = max(256, sample_rate // 32)
    hop = frame // 2
    buckets = [0.0] * 128
    counts = [0] * 128

    for i in range(0, max(1, len(samples) - frame + 1), hop):
        chunk = samples[i : i + frame]
        energy = sum(x * x for x in chunk) / max(len(chunk), 1)
        idx = min(127, int(math.log1p(energy * 1e4) * 16))
        buckets[idx] += energy
        counts[idx] += 1

    feat: list[float] = []
    for b, c in zip(buckets, counts, strict=True):
        feat.append(b / c if c else 0.0)
    feat.extend(feat[:128])
    norm = math.sqrt(sum(x * x for x in feat))
    if norm > 0:
        feat = [x / norm for x in feat]
    return feat[:EMBEDDING_DIM]


def _zero_embedding() -> list[float]:
    return [0.0] * EMBEDDING_DIM


def embed_speaker_segments(
    audio_path: Path,
    segments: list[tuple[str, float, float]],
) -> dict[str, list[float]]:
    """Compute one averaged embedding per speaker label from time ranges."""
    samples, sr = load_audio_mono(audio_path)
    per_speaker: dict[str, list[list[float]]] = {}

    for label, start, end in segments:
        clip = slice_samples(samples, sr, start, end)
        emb = compute_voice_embedding(clip, sr)
        if emb is None:
            continue
        per_speaker.setdefault(label, []).append(emb)

    result: dict[str, list[float]] = {}
    for label, embs in per_speaker.items():
        if not embs:
            continue
        dim = len(embs[0])
        avg = [sum(e[i] for e in embs) / len(embs) for i in range(dim)]
        norm = math.sqrt(sum(x * x for x in avg))
        if norm > 0:
            avg = [x / norm for x in avg]
        result[label] = avg
    return result
