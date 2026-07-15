"""Regression tests for the two-stage expression-chunk bundle pipeline."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from app import node_expression_store, quiz_bundle
from app.models import Node


class _Completions:
    def __init__(self, responses: list[dict]) -> None:
        self.responses = responses
        self.calls: list[dict] = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(self.responses.pop(0))))]
        )


@pytest.mark.asyncio
async def test_card_is_saved_without_a_subjective_qa_call(
    db_session, iso_user, monkeypatch
) -> None:
    source = "두 보고서를 꼼꼼히 비교했다."
    node = Node(
        user_id=iso_user.id,
        name="comparison",
        type="Statement",
        description=json.dumps({"content": source}),
    )
    db_session.add(node)
    await db_session.commit()
    plan = {
        "composition": {
            "prompt": source,
            "model_answers": [{"text": "I carefully compared two reports."}],
        },
        "expression_chunks": [
            {
                "text": "carefully compared",
                "meaning": "꼼꼼히 비교했다",
                "kind": "collocation",
            }
        ],
    }
    cloze = {
        "cloze": [
            {
                "expression": "carefully compared",
                "question_ko": "표현을 완성하세요.",
                "sentence_ko": source,
                "target_ko": "꼼꼼히 비교했다",
                "sentence_en": "I carefully compared two reports.",
                "blank": "carefully compared",
            }
        ]
    }
    completions = _Completions([plan, cloze])
    monkeypatch.setattr(
        quiz_bundle,
        "_client",
        lambda: SimpleNamespace(chat=SimpleNamespace(completions=completions)),
    )
    saved: list[dict] = []

    async def capture_expressions(*args, **kwargs):
        saved.extend(args[3])

    monkeypatch.setattr(node_expression_store, "save_node_expressions", capture_expressions)

    async def no_audio(*args, **kwargs):
        return None, None

    monkeypatch.setattr(quiz_bundle, "synthesize_quiz_audio", no_audio)

    created, _ = await quiz_bundle.generate_quiz_bundle(
        db_session,
        iso_user,
        language="english",
        seed_node_ids={str(node.id)},
    )

    assert [quiz.quiz_type for quiz in created] == ["composition", "cloze"]
    assert [item["expression"] for item in saved] == ["carefully compared"]
    assert len(completions.calls) == 2  # plan + cloze; no QA or repair call
    assert completions.calls[0]["response_format"]["type"] == "json_schema"
    assert completions.calls[0]["response_format"]["json_schema"]["strict"] is True
    assert completions.calls[1]["response_format"]["type"] == "json_schema"
    assert source in completions.calls[0]["messages"][1]["content"]
    assert "Return only the composition and cloze arrays" not in completions.calls[0]["messages"][0]["content"]
    cloze_payload = json.loads(completions.calls[1]["messages"][1]["content"])
    assert cloze_payload["source_statement"] == source
    assert [item["text"] for item in cloze_payload["expressions"]] == ["carefully compared"]


def test_proper_name_expression_chunks_are_excluded() -> None:
    assert quiz_bundle._usable_expression_chunks(
        [
            {"text": "reviewed carefully", "kind": "collocation"},
            {"text": "CES2025", "kind": "domain_term"},
            {"text": "Industrial Bank", "kind": "organization"},
            {"text": "at the Antock webpage", "kind": "collocation"},
        ],
        language="english",
    ) == {"reviewed carefully"}


def test_german_common_noun_capitalization_is_allowed() -> None:
    assert quiz_bundle._usable_expression_chunks(
        [
            {"text": "die Bewertungsindikatoren analysieren", "kind": "verb_phrase"},
            {"text": "Shinhan Investment Corp", "kind": "organization"},
        ],
        language="german",
    ) == {"die bewertungsindikatoren analysieren"}


@pytest.mark.parametrize(
    ("language", "canonical", "answer", "sentence", "excluded", "expected"),
    [
        (
            "english",
            "on the webpage",
            "at the Antock webpage",
            "You can view it at the Antock webpage.",
            ["Antock"],
            "excluded context entity",
        ),
        (
            "german",
            "auf der Webseite von",
            "Auf der Webseite von Entok",
            "Auf der Webseite von Entok kann man es sehen.",
            ["Entok"],
            "excluded context entity",
        ),
        (
            "english",
            "on the webpage",
            "at the Antock webpage",
            "You can view it at the Antock webpage.",
            [],
            "entity-like token",
        ),
    ],
)
def test_surface_answer_cannot_expand_expression_with_a_proper_name(
    language, canonical, answer, sentence, excluded, expected
) -> None:
    reason = quiz_bundle._surface_answer_contract_reason(
        answer=answer,
        sentence_target=sentence,
        canonical_form=canonical,
        excluded_target_terms=excluded,
        language=language,
    )

    assert expected in (reason or "")


def test_inflected_surface_answer_without_context_entity_is_allowed() -> None:
    assert quiz_bundle._surface_answer_contract_reason(
        answer="reviewed the report",
        sentence_target="I reviewed the report yesterday.",
        canonical_form="review a report",
        excluded_target_terms=["Antock"],
        language="english",
    ) is None


def test_cloze_candidate_with_antock_in_blank_is_rejected() -> None:
    candidates, reasons = quiz_bundle._prepare_cloze_candidates(
        [{
            "expression_id": "0:0",
            "canonical_form": "on the webpage",
            "surface_answer": "at the Antock webpage",
            "sentence_target": "You can view the screen at the Antock webpage.",
            "sentence_ko": "앤톡 웹페이지에서 화면을 확인할 수 있습니다.",
            "target_ko": "웹페이지에서",
            "question_ko": "빈칸을 완성하세요.",
        }],
        language="english",
        level=45,
        source_meta={"node_id": "node-1"},
        expression_contracts={
            "0:0": {
                "canonical_form": "on the webpage",
                "excluded_target_terms": ["Antock"],
            }
        },
    )

    assert candidates == []
    assert any("excluded context entity 'Antock'" in reason for reason in reasons)


def test_target_language_prompt_uses_localized_quality_rubric() -> None:
    prompt = quiz_bundle._build_plan_system_prompt(
        "Korean (한국어)",
        "German (Deutsch)",
        45,
        quiz_bundle.lang_guide("german"),
        "german",
    )

    assert "Formuliere idiomatisches, modernes Deutsch" in prompt
    assert "context_entities" in prompt
    assert "auf der Webseite von Entok" in prompt


def test_statement_is_split_into_stable_composition_units() -> None:
    assert quiz_bundle._split_statement_units(
        "보고서를 확인했습니다. 결과를 엑셀로 정리했습니다."
    ) == ["보고서를 확인했습니다.", "결과를 엑셀로 정리했습니다."]


def test_plain_detail_does_not_license_english_comparative() -> None:
    segments = [{
        "segment_index": 0,
        "reference_answers": [{
            "text": "You can take a closer look at the platform screen."
        }],
        "expressions": [{
            "canonical_form": "take a closer look at",
            "surface_form": "take a closer look at",
            "surface_segments": ["take a closer look at"],
            "meaning": "~을 더 자세히 살펴보다",
            "meaning_parts": [{"target": "closer", "native": "더 자세히"}],
        }],
    }]

    changes = quiz_bundle._normalize_unlicensed_detail_comparatives(
        segments,
        ["플랫폼 화면을 자세히 확인할 수 있습니다."],
        "english",
    )

    assert changes
    assert segments[0]["reference_answers"][0]["text"] == (
        "You can take a close look at the platform screen."
    )
    expression = segments[0]["expressions"][0]
    assert expression["canonical_form"] == "take a close look at"
    assert expression["meaning"] == "~을 자세히 살펴보다"
    assert expression["meaning_parts"] == [
        {"target": "close", "native": "자세히"}
    ]


def test_explicit_more_detail_keeps_english_comparative() -> None:
    segments = [{
        "segment_index": 0,
        "reference_answers": [{"text": "Take a closer look."}],
        "expressions": [{"canonical_form": "take a closer look"}],
    }]

    changes = quiz_bundle._normalize_unlicensed_detail_comparatives(
        segments,
        ["더 자세히 살펴보세요."],
        "english",
    )

    assert changes == []
    assert segments[0]["expressions"][0]["canonical_form"] == (
        "take a closer look"
    )


@pytest.mark.asyncio
async def test_multiple_segments_and_inflected_surface_answers_are_created(
    db_session, iso_user, monkeypatch
) -> None:
    source = "보고서를 확인했습니다. 화면을 더 자세히 살펴봤습니다."
    node = Node(
        user_id=iso_user.id,
        name="multi-segment",
        type="Statement",
        description=json.dumps({"content": source}),
    )
    db_session.add(node)
    await db_session.commit()
    plan = {
        "segments": [
            {
                "segment_index": 0,
                "reference_answers": [{"text": "I reviewed the report."}],
                "expressions": [{
                    "canonical_form": "review a report",
                    "surface_form": "reviewed the report",
                    "surface_segments": ["reviewed the report"],
                    "meaning": "보고서를 검토하다",
                    "meaning_parts": [],
                    "kind": "verb_phrase",
                }],
            },
            {
                "segment_index": 1,
                "reference_answers": [{"text": "I took a closer look at the screen."}],
                "expressions": [{
                    "canonical_form": "take a closer look at",
                    "surface_form": "took a closer look at",
                    "surface_segments": ["took a closer look at"],
                    "meaning": "~을 더 자세히 살펴보다",
                    "meaning_parts": [{"target": "closer", "native": "더 자세히"}],
                    "kind": "verb_phrase",
                }],
            },
        ]
    }
    cloze = {"cloze": [
        {
            "expression_id": "0:0",
            "canonical_form": "review a report",
            "surface_answer": "reviewed the report",
            "sentence_target": "I reviewed the report before the meeting.",
            "sentence_ko": "회의 전에 보고서를 검토했습니다.",
            "target_ko": "보고서를 검토했습니다",
            "question_ko": "빈칸을 완성하세요.",
        },
        {
            "expression_id": "1:0",
            "canonical_form": "take a closer look at",
            "surface_answer": "took a closer look at",
            "sentence_target": "I took a closer look at the screen.",
            "sentence_ko": "화면을 더 자세히 살펴봤습니다.",
            "target_ko": "더 자세히 살펴봤습니다",
            "question_ko": "빈칸을 완성하세요.",
        },
    ]}
    completions = _Completions([plan, cloze])
    monkeypatch.setattr(
        quiz_bundle,
        "_client",
        lambda: SimpleNamespace(chat=SimpleNamespace(completions=completions)),
    )

    async def no_audio(*args, **kwargs):
        return None, None

    monkeypatch.setattr(quiz_bundle, "synthesize_quiz_audio", no_audio)
    created, _ = await quiz_bundle.generate_quiz_bundle(
        db_session, iso_user, language="english", seed_node_ids={str(node.id)}
    )

    assert [quiz.quiz_type for quiz in created] == [
        "composition", "composition", "cloze", "cloze"
    ]
    compositions = [quiz for quiz in created if quiz.quiz_type == "composition"]
    assert [quiz.question_ko for quiz in compositions] == [
        "보고서를 확인했습니다.", "화면을 더 자세히 살펴봤습니다."
    ]
    closer = next(
        quiz for quiz in created
        if (quiz.quiz_data or {}).get("canonical_form") == "take a closer look at"
    )
    assert closer.quiz_data["surface_form"] == "took a closer look at"
    assert closer.quiz_data["meaning"] == "~을 더 자세히 살펴보다"
    assert len(completions.calls) == 2
