"""Small, explicit policy boundary for the quiz learning loop.

The first version deliberately uses understandable tiered rules rather than a
large opaque score.  Future ranking algorithms can replace these helpers while
the database/API contract (policy version + reason) remains stable.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from .models import Quiz, QuizPolicyDecision

GENERATION_POLICY_VERSION = "generation-v1-inventory-first"
PRESENTATION_POLICY_VERSION = "presentation-v1-tiered"
REVIEW_POLICY_VERSION = "review-v1-sm2"


async def record_policy_decision(
    session: AsyncSession,
    *,
    user_id: uuid.UUID,
    policy: str,
    policy_version: str,
    entity_type: str,
    entity_id: str | uuid.UUID,
    reason: str,
    details: dict[str, Any] | None = None,
) -> None:
    session.add(
        QuizPolicyDecision(
            user_id=user_id,
            policy=policy,
            policy_version=policy_version,
            entity_type=entity_type,
            entity_id=str(entity_id),
            reason=reason,
            details=details or {},
        )
    )


def generation_reason(*, direct_node: bool, queue_missing: int, expression: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    if direct_node:
        return (
            "사용자가 선택한 진술 노드의 미생성 표현을 우선 문제화",
            {"direct_node": True, "queue_missing": queue_missing},
        )
    return (
        "타겟 언어 퀴즈 재고 부족 및 미생성 표현 우선",
        {
            "direct_node": False,
            "queue_missing": queue_missing,
            "expression": expression.get("expression"),
            "utility_score": expression.get("utility_score", 0),
            "kind": expression.get("kind", ""),
        },
    )


def presentation_reason(quiz: Quiz, *, direct_node: bool = False) -> tuple[int, str]:
    """Return a stable tier and a user-readable explanation for a card."""
    if direct_node:
        return 0, "사용자가 지식 그래프에서 직접 선택한 진술 노드"
    now = datetime.now(UTC)
    if quiz.queue_kind == "review" and quiz.next_review_at and quiz.next_review_at < now:
        if quiz.times_wrong:
            return 1, "복습 예정일이 지났고 이전 오답 이력이 있음"
        return 2, "복습 예정일이 지남"
    if quiz.queue_kind == "review":
        return 3, "오늘의 복습 큐에 포함됨"
    return 4, "아직 풀지 않은 새 문제"


def review_reason(quiz: Quiz, *, correct: bool, quality: int, hint_level: int = 0) -> tuple[str, dict[str, Any]]:
    outcome = "정답" if correct else "오답"
    return (
        f"{outcome} 결과와 품질 점수로 다음 복습 시점을 계산",
        {
            "correct": correct,
            "quality": quality,
            "hint_level": hint_level,
            "next_review_at": quiz.next_review_at.isoformat() if quiz.next_review_at else None,
            "interval_days": quiz.interval_days,
            "repetitions": quiz.repetitions,
        },
    )
