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


def test_cloze_author_prompt_requires_complete_native_translation() -> None:
    """The single-card author must translate the complete target sentence and
    copy the exact corresponding native span, without a separate translation call."""
    prompt = quiz_bundle._build_cloze_system_prompt(
        "Korean (한국어)", "English", 50, quiz_bundle.lang_guide("english"), "english"
    )
    assert "sentence_native must be the complete sentence" in prompt
    assert "completely translate sentence_target" in prompt
    assert "answer_native must be copied verbatim" in prompt


def test_release_prompt_rejects_conservative_rate_scope_mismatch() -> None:
    prompt = quiz_bundle._build_cloze_qa_system_prompt("Korean (한국어)", "English")
    assert "a conservative discount rate" in prompt
    assert "보수적으로" in prompt
    assert "보수적인 할인율" in prompt
    assert "semantic_scope_mismatch" in prompt
    assert "part_of_speech_mismatch" in prompt
    assert "score < 92" in prompt
    assert "part of the faithful short source sentence" in prompt


def test_author_prompt_uses_language_neutral_model_fields() -> None:
    prompt = quiz_bundle._build_cloze_system_prompt(
        "English", "Korean (한국어)", 50, quiz_bundle.lang_guide("korean"), "korean"
    )
    assert "sentence_target to that complete reference answer" in prompt
    assert "sentence_native must be the complete sentence" in prompt
    assert "answer_native must be copied verbatim" in prompt
    assert '"sentence_native"' in prompt
    assert '"answer_native"' in prompt
    assert "sibling expression may remain as context outside surface_answer" in prompt


def test_language_neutral_model_fields_map_to_legacy_storage_fields() -> None:
    mapped = quiz_bundle._store_legacy_cloze_fields({
        "question_native": "Complete the sentence.",
        "sentence_native": "He applied a conservative discount rate.",
        "answer_native": "a conservative discount rate",
    })
    assert mapped == {
        "question_ko": "Complete the sentence.",
        "sentence_ko": "He applied a conservative discount rate.",
        "target_ko": "a conservative discount rate",
    }
    assert quiz_bundle._review_cloze_view(mapped) == {
        "question_native": "Complete the sentence.",
        "sentence_native": "He applied a conservative discount rate.",
        "answer_native": "a conservative discount rate",
    }


def test_reviewed_meaning_parts_recover_exact_native_source_span() -> None:
    source = "He is applying a conservative discount rate to account for uncertainty."
    core = {
        "meaning": "to apply a conservative discount rate",
        "meaning_parts": [
            {"native": "conservative"},
            {"native": "discount rate"},
            {"native": "to apply"},
        ],
    }
    purpose = {"meaning": "to account for uncertainty", "meaning_parts": []}
    assert quiz_bundle._source_alignment_span(source, core) == (
        "is applying a conservative discount rate"
    )
    assert quiz_bundle._source_alignment_span(source, purpose) == "to account for uncertainty"


def test_missing_or_low_quality_review_fails_closed() -> None:
    items = [{"expression_id": "good"}, {"expression_id": "missing"}]
    reviews = {
        "good": {"expression_id": "good", "verdict": "pass", "score": 91, "issues": []}
    }
    assert quiz_bundle._quality_feedback_for_items(items, reviews) == {
        "good": ["quality_score_below_release_bar"],
        "missing": ["missing_quality_review"],
    }


