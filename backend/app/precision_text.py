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

# 대괄호 없는 "이름: 내용" 줄 (카톡·회의록 붙여넣기). 이름은 숫자 없는 12자
# 이하 한글/영문(+공백·점·언더스코어) — 시간("12:30")·목록 콜론 오탐 방지.
_BARE_SPEAKER_LINE_RE = re.compile(
    r"^\s*(?P<speaker>[A-Za-z가-힣][A-Za-z가-힣 ._-]{0,11}?)\s*[:：]\s*(?P<text>.+?)\s*$"
)


def _pre_slice_bare_speaker_lines(paragraph_text: str) -> list[dict[str, str]]:
    """Heuristic fallback for un-bracketed "이름: 내용" dialogue pastes.

    산문 속 콜론("결심: …", "주의: …", URL)을 대화로 오인하지 않도록 보수적으로:
    ① 서로 다른 화자 2명 이상, ② **화자당 평균 2턴 이상**, ③ 비어있지 않은 줄의
    60% 이상이 매칭될 때만 대화로 인정. 미분리로 남아도 화자 확인 UI에서 지정 가능.

    ②가 이 함수의 핵심 판별식이다. 대화는 소수의 화자가 번갈아 **반복** 등장하지만,
    용어사전·강의노트("약정액: …", "설정액: …", "ROE: …")는 줄마다 새 이름이 나온다.
    예전 조건은 "한 화자가 2번 이상 OR 매칭 4줄 이상"이었는데, 뒤쪽 우회로 때문에
    한 번도 반복되지 않는 24줄짜리 금융 용어 정리가 화자 23명짜리 대화로 잘려
    개념 하나하나가 Identity 노드로 그래프에 박혔다. 평균 턴 수는 그 둘을 정확히
    가른다 — 2인 대화 20줄이면 10턴/인, 용어사전 24줄이면 1.04턴/인.
    """
    raw_lines = [l.strip() for l in paragraph_text.splitlines() if l.strip()]
    parsed: list[dict[str, str]] = []
    matched = 0
    for line in raw_lines:
        m = _BARE_SPEAKER_LINE_RE.match(line)
        speaker = m.group("speaker").strip() if m else ""
        text = m.group("text").strip() if m else ""
        if m and not text.startswith("//"):
            parsed.append({"speaker": speaker, "text": text})
            matched += 1
        elif parsed:
            # 이어지는 줄은 사용자가 넣은 줄바꿈을 살려 붙인다(공백 병합 금지) —
            # 목록·문단 구조가 화자별 스크립트에 그대로 남게.
            parsed[-1]["text"] = f"{parsed[-1]['text']}\n{line}".strip()
    counts: dict[str, int] = {}
    for p in parsed:
        counts[p["speaker"]] = counts.get(p["speaker"], 0) + 1
    # 화자당 평균 2턴 이상. 대화에서는 자연스럽게 성립하고, 줄마다 새 용어가 오는
    # 정의 목록에서는 절대 성립하지 않는다. 애매하면 대화가 아니라고 본다 —
    # 놓쳤을 때의 비용(사용자가 화자 확인 UI에서 지정)이 잘못 잘랐을 때의 비용
    # (지식그래프에 가짜 인물 노드 수십 개)보다 훨씬 싸다.
    recurring_enough = matched >= len(counts) * 2
    if len(counts) >= 2 and recurring_enough and matched * 5 >= len(raw_lines) * 3:
        return parsed
    return []


def pre_slice_by_speaker_lines(paragraph_text: str) -> list[dict[str, str]]:
    """Parse [화자명]: line blocks without merging same-speaker lines.

    대괄호 형식이 하나도 없으면 "이름: 내용" 맨살 형식을 휴리스틱으로 시도한다
    (카톡·회의록 붙여넣기 자동 화자 분리 — 2026-07-04 텍스트/음성 통일 흐름).
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
            # 줄바꿈 보존(공백 병합 금지) — 위 _pre_slice_bare_speaker_lines와 동일.
            lines[-1]["text"] = f"{lines[-1]['text']}\n{line}".strip()
    if not lines:
        return _pre_slice_bare_speaker_lines(paragraph_text)
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
