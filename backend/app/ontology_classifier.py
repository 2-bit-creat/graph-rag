"""Post-extraction LLM pass: re-classify entity types against the ontology.

SchemaLLMPathExtractor picks labels from the allowed set but can mis-tag
(e.g. a job title as Person). This lightweight classifier corrects types using
per-type descriptions before staging is returned to the user.
"""

import json
from functools import lru_cache

from openai import AsyncOpenAI

from .config import get_settings

# Fallback descriptions when ontology rows lack a `description` field.
CLASSIFIER_SYSTEM_PROMPT = (
    "You classify knowledge-graph entity names into ontology types. "
    'Return JSON only: {"corrections": {"entity name": "Type", ...}} '
    "Include ONLY entities whose type should change. "
    "Job titles and roles must NOT be Person. Use Role if available, else Concept."
)

TYPE_DESCRIPTIONS: dict[str, str] = {
    "Concept": "추상적 개념, 이론적 주제, 일반 명사 개념",
    "Topic": "학습 주제, 큰 단위의 분야/영역",
    "Definition": "용어의 정의, '~란 …이다' 형태의 설명",
    "Example": "구체적 사례, 예시",
    "Theory": "이론, 학술적 틀, 모델",
    "Person": "실제 인물 이름만 (직급·직책·역할명은 해당 없음)",
    "Role": "직급, 직책, 역할, 포지션 (사람 이름이 아님)",
    "Tool": "도구, 방법론, 기법, 프레임워크",
    "Organization": "금융 기관, IT 벤더, 규제 기관",
    "Regulation": "금융 규제, 컴플라이언스 규정",
    "FinancialInstrument": "금융 상품, 파생상품, 채권 등",
    "RiskMetric": "VaR, Greeks, CVaR 등 리스크 지표",
    "Technology": "IT 시스템, 플랫폼, 소프트웨어",
    "Document": "보고서, 명세서, 정책 문서",
    "Task": "업무, 프로젝트 작업",
}


@lru_cache
def _client() -> AsyncOpenAI:
    return AsyncOpenAI(api_key=get_settings().openai_api_key)


async def refine_entity_types(
    entities: list[tuple[str, str]],
    entity_types: list[dict],
) -> dict[str, str]:
    """Return {entity_name: corrected_type} for entities that need re-tagging."""
    if not entities:
        return {}

    unique = list({name.strip(): typ for name, typ in entities if name.strip()}.items())
    if not unique:
        return {}

    type_lines = []
    allowed = []
    for et in entity_types:
        name = et.get("name", "")
        if not name:
            continue
        allowed.append(name)
        desc = et.get("description") or TYPE_DESCRIPTIONS.get(name, "")
        type_lines.append(f"- {name}: {desc}")

    if not allowed:
        return {}

    entity_lines = "\n".join(f'- "{n}" (현재: {t})' for n, t in unique)

    system = CLASSIFIER_SYSTEM_PROMPT
    user = (
        f"Allowed types:\n" + "\n".join(type_lines) + "\n\n"
        f"Entities:\n{entity_lines}"
    )

    settings = get_settings()
    resp = await _client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        temperature=0,
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or "{}"
    try:
        data = json.loads(raw)
        corrections = data.get("corrections", {})
        return {
            k: v
            for k, v in corrections.items()
            if isinstance(v, str) and v in allowed
        }
    except json.JSONDecodeError:
        return {}
