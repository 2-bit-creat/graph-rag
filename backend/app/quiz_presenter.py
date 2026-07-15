"""Display helpers for quiz queue API."""

from __future__ import annotations

import uuid

from .models import Quiz


def _target_from_quiz_data(quiz: Quiz) -> str:
    data = quiz.quiz_data or {}
    qt = quiz.quiz_type
    if qt == "cloze":
        blank = data.get("blank")
        if blank:
            return str(blank)
        accepted = data.get("accepted_answers") or []
        return str(accepted[0]) if accepted else ""
    if qt == "scramble":
        return str(data.get("sentence_en") or quiz.sentence_en or "")
    if qt == "mcq_nuance":
        opts = data.get("options") or []
        idx = data.get("correct_index")
        if idx is not None and 0 <= int(idx) < len(opts):
            return str(opts[int(idx)])
        return str(data.get("prompt_ko") or quiz.question_ko or "")
    return quiz.sentence_en or quiz.question_ko or ""


_LANG_LABEL = {
    "english": "영어", "german": "독일어", "japanese": "일본어", "chinese": "중국어",
    "spanish": "스페인어", "french": "프랑스어", "portuguese": "포르투갈어",
    "italian": "이탈리아어", "arabic": "아랍어", "russian": "러시아어",
}


def _source_label(quiz: Quiz) -> str:
    """Human-readable provenance badge from quiz_data._source (empty for old rows)."""
    data = quiz.quiz_data or {}
    src = data.get("_source")
    if not isinstance(src, dict):
        return ""
    mode = src.get("mode")
    lang = _LANG_LABEL.get(str(src.get("language") or "").lower(), "")
    if mode in ("statement", "bundle"):
        return "지식그래프 문장 기반"
    if mode == "default":
        return f"{lang} 기본 단어장".strip()
    # custom user list
    vocab_id = str(src.get("vocab_id") or "")
    if vocab_id == "ielts":
        return "IELTS"
    return "저장한 표현"


def _context_sentence(quiz: Quiz) -> str:
    data = quiz.quiz_data or {}
    if quiz.quiz_type == "cloze":
        return str(data.get("prompt_en") or quiz.sentence_en or "")
    if quiz.quiz_type == "scramble":
        return str(data.get("sentence_en") or quiz.sentence_en or "")
    if quiz.quiz_type == "mcq_nuance":
        return str(data.get("prompt_ko") or quiz.question_ko or "")
    return quiz.sentence_en or quiz.question_ko or ""


def quiz_queue_item_dict(
    quiz: Quiz,
    node_names: dict[uuid.UUID, str],
) -> dict:
    target_node = ""
    if quiz.source_nodes:
        names = [node_names[nid] for nid in quiz.source_nodes if nid in node_names]
        target_node = ", ".join(names) if names else ""
    if not target_node:
        target_node = _target_from_quiz_data(quiz)

    priority: int | None = None
    reason: str | None = None
    if quiz.queue_kind == "review":
        if quiz.quiz_type == "composition":
            quality = quiz.last_quality if quiz.last_quality is not None else 5
            priority = 100 + quality
            reason = f"작문 점수 {quality}/5 · 같은 점수에서는 오래 푼 문제 우선"
        elif quiz.times_wrong > 0:
            priority = 1
            reason = "이전 오답 · 회복 복습 우선"
        else:
            priority = 200
            reason = "정답 이력 · 오래 푼 문제부터 복습"

    return {
        "id": quiz.id,
        "quiz_type": quiz.quiz_type,
        "queue_kind": quiz.queue_kind,
        "difficulty_level": quiz.difficulty_level,
        "target_node": target_node,
        "source_label": _source_label(quiz),
        "context_sentence": _context_sentence(quiz),
        "question_ko": quiz.question_ko,
        "sentence_en": quiz.sentence_en,
        "quiz_data": quiz.quiz_data if isinstance(quiz.quiz_data, dict) else None,
        "next_review_at": quiz.next_review_at,
        "streak": quiz.repetitions,
        "times_correct": quiz.times_correct,
        "times_wrong": quiz.times_wrong,
        "last_quality": quiz.last_quality,
        "last_answered_at": quiz.last_answered_at,
        "review_priority": priority,
        "review_reason": reason,
        "created_at": quiz.created_at,
        "associated_entry_id": quiz.associated_entry_id,
        "track": quiz.track,
        "batch_id": quiz.batch_id,
        "source_kind": quiz.source_kind,
        "language": quiz.language or str((quiz.quiz_data or {}).get("language") or "english"),
    }
