"""Unit tests for voice embedding extraction."""

from pathlib import Path
import struct
import tempfile
import wave

from app.voice_embedding import (
    EMBEDDING_DIM,
    compute_voice_embedding,
    cosine_similarity,
    embed_speaker_segments,
)


def _write_test_wav(path: Path, duration_sec: float = 1.0, freq: float = 440.0) -> None:
    sr = 16000
    n = int(sr * duration_sec)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        frames = bytearray()
        for i in range(n):
            import math

            val = int(16000 * math.sin(2 * math.pi * freq * i / sr))
            frames.extend(struct.pack("<h", val))
        wf.writeframes(bytes(frames))


def test_compute_voice_embedding_dim():
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "test.wav"
        _write_test_wav(wav, duration_sec=0.8)
        segments = embed_speaker_segments(wav, [("Speaker_1", 0.1, 0.7)])
        assert "Speaker_1" in segments
        assert len(segments["Speaker_1"]) == EMBEDDING_DIM


def test_cosine_similarity_identical():
    v = [1.0, 0.0, 0.0]
    assert abs(cosine_similarity(v, v) - 1.0) < 1e-6


def test_compute_voice_embedding_short_clip():
    samples = [0.0] * 100
    assert compute_voice_embedding(samples, 16000) is None
