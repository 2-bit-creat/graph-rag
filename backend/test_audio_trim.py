"""Unit test for WAV silence trim."""

import io
import struct
import wave

from app.audio_trim import trim_wav_bytes


def _make_wav(
    duration_sec: float,
    speech_at: tuple[float, float] | None = None,
    *,
    quiet_speech: bool = False,
) -> bytes:
    rate = 16000
    n = int(rate * duration_sec)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        frames = []
        for i in range(n):
            t = i / rate
            amp = 0
            if speech_at and speech_at[0] <= t <= speech_at[1]:
                amp = 400 if quiet_speech else 8000
            frames.append(struct.pack("<h", amp))
        wf.writeframes(b"".join(frames))
    return buf.getvalue()


def test_trim_edges_keeps_middle_pauses():
    """Quiet speech with pause — edges mode must not cut the middle."""
    raw = _make_wav(10.0, speech_at=(1.0, 9.0), quiet_speech=True)
    _, report = trim_wav_bytes(raw)
    assert report.mode == "edges"
    assert report.trimmed_duration_sec > 7.0


def test_trim_rejects_aggressive_cut():
    raw = _make_wav(10.0, speech_at=(4.5, 5.0))
    _, report = trim_wav_bytes(raw)
    assert not report.applied
    assert "aggressive" in report.reason or report.saved_ratio == 0


def test_trim_removes_leading_trailing_silence():
    raw = _make_wav(10.0, speech_at=(1.0, 9.0))
    trimmed, report = trim_wav_bytes(raw)
    assert report.applied
    assert report.trimmed_duration_sec > 7.0
    assert report.saved_ratio <= 0.25
    assert len(trimmed) > 44


if __name__ == "__main__":
    test_trim_edges_keeps_middle_pauses()
    test_trim_rejects_aggressive_cut()
    test_trim_removes_leading_trailing_silence()
    print("OK")
