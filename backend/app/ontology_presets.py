"""Named ontology presets — seed data and apply-by-name targets."""

from __future__ import annotations

from typing import TypedDict

from .entity_types import is_person_like_type, is_source_like_type, type_group_key


class OntologyPreset(TypedDict):
    ontology_name: str
    entity_types: list[dict]
    relation_types: list[str]
    description: str


LEARNING_GRAPH: OntologyPreset = {
    "ontology_name": "Learning_Graph",
    "description": "학습·개념 중심 기본 온톨로지",
    "entity_types": [
        {"name": "Concept", "color": "#6366f1", "description": "추상적 개념, 이론적 주제"},
        {"name": "Topic", "color": "#0ea5e9", "description": "학습 주제, 큰 단위의 분야"},
        {"name": "Definition", "color": "#22c55e", "description": "용어의 정의"},
        {"name": "Example", "color": "#f59e0b", "description": "구체적 사례, 예시"},
        {"name": "Theory", "color": "#a855f7", "description": "이론, 학술적 틀"},
        {"name": "Person", "color": "#ef4444", "description": "실제 인물 이름만 (직급·직책 제외)"},
        {"name": "Role", "color": "#f97316", "description": "직급, 직책, 역할 (사람 이름이 아님)"},
        {"name": "Tool", "color": "#14b8a6", "description": "도구, 방법론, 기법"},
    ],
    "relation_types": [
        "IS_A",
        "PART_OF",
        "PREREQUISITE_OF",
        "RELATED_TO",
        "EXAMPLE_OF",
        "DEFINED_AS",
    ],
}

FINANCIAL_IT_KNOWLEDGE_GRAPH: OntologyPreset = {
    "ontology_name": "Financial_IT_Knowledge_Graph",
    "description": "금융 IT 도메인 — 기관, 규제, 리스크, 기술 중심",
    "entity_types": [
        {
            "name": "Organization",
            "color": "#3b82f6",
            "description": "금융 기관, IT 벤더, 규제 기관",
        },
        {
            "name": "Person",
            "color": "#ef4444",
            "description": "관련 인물 (실명)",
        },
        {
            "name": "Regulation",
            "color": "#8b5cf6",
            "description": "금융 규제, 컴플라이언스 규정",
        },
        {
            "name": "FinancialInstrument",
            "color": "#f59e0b",
            "description": "금융 상품, 파생상품, 채권 등",
        },
        {
            "name": "RiskMetric",
            "color": "#ec4899",
            "description": "VaR, Greeks, CVaR 등 리스크 지표",
        },
        {
            "name": "Technology",
            "color": "#14b8a6",
            "description": "IT 시스템, 플랫폼, 소프트웨어",
        },
        {
            "name": "Document",
            "color": "#64748b",
            "description": "보고서, 명세서, 정책 문서",
        },
        {
            "name": "Task",
            "color": "#22c55e",
            "description": "업무, 프로젝트 작업",
        },
    ],
    "relation_types": [
        "EMPLOYS",
        "CONTRIBUTES_TO",
        "USES",
        "PRODUCES",
        "COMPLIES_WITH",
        "MEASURED_BY",
        "IMPLEMENTS_CALCULATION_OF",
        "SUBJECT_TO",
        "HOLDS",
        "REFERENCES",
    ],
}

DAILY_LIFE_ENGLISH: OntologyPreset = {
    "ontology_name": "DailyLife_English",
    "description": "일상 대화/일기 — 정체성-진술-개념 3계층 (Identity · Statement · Concept)",
    "entity_types": [
        {
            "name": "Identity",
            "color": "#f07b5b",
            "description": "정체성 카테고리 — 이름/별칭으로 재식별되는 반복 등장 개체 전체 "
            "(Person·Source 포함 상위 분류이자, 사람도 매체도 아닌 반려동물·단체 등의 기본 타입)",
        },
        {
            "name": "Person",
            "color": "#ff8c42",
            "description": "Identity의 하위 타입 — 실존 인물. 동명이인이어도 Source와는 병합되지 않음",
            "parent": "Identity",
        },
        {
            "name": "Source",
            "color": "#ffc53d",
            "description": "Identity의 하위 타입 — 매체·기관·AI 등 발화 귀속처. "
            "화자로 지정할 수 있지만 사람과는 병합되지 않음",
            "parent": "Identity",
        },
        {"name": "Statement", "color": "#b07bff", "description": "화자(Identity)의 발화 · 진술 단위"},
        {"name": "Concept", "color": "#5b9dff", "description": "진술이 언급하는 도메인 개념 · 고유명사"},
    ],
    "relation_types": [
        "SPOKE_OR_PUBLISHED",
        "MENTIONS",
        "RELATED_TO",
    ],
}

ONTOLOGY_PRESETS: dict[str, OntologyPreset] = {
    LEARNING_GRAPH["ontology_name"]: LEARNING_GRAPH,
    FINANCIAL_IT_KNOWLEDGE_GRAPH["ontology_name"]: FINANCIAL_IT_KNOWLEDGE_GRAPH,
    DAILY_LIFE_ENGLISH["ontology_name"]: DAILY_LIFE_ENGLISH,
}

# Canonical Identity/Person/Source/Statement/Concept definitions from
# DAILY_LIFE_ENGLISH, keyed lowercase for lookup by name.
_IDENTITY_HIERARCHY_BY_KEY: dict[str, dict] = {
    et["name"].lower(): et for et in DAILY_LIFE_ENGLISH["entity_types"]
}


def ensure_identity_hierarchy(entity_types: list[dict]) -> list[dict]:
    """Backfill the Identity/Person/Source structural types for display.

    Ontology rows seeded before the 정체성-진술-개념 model existed (or from an
    older preset) may still say just "Speaker"/"Statement"/"Concept". The
    Identity/Person/Source distinction is a structural given of the graph
    model (see entity_types.py), not something the ontology editor invents,
    so the settings sheet should always show it correctly regardless of what
    happens to be stored — this only affects the returned response, never
    what's persisted.

    A stored legacy alias for Person/Source (e.g. "Speaker", the pre-split
    name for what Person means now) is MIGRATED in place to the canonical
    entry rather than left alongside a separately-appended "Person" — showing
    both "Speaker" and "Person" as if they were two different types is exactly
    the same role twice, which reads as a duplicate/confusing list rather than
    an update.
    """
    result: list[dict] = []
    present: set[str] = set()
    for et in entity_types:
        name = str(et.get("name", ""))
        key = type_group_key(name)
        if key != "person" and is_person_like_type(name):
            result.append(dict(_IDENTITY_HIERARCHY_BY_KEY["person"]))
            present.add("person")
            continue
        if key != "source" and is_source_like_type(name):
            result.append(dict(_IDENTITY_HIERARCHY_BY_KEY["source"]))
            present.add("source")
            continue
        result.append(dict(et))
        present.add(key)
    for key in ("identity", "person", "source"):
        if key not in present:
            result.append(dict(_IDENTITY_HIERARCHY_BY_KEY[key]))
    return result