@pytest.mark.asyncio
async def test_card_is_saved_after_independent_full_translation(
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
    review = {
        "reviews": [{
            "expression_id": "0:0",
            "verdict": "pass",
            "score": 94,
            "issues": [],
        }],
    }
    completions = _Completions([plan, plan, cloze, review])
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
        return None, None, None

    monkeypatch.setattr(quiz_bundle, "synthesize_quiz_audio_assets", no_audio)

    created, _ = await quiz_bundle.generate_quiz_bundle(
        db_session,
        iso_user,
        language="english",
        seed_node_ids={str(node.id)},
    )

    assert [quiz.quiz_type for quiz in created] == ["composition", "cloze"]
    assert [item["expression"] for item in saved] == ["carefully compared"]
    assert len(completions.calls) == 4  # plan + plan review + individual card + batch review
    assert completions.calls[0]["response_format"]["type"] == "json_schema"
    assert completions.calls[0]["response_format"]["json_schema"]["strict"] is True
    assert completions.calls[1]["response_format"]["type"] == "json_schema"
    assert completions.calls[2]["response_format"]["json_schema"]["strict"] is True
    assert source in completions.calls[0]["messages"][1]["content"]
    assert "Return only the composition and cloze arrays" not in completions.calls[0]["messages"][0]["content"]
    cloze_payload = json.loads(completions.calls[2]["messages"][1]["content"])
    assert cloze_payload["source_statement"] == source
    assert cloze_payload["expression"]["canonical_form"] == "carefully compared"


@pytest.mark.asyncio
async def test_quality_review_repairs_only_the_failed_card(
    db_session, iso_user, monkeypatch
) -> None:
    source = "회의 전에 핵심 지표를 꼼꼼히 검토했다."
    node = Node(
        user_id=iso_user.id,
        name="metric-review",
        type="Statement",
        description=json.dumps({"content": source}),
    )
    db_session.add(node)
    await db_session.commit()
    plan = {"segments": [{
        "segment_index": 0,
        "reference_answers": [{"text": "I carefully reviewed the key metrics before the meeting."}],
        "expressions": [{
            "canonical_form": "carefully review",
            "surface_form": "carefully reviewed",
            "surface_segments": ["carefully reviewed"],
            "meaning": "꼼꼼히 검토하다",
            "meaning_parts": [{"target": "carefully reviewed", "native": "꼼꼼히 검토했다"}],
            "kind": "collocation",
            "quality_score": 94,
        }],
    }]}
    first_card = {"cloze": [{
        "expression_id": "0:0",
        "canonical_form": "carefully review",
        "surface_answer": "carefully reviewed",
        "question_ko": "빈칸을 완성하세요.",
        "sentence_ko": "회의 전에 핵심 지표를 검토했습니다.",
        "target_ko": "검토했습니다",
        "sentence_target": "I carefully reviewed the key metrics before the meeting.",
    }]}
    review = {"reviews": [{
        "expression_id": "0:0",
        "verdict": "repair",
        "score": 74,
        "issues": ["translation_omission"],
    }]}
    repaired_card = {"cloze": [{
        "expression_id": "0:0",
        "canonical_form": "carefully review",
        "surface_answer": "carefully reviewed",
        "question_ko": "빈칸을 완성하세요.",
        "sentence_ko": "회의 전에 핵심 지표를 꼼꼼히 검토했습니다.",
        "target_ko": "꼼꼼히 검토했습니다",
        "sentence_target": "I carefully reviewed the key metrics before the meeting.",
    }]}
    repaired_review = {"reviews": [{
        "expression_id": "0:0",
        "verdict": "pass",
        "score": 96,
        "issues": [],
    }]}
    completions = _Completions([
        plan, plan, first_card, review, repaired_card, repaired_review
    ])
    monkeypatch.setattr(
        quiz_bundle,
        "_client",
        lambda: SimpleNamespace(chat=SimpleNamespace(completions=completions)),
    )

    async def no_audio(*args, **kwargs):
        return None, None, None

    monkeypatch.setattr(quiz_bundle, "synthesize_quiz_audio_assets", no_audio)
    created, trace = await quiz_bundle.generate_quiz_bundle(
        db_session,
        iso_user,
        language="english",
        seed_node_ids={str(node.id)},
    )

    cloze = next(quiz for quiz in created if quiz.quiz_type == "cloze")
    assert cloze.quiz_data["sentence_ko"] == "회의 전에 핵심 지표를 꼼꼼히 검토했습니다."
    review_step = next(
        step for step in trace["steps"]
        if step["name"] == "bundle_cloze_batch_quality_review"
    )
    assert review_step["output"]["repair_count"] == 1
    assert len(completions.calls) == 6
    assert review_step["output"]["fail_closed"] is True
    assert review_step["output"]["release_score"] == 92


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


def test_expression_selection_keeps_quality_and_removes_nested_duplicates() -> None:
    selected = quiz_bundle._select_quality_expression_chunks([
        {
            "canonical_form": "acquire control",
            "quality_score": 78,
            "kind": "verb_phrase",
            "segment_index": 0,
        },
        {
            "canonical_form": "acquire management control",
            "quality_score": 94,
            "kind": "verb_phrase",
            "segment_index": 0,
        },
        {
            "canonical_form": "restructure governance",
            "quality_score": 91,
            "kind": "verb_phrase",
            "segment_index": 0,
        },
        {
            "canonical_form": "the company",
            "quality_score": 42,
            "kind": "domain_term",
            "segment_index": 0,
        },
    ])

    assert [item["canonical_form"] for item in selected] == [
        "acquire management control",
        "restructure governance",
    ]


def test_expression_selection_rejects_inflected_or_multi_action_canonical_forms() -> None:
    selected = quiz_bundle._select_quality_expression_chunks([
        {"canonical_form": "walked in the park", "quality_score": 95, "kind": "verb_phrase"},
        {"canonical_form": "dry shoes while checking", "quality_score": 95, "kind": "verb_phrase"},
        {"canonical_form": "take a walk", "quality_score": 90, "kind": "verb_phrase"},
    ], language="english")

    assert [item["canonical_form"] for item in selected] == ["take a walk"]


def test_safe_reference_fallback_requires_exact_source_alignment() -> None:
    fallback = quiz_bundle._safe_reference_fallback({
        "expression_id": "0:0",
        "canonical_form": "go for a walk",
        "surface_form": "went for a walk",
        "source_segment": "비가 왔지만 산책을 갔다.",
        "reference_answers": [{"text": "Although it rained, I went for a walk."}],
        "meaning_parts": [{"target": "went for a walk", "native": "산책을 갔다"}],
    }, target_language="english")

    assert fallback is not None
    assert fallback["target_ko"] == "산책을 갔다"


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


def test_incomplete_composition_rewrite_falls_back_to_exact_source_span() -> None:
    source = "집에 돌아온 뒤 젖은 신발을 말리면서 다음 주 여행 일정을 다시 확인했다."
    segment = {
        "source_text": source,
        "prompt_native": "집에 돌아온 뒤 젖은 신발을 말렸다.",
    }

    assert quiz_bundle._native_ngram_coverage(source, segment["prompt_native"]) < 0.72
    assert quiz_bundle._composition_prompt_for_segment(segment) == source


@pytest.mark.asyncio
async def test_long_statement_uses_semantic_composition_units(
    db_session, iso_user, monkeypatch
) -> None:
    source = (
        "비가 많이 왔지만 예정대로 산책을 했고, 돌아온 뒤 젖은 신발을 말리면서 "
        "다음 주 여행 계획을 다시 확인했다."
    )
    node = Node(
        user_id=iso_user.id,
        name="rainy-day-plan",
        type="Statement",
        description=json.dumps({"content": source}),
    )
    db_session.add(node)
    await db_session.commit()
    plan = {"segments": [
        {
            "segment_index": 0,
            "source_text": "비가 많이 왔지만 예정대로 산책을 했고",
            "prompt_native": "비가 많이 왔지만 예정대로 산책했다.",
            "grammar_focus": ["although"],
            "context_entities": [],
            "reference_answers": [{
                "text": "Although it rained heavily, I went for my planned walk.",
                "register": "neutral",
                "note": "대조 관계를 자연스럽게 연결합니다.",
            }],
            "expressions": [],
        },
        {
            "segment_index": 1,
            "source_text": "돌아온 뒤 젖은 신발을 말리면서 다음 주 여행 계획을 다시 확인했다.",
            "prompt_native": "돌아온 뒤 젖은 신발을 말리면서 다음 주 여행 계획을 다시 확인했다.",
            "grammar_focus": ["while + gerund"],
            "context_entities": [],
            "reference_answers": [{
                "text": "After returning, I reviewed next week's travel plans while drying my wet shoes.",
                "register": "neutral",
                "note": "동시 동작을 while로 연결합니다.",
            }],
            "expressions": [],
        },
    ]}
    completions = _Completions([plan, plan, plan])
    monkeypatch.setattr(
        quiz_bundle,
        "_client",
        lambda: SimpleNamespace(chat=SimpleNamespace(completions=completions)),
    )

    created, _ = await quiz_bundle.generate_quiz_bundle(
        db_session,
        iso_user,
        language="english",
        seed_node_ids={str(node.id)},
        materialize_cloze=False,
    )

    assert [quiz.question_native for quiz in created] == [
        "비가 많이 왔지만 예정대로 산책했다.",
        "돌아온 뒤 젖은 신발을 말리면서 다음 주 여행 계획을 다시 확인했다.",
    ]


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


def test_overlapping_reviewed_source_is_cut_at_next_unit() -> None:
    second = "집에 돌아온 뒤 젖은 신발을 말렸다."
    segments = [
        {"source_text": f"비가 왔지만 산책했고, {second}"},
        {"source_text": second},
    ]

    quiz_bundle._trim_overlapping_segment_sources(segments)

    assert segments[0]["source_text"] == "비가 왔지만 산책했고,"
    assert segments[1]["source_text"] == second


def test_native_expression_meaning_rebuilds_target_language_definition() -> None:
    chunk = {
        "meaning": "to dry shoes and remove moisture",
        "meaning_parts": [
            {"target": "dry shoes", "native": "신발을 말리다"},
        ],
    }

    assert quiz_bundle._native_expression_meaning(chunk, "korean") == "신발을 말리다"


def test_duplicate_inventory_segment_rows_merge_without_candidate_loss() -> None:
    rows = [
        {"segment_index": 1, "expressions": [{"canonical_form": "reproduce a lost update"}]},
        {"segment_index": 1, "expressions": [{"canonical_form": "modify the same balance"}]},
    ]

    merged = quiz_bundle._inventory_expressions_by_index(rows)

    assert [item["canonical_form"] for item in merged[1]] == [
        "reproduce a lost update",
        "modify the same balance",
    ]


def test_subject_predicate_clause_is_not_selected_as_an_expression() -> None:
    chunks = [{
        "canonical_form": "concurrent requests modify balance",
        "kind": "collocation",
        "quality_score": 95,
        "meaning_parts": [
            {"target": "concurrent requests", "native": "동시 요청이"},
            {"target": "modify balance", "native": "잔액을 수정하다"},
        ],
    }]

    assert quiz_bundle._select_quality_expression_chunks(chunks, language="english") == []


def test_semantically_required_six_word_verb_phrase_is_kept() -> None:
    chunks = [{
        "canonical_form": "refine the conclusion of presentation materials",
        "kind": "verb_phrase",
        "quality_score": 90,
    }]

    assert quiz_bundle._select_quality_expression_chunks(
        chunks, language="english"
    ) == chunks


def test_reviewer_cannot_merge_a_long_two_unit_plan_back_into_one() -> None:
    long_source = (
        "기차가 한 시간 지연되어 예약을 오후로 옮겼지만, 남는 시간에는 "
        "카페에서 발표 자료의 결론 부분을 꼼꼼하게 다듬었다."
    )

    assert quiz_bundle._review_collapses_long_plan(long_source, 2, 1) is True
    assert quiz_bundle._review_collapses_long_plan("예약을 옮겼다.", 2, 1) is False


def test_long_comma_sentence_supplies_two_stable_preliminary_units() -> None:
    source = (
        "기차가 한 시간 지연되어 박물관 예약을 오후로 옮겼지만, "
        "남는 시간에는 카페에서 발표 자료의 결론 부분을 다듬었다."
    )

    assert quiz_bundle._split_statement_units(source) == [
        "기차가 한 시간 지연되어 박물관 예약을 오후로 옮겼지만",
        "남는 시간에는 카페에서 발표 자료의 결론 부분을 다듬었다.",
    ]


def test_subordinate_and_dangling_composition_fragments_are_rejected() -> None:
    fragments = [{
        "prompt_native": "기차가 지연되는 바람에.",
        "reference_answers": [{"text": "Due to the train delay,"}],
    }]
    complete = [{
        "prompt_native": "기차가 지연되어 예약을 옮겼다.",
        "reference_answers": [{"text": "I moved the reservation because the train was delayed."}],
    }]

    assert quiz_bundle._plan_has_incomplete_units(fragments) is True
    assert quiz_bundle._plan_has_incomplete_units(complete) is False


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
    first_card = {"cloze": [cloze["cloze"][0]]}
    second_card = {"cloze": [cloze["cloze"][1]]}
    review = {"reviews": [
        {"expression_id": "0:0", "verdict": "pass", "score": 92, "issues": []},
        {"expression_id": "1:0", "verdict": "pass", "score": 95, "issues": []},
    ]}
    completions = _Completions([plan, plan, first_card, second_card, review])
    monkeypatch.setattr(
        quiz_bundle,
        "_client",
        lambda: SimpleNamespace(chat=SimpleNamespace(completions=completions)),
    )

    async def no_audio(*args, **kwargs):
        return None, None, None

    monkeypatch.setattr(quiz_bundle, "synthesize_quiz_audio_assets", no_audio)
    created, _ = await quiz_bundle.generate_quiz_bundle(
        db_session, iso_user, language="english", seed_node_ids={str(node.id)}
    )

    assert [quiz.quiz_type for quiz in created] == [
        "composition", "composition", "cloze", "cloze"
    ]
    compositions = [quiz for quiz in created if quiz.quiz_type == "composition"]
    assert [quiz.question_native for quiz in compositions] == [
        "보고서를 확인했습니다.", "화면을 더 자세히 살펴봤습니다."
    ]
    closer = next(
        quiz for quiz in created
        if (quiz.quiz_data or {}).get("canonical_form") == "take a closer look at"
    )
    assert closer.quiz_data["surface_form"] == "took a closer look at"
    assert closer.quiz_data["meaning"] == "더 자세히 살펴봤습니다"
    assert len(completions.calls) == 5
