"""Public legal/disclosure endpoints — privacy policy and AI-use notice.

No auth: these must be readable before login and before consent is given."""

from functools import lru_cache
from pathlib import Path

from fastapi import APIRouter

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


@lru_cache
def _policy_markdown() -> str:
    try:
        return _POLICY_PATH.read_text(encoding="utf-8")
    except OSError:
        return "# 개인정보 처리방침\n\n(문서를 불러올 수 없습니다.)"


@router.get("/privacy-policy")
async def privacy_policy() -> dict:
    return {
        "version": PRIVACY_POLICY_VERSION,
        "language": "ko",
        "content_markdown": _policy_markdown(),
    }


@router.get("/ai-disclosure")
async def ai_disclosure() -> dict:
    return {"notice": _AI_DISCLOSURE}
