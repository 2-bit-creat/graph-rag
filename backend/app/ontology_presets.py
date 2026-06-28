"""Named ontology presets — seed data and apply-by-name targets."""

from __future__ import annotations

from typing import TypedDict


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
    "description": "일상 대화/일기 — Statement 3노드 구조 (Speaker · Statement · Concept)",
    "entity_types": [
        {"name": "Speaker", "color": "#ff8c42", "description": "화자 · 인물"},
        {"name": "Statement", "color": "#6366f1", "description": "화자의 발화 · 진술 단위"},
        {"name": "Concept", "color": "#5b9dff", "description": "도메인 개념 · 고유명사"},
    ],
    "relation_types": [
        "SPOKE",
        "MENTIONS",
        "RELATED_TO",
    ],
}

ONTOLOGY_PRESETS: dict[str, OntologyPreset] = {
    LEARNING_GRAPH["ontology_name"]: LEARNING_GRAPH,
    FINANCIAL_IT_KNOWLEDGE_GRAPH["ontology_name"]: FINANCIAL_IT_KNOWLEDGE_GRAPH,
    DAILY_LIFE_ENGLISH["ontology_name"]: DAILY_LIFE_ENGLISH,
}
