"""Precision text journal entries — user-labeled dialogue without voice embeddings."""

from __future__ import annotations

import re
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from .models import JournalEntry
from .speaker_diarization import SpeakerSegment, segments_to_labeled_transcript

_SPEAKER_LABEL_RE = re.compile(r"^Speaker[_\s]?\d+$", re.I)
_IGNORE_SPEAKER = frozenset({"무시", "ignore", "skip", "omit"})
_MEANINGFUL_TEXT_RE = re.compile(r"[^\s\W]+", re.UNICODE)

_SPEAKER_LINE_RE = re.compile(
    r"^\s*\[(?P<speaker>[^\]]+)\]\s*:\s*(?P<text>.+?)\s*$",
    re.MULTILINE,
)


def pre_slice_by_speaker_lines(paragraph_text: str) -> list[dict[str, str]]:
    """Parse [화자명]: line blocks without merging same-speaker lines.

    화자는 명시적 표기로만 갈린다 — 클라이언트의 `@이름` 멘션, 그리고 그것이
    정규화된 `[이름]: …` 라벨. 대괄호가 없으면 화자가 없는 것이고, 전체가 한
    사람(글쓴이)의 글로 남는다.

    예전에는 여기에 맨살 "이름: 내용" 휴리스틱 폴백이 있었다. 명분은 카톡·회의록
    붙여넣기였는데 실제 카톡 내보내기 두 포맷(`2026년 ... , 홍길동 : 안녕`,
    `[홍길동] [오후 3:20] 안녕`) 어느 것도 그 정규식에 걸리지 않았다. 잡으려던
    것은 못 잡고 콜론이 흔한 문서만 잘라서, 금융 용어 정리 한 장이 화자 23명짜리
    대화가 되고 개념마다 Identity 노드가 생겼다. 턴 수 임계값으로 완화해도
    `질문:/답변:` 같은 메모는 통과하므로, 신호 자체를 신뢰할 수 없다고 보고 제거.
    스크린샷 대화는 OCR이 `@이름:`을 붙여 오므로 이 경로가 아니라 멘션 경로를 탄다.
    """
    lines: list[dict[str, str]] = []
    for raw_line in paragraph_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        m = _SPEAKER_LINE_RE.match(line)
        if m:
            lines.append(
                {
                    "speaker": m.group("speaker").strip(),
                    "text": m.group("text").strip(),
                }
            )
            continue
        if lines:
            # 사용자가 넣은 줄바꿈 보존(공백 병합 금지) — 목록·문단 구조가
            # 화자별 스크립트에 그대로 남게.
            lines[-1]["text"] = f"{lines[-1]['text']}\n{line}".strip()
    return lines


def segments_to_paragraph_text(segments: list[dict[str, Any]]) -> str:
    """Convert journal transcript segments to [speaker]: text lines."""
    out: list[str] = []
    for raw in segments:
        if not isinstance(raw, dict):
            continue
        speaker = str(raw.get("speaker", "")).strip()
        text = str(raw.get("text", "")).strip()
        if speaker and text:
            out.append(f"[{speaker}]: {text}")
    return "\n".join(out)


def is_precision_text_entry(entry: JournalEntry) -> bool:
    """True when the entry was created from drag-labeled text (not audio STT)."""
    trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
    if trace.get("entry_source") == "precision_text":
        return True
    if entry.audio_url:
        return False
    segments = entry.transcript_segments or []
    if not segments:
        return False
    for raw in segments:
        if not isinstance(raw, dict):
            continue
        speaker = str(raw.get("speaker", "")).strip()
        if not speaker or _SPEAKER_LABEL_RE.match(speaker):
            return False
    return True


def normalize_dialogue(dialogue: list[dict[str, Any]]) -> list[dict[str, str]]:
    """Filter empty / ignored lines; raise if nothing remains."""
    cleaned: list[dict[str, str]] = []
    for raw in dialogue:
        if not isinstance(raw, dict):
            continue
        speaker = str(raw.get("speaker", "")).strip()
        text = str(raw.get("text", "")).strip()
        if not speaker or speaker.lower() in _IGNORE_SPEAKER:
            continue
        if not text or _MEANINGFUL_TEXT_RE.search(text) is None:
            continue
        cleaned.append({"speaker": speaker, "text": text})
    if not cleaned:
        raise ValueError("At least one labeled dialogue line with speaker and text is required")
    return cleaned


def dialogue_to_transcript(dialogue: list[dict[str, str]]) -> str:
    segments = [
        SpeakerSegment(speaker=line["speaker"], start_sec=0.0, end_sec=0.0, text=line["text"])
        for line in dialogue
    ]
    return segments_to_labeled_transcript(segments)


def segments_from_dialogue(dialogue: list[dict[str, str]]) -> list[dict[str, Any]]:
    return [
        {
            "speaker": line["speaker"],
            "text": line["text"],
            "start_sec": 0.0,
            "end_sec": 0.0,
        }
        for line in dialogue
    ]


async def resolve_text_speaker_context(
    session: AsyncSession,
    entry: JournalEntry,
    user_id: uuid.UUID,
) -> dict[str, Any]:
    """Speaker context for precision-text entries (no voice embeddings)."""
    _ = session, user_id
    profiles: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in entry.transcript_segments or []:
        if not isinstance(raw, dict):
            continue
        speaker = str(raw.get("speaker", "")).strip()
        text = str(raw.get("text", "")).strip()
        if not speaker or speaker.lower() in _IGNORE_SPEAKER:
            continue
        if not text or _MEANINGFUL_TEXT_RE.search(text) is None:
            continue
        key = speaker.lower()
        if key in seen:
            continue
        seen.add(key)
        profiles.append(
            {
                "person_name": speaker,
                "person_type": "Speaker",
                "node_id": None,
                "node_name": speaker,
                "has_voice_embedding": False,
                "source": "precision_text",
            }
        )
    return {
        "confirmed_speaker_count": len(profiles),
        "confirmed_speakers": profiles,
        "pre_confirmed_mappings": 0,
        "identity_links": [],
        "entry_source": "precision_text",
    }
