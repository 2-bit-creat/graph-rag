"""Public legal/disclosure endpoints — privacy policy and AI-use notice.

No auth: these must be readable before login and before consent is given."""

import re
from functools import lru_cache
from pathlib import Path

from fastapi import APIRouter, HTTPException, status

from ..config import get_settings

router = APIRouter(prefix="/legal", tags=["legal"])

# Bump when the policy text changes; the client sends this back on consent so we
# can tell who accepted which version.
PRIVACY_POLICY_VERSION = "2026-07-12"

_POLICY_PATH = Path(__file__).resolve().parent.parent / "legal" / "privacy_policy_ko.md"

# AI기본법(2026-01-22 시행) 사전 고지 + 생성물 표시 안내.
_AI_DISCLOSURE = (
    "본 서비스의 일기 정제, 지식그래프 회상 대화, 학습 문항 생성 등 주요 기능은 "
    "생성형 인공지능(AI)에 기반하여 동작합니다. AI가 생성한 결과물에는 'AI 생성' "
    "표시가 부착되며, 생성 결과는 사실과 다를 수 있으니 참고용으로 활용해 주세요."
)


# `{{...}}` markers left in the shipped document. The draft was being served to
# real readers verbatim — service name, effective date and the privacy officer's
# contact all still in braces, next to a note telling the *developer* to have a
# lawyer review it. Anything unfilled is a compliance defect, not a cosmetic one,
# so production refuses to serve the document at all rather than publish a draft.
_PLACEHOLDER_RE = re.compile(r"\{\{[^}]+\}\}")


def policy_placeholders(markdown: str) -> list[str]:
    """Unfilled `{{...}}` markers, in document order and de-duplicated."""
    seen: dict[str, None] = {}
    for match in _PLACEHOLDER_RE.findall(markdown):
        seen.setdefault(match, None)
    return list(seen)


@lru_cache
def _policy_markdown() -> str:
    try:
        return _POLICY_PATH.read_text(encoding="utf-8")
    except OSError:
        return "# 개인정보 처리방침\n\n(문서를 불러올 수 없습니다.)"


@router.get("/privacy-policy")
async def privacy_policy() -> dict:
    markdown = _policy_markdown()
    pending = policy_placeholders(markdown)
    if pending and get_settings().is_production:
        # 503 rather than a redacted document: a privacy policy that is missing
        # its effective date and contact is not a policy, and quietly serving a
        # trimmed one would hide the problem from whoever is shipping.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={
                "code": "privacy_policy_incomplete",
                "message": (
                    "Privacy policy still contains template placeholders: "
                    + ", ".join(pending)
                ),
            },
        )
    return {
        "version": PRIVACY_POLICY_VERSION,
        "language": "ko",
        "content_markdown": markdown,
        # Development only — lets the team see what is still unfilled without
        # reading the raw markdown. Always empty in a correct production build.
        "pending_placeholders": pending,
    }


@router.get("/ai-disclosure")
async def ai_disclosure() -> dict:
    return {"notice": _AI_DISCLOSURE}
