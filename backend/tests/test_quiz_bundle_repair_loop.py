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


def test_cloze_author_prompt_freezes_reviewed_bilingual_sentences() -> None:
    prompt = quiz_bundle._build_cloze_system_prompt(
        "Korean (한국어)", "English", 50, quiz_bundle.lang_guide("english"), "english"
    )
    assert "[PAIR ko-en ALIGNMENT]" in prompt
    assert "sentences are frozen and must not be rewritten" in prompt
    assert "Copy answer_en" in prompt
    assert "meaning_ko" in prompt


def test_release_prompt_rejects_conservative_rate_scope_mismatch() -> None:
    prompt = quiz_bundle._build_cloze_qa_system_prompt("Korean (한국어)", "English")
    assert "a conservative discount rate" in prompt
    assert "보수적으로" in prompt
    assert "보수적인 할인율" in prompt
    assert "semantic_scope_mismatch" in prompt
    assert "part_of_speech_mismatch" in prompt
    assert "score < 92" in prompt
    assert "part of the faithful short source sentence" in prompt


def test_author_prompt_uses_en_ko_concrete_language_fields() -> None:
    prompt = quiz_bundle._build_cloze_system_prompt(
        "English", "Korean (한국어)", 50, quiz_bundle.lang_guide("korean"), "korean", "english"
    )
    assert "[PAIR en-ko ALIGNMENT]" in prompt
    assert "Copy answer_ko" in prompt
    assert "meaning_en" in prompt
    assert "answer_native" not in prompt


def test_plan_schema_uses_concrete_native_gloss_field() -> None:
    profile = quiz_bundle.get_quiz_prompt_profile("english", "korean")
    response_format = quiz_bundle._plan_response_format(profile)
    expression_schema = response_format["json_schema"]["schema"]["properties"][
        "segments"
    ]["items"]["properties"]["expressions"]["items"]

    assert "meaning_en" in expression_schema["required"]
    assert "meaning_en" in expression_schema["properties"]
    assert "meaning" not in expression_schema["properties"]

    normalized = quiz_bundle._normalize_plan_language_fields({"segments": [{
        "expressions": [{"meaning_en": "to apply a conservative discount rate"}]
    }]}, profile)
    assert normalized["segments"][0]["expressions"][0]["meaning"] == (
        "to apply a conservative discount rate"
    )


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


def test_multiword_expression_cannot_repair_to_bare_verb() -> None:
    assert quiz_bundle._surface_answer_contract_reason(
        answer="moved",
        sentence_target="His colleague moved his appointment to the afternoon.",
        canonical_form="move an appointment to the afternoon",
        excluded_target_terms=[],
        language="english",
    ) == "answer_boundary: repaired answer collapsed a multiword expression to one token"


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
    plan = {"segments": [{
        "segment_index": 0,
        "source_text": source,
        "prompt_native": source,
        "grammar_focus": ["past tense"],
        "context_entities": [],
        "reference_answers": [{
            "text": "I carefully compared two reports.",
            "register": "neutral",
            "note": "과거의 비교 행동",
        }],
        "expressions": [{
            "canonical_form": "carefully compare",
            "surface_form": "carefully compared",
            "surface_segments": ["carefully compared"],
            "meaning": "꼼꼼히 비교하다",
            "meaning_parts": [{
                "target": "carefully compared",
                "native": "꼼꼼히 비교했다",
            }],
            "kind": "collocation",
            "quality_score": 96,
            "quality_reason": "재사용 가능한 동사 결합",
        }],
    }]}
    completions = _Completions([plan, plan])
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
    assert next(quiz for quiz in created if quiz.quiz_type == "cloze").quiz_data["_origin"] == "reviewed_plan"
    assert [item["expression"] for item in saved] == ["carefully compare"]
    assert saved[0]["release_reviewed"] is True
    assert saved[0]["review_contract_version"] == "pair-release-v1"
    assert len(completions.calls) == 2  # draft + one shared composition/cloze release review
    assert completions.calls[0]["response_format"]["type"] == "json_schema"
    assert completions.calls[0]["response_format"]["json_schema"]["strict"] is True
    assert completions.calls[1]["response_format"]["type"] == "json_schema"
    assert source in completions.calls[0]["messages"][1]["content"]
    assert "Return only the composition and cloze arrays" not in completions.calls[0]["messages"][0]["content"]


@pytest.mark.asyncio
async def test_draft_and_review_calls_both_receive_the_full_statement_as_context(
    db_session, iso_user, monkeypatch
) -> None:
    """Both the first-draft (author) and review calls only ever saw the one
    unit they were writing/checking — never the Statement it came from. That's
    exactly why a backstory clause split away from the event it explained
    (see test_scramble_contract.py's translation-note tests and the segment
    prompt's own backstory-clause rule) could be mistranslated into something
    that contradicts the rest of the statement: neither call had the
    information needed to notice. Passing the original statement alongside the
    unit lets both calls actually judge that, instead of only the review call
    getting a chance to catch what the draft call had no way to avoid."""
    source = "친구를 만났고, 그가 저녁을 사주었다."
    node = Node(
        user_id=iso_user.id,
        name="dinner",
        type="Statement",
        description=json.dumps({"content": source}),
    )
    db_session.add(node)
    await db_session.commit()
    plan = {"segments": [{
        "segment_index": 0,
        "source_text": source,
        "prompt_native": source,
        "grammar_focus": ["past tense"],
        "translation_notes": [],
        "context_entities": [],
        "reference_answers": [{
            "text": "I met a friend, and he bought me dinner.",
            "register": "neutral",
            "note": "",
            "scramble_units": ["I met a friend,", "and he bought me dinner."],
        }],
        "expressions": [],
    }]}
    completions = _Completions([plan, plan])
    monkeypatch.setattr(
        quiz_bundle,
        "_client",
        lambda: SimpleNamespace(chat=SimpleNamespace(completions=completions)),
    )
    monkeypatch.setattr(
        node_expression_store, "save_node_expressions", lambda *a, **k: None
    )

    async def no_audio(*args, **kwargs):
        return None, None, None

    monkeypatch.setattr(quiz_bundle, "synthesize_quiz_audio_assets", no_audio)

    await quiz_bundle.generate_quiz_bundle(
        db_session,
        iso_user,
        language="english",
        seed_node_ids={str(node.id)},
    )

    assert len(completions.calls) == 2  # draft, then review
    for call in completions.calls:
        payload = json.loads(call["messages"][1]["content"])
        assert payload["full_statement_context"] == source
        system_prompt = call["messages"][0]["content"]
        assert "full_statement_context" in system_prompt
        assert "backstory" in system_prompt


@pytest.mark.asyncio
async def test_reviewed_plan_does_not_pay_for_duplicate_cloze_review(
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
    completions = _Completions([plan, plan])
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
    assert cloze.quiz_data["_origin"] == "reviewed_plan"
    assert cloze.quiz_data["sentence_ko"] == source
    review_step = next(
        step for step in trace["steps"]
        if step["name"] == "bundle_cloze_batch_quality_review"
    )
    assert review_step["output"]["repair_count"] == 0
    assert review_step["output"]["reused_plan_review_count"] == 1
    assert review_step["output"]["review_count"] == 0
    assert len(completions.calls) == 2
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


def test_single_high_value_word_is_a_valid_expression_candidate() -> None:
    selected = quiz_bundle._select_quality_expression_chunks([{
        "canonical_form": "suddenly",
        "surface_form": "suddenly",
        "quality_score": 93,
        "kind": "word",
    }], language="english")

    assert [item["canonical_form"] for item in selected] == ["suddenly"]


def test_padded_weather_phrase_is_rejected_in_favor_of_a_standalone_adverb() -> None:
    selected = quiz_bundle._select_quality_expression_chunks([
        {"canonical_form": "suddenly rain", "quality_score": 98, "kind": "verb_phrase"},
        {"canonical_form": "suddenly", "quality_score": 93, "kind": "word"},
    ], language="english")

    assert [item["canonical_form"] for item in selected] == ["suddenly"]


def test_ko_en_prompt_prefers_a_word_over_a_padded_phrase() -> None:
    profile = quiz_bundle.get_quiz_prompt_profile("korean", "english")

    assert "never 'suddenly rain'" in profile.plan_rules
    assert "replace it with 'suddenly'" in profile.plan_review_rules


def test_korean_expression_selection_requires_a_dictionary_lemma() -> None:
    selected = quiz_bundle._select_quality_expression_chunks([
        {
            "canonical_form": "머리를 잘랐어요",
            "surface_form": "머리를 잘랐어요",
            "quality_score": 95,
            "kind": "verb_phrase",
        },
        {
            "canonical_form": "머리를 자르다",
            "surface_form": "머리를 잘랐어요",
            "quality_score": 94,
            "kind": "verb_phrase",
        },
    ], language="korean", native_language="english")

    assert [item["canonical_form"] for item in selected] == ["머리를 자르다"]


def test_reviewed_expression_becomes_primary_cloze_without_fallback() -> None:
    card = quiz_bundle._cloze_from_reviewed_expression({
        "expression_id": "0:0",
        "canonical_form": "go for a walk",
        "surface_form": "went for a walk",
        "source_segment": "비가 왔지만 산책을 갔다.",
        "reference_answers": [{"text": "Although it rained, I went for a walk."}],
        "meaning_parts": [{"target": "went for a walk", "native": "산책을 갔다"}],
    }, native_language="korean", target_language="english")

    assert card is not None
    assert card["surface_answer"] == "went for a walk"
    assert card["target_ko"] == "산책을 갔다"


def test_translation_choice_is_saved_for_post_answer_explanation() -> None:
    quiz_data = quiz_bundle._compose_quiz_data({
        "translation_notes": [{
            "source": "sister",
            "target": "언니",
            "note": "여기서는 언니로 옮겼지만, 문맥에 따라 누나나 여동생이 될 수도 있어요.",
        }],
    }, "korean", 10)

    assert quiz_data["hints"] == []
    assert quiz_data["translation_notes"] == [{
        "source": "sister",
        "target": "언니",
        "note": "여기서는 언니로 옮겼지만, 문맥에 따라 누나나 여동생이 될 수도 있어요.",
    }]


def test_contextual_surface_is_dropped_instead_of_replaced_by_canonical() -> None:
    card = quiz_bundle._cloze_from_reviewed_expression({
        "expression_id": "0:0",
        "canonical_form": "휴대폰 속",
        "surface_form": "내 휴대폰 속",
        "source_segment": "I organized the photos on my phone.",
        "reference_answers": [{"text": "오늘 저녁에 내 휴대폰 속 사진을 정리했다."}],
        "meaning_parts": [{"target": "내 휴대폰 속", "native": "on my phone"}],
    }, native_language="english", target_language="korean")

    assert card is None


def test_source_alignment_span_covers_inflected_english_verb_and_object() -> None:
    chunk = {
        "meaning_parts": [
            {"target": "할인율", "native": "discount rate"},
            {"target": "적용하다", "native": "apply"},
        ]
    }

    assert quiz_bundle._source_alignment_span(
        "He is applying a conservative discount rate to account for uncertainty.",
        chunk,
    ) == "is applying a conservative discount rate"


def test_source_alignment_span_rejects_partial_meaning_part_coverage() -> None:
    assert quiz_bundle._source_alignment_span(
        "그는 보수적인 할인율을 적용하고 있다.",
        {
            "meaning_parts": [
                {"target": "discount rate", "native": "보수적인 할인율"},
                {"target": "apply", "native": "적용하다"},
            ]
        },
    ) == ""


def test_reviewed_expression_uses_complete_native_gloss() -> None:
    card = quiz_bundle._cloze_from_reviewed_expression({
        "expression_id": "0:0",
        "canonical_form": "할인율 적용하다",
        "surface_form": "할인율을 적용하고 있다",
        "source_segment": "He is applying a conservative discount rate to account for uncertainty.",
        "meaning": "apply a conservative discount rate",
        "reference_answers": [{
            "text": "그는 불확실성을 고려하여 보수적인 할인율을 적용하고 있다."
        }],
        "meaning_parts": [
            {"target": "할인율", "native": "discount rate"},
            {"target": "적용하다", "native": "apply"},
        ],
    }, native_language="english", target_language="korean")

    assert card is not None
    assert card["target_ko"] == "apply a conservative discount rate"


def test_en_ko_uses_measured_hybrid_model_roles() -> None:
    settings = SimpleNamespace(
        openai_model="gpt-4o-mini",
        quiz_author_model="gpt-5.4-mini",
        quiz_quality_model="gpt-5.4-mini",
        quiz_author_model_en_ko="gpt-4o-mini",
        quiz_quality_model_en_ko="gpt-5.4-mini",
    )

    assert quiz_bundle._quiz_role_models(settings, "english", "korean") == (
        "gpt-4o-mini",
        "gpt-5.4-mini",
    )
    assert quiz_bundle._quiz_role_models(settings, "korean", "english") == (
        "gpt-5.4-mini",
        "gpt-5.4-mini",
    )


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
    assert "dedicated ko-de curriculum planner" in prompt
    assert "never apply rules or field roles from another direction" in prompt


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
    segmentation = {"segments": [
        {"source_text": plan["segments"][0]["source_text"]},
        {"source_text": plan["segments"][1]["source_text"]},
    ]}
    completions = _Completions([segmentation, plan, plan, plan, plan])
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


def test_english_canonical_rejects_an_inflected_verb_after_an_adverb() -> None:
    chunks = [{
        "canonical_form": "suddenly rained",
        "kind": "discourse_frame",
        "quality_score": 95,
    }]

    assert quiz_bundle._select_quality_expression_chunks(chunks, language="english") == []


def test_expression_selection_is_capped_per_study_unit() -> None:
    chunks = [
        {"canonical_form": "buy an umbrella", "kind": "verb_phrase", "quality_score": 95},
        {"canonical_form": "be a little wet", "kind": "verb_phrase", "quality_score": 94},
        {"canonical_form": "feel much better", "kind": "verb_phrase", "quality_score": 93},
    ]

    selected = quiz_bundle._select_quality_expression_chunks(
        chunks, language="english", limit=2
    )

    assert len(selected) == 2


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


def test_enko_rejects_subjectless_or_dangling_llm_source_units() -> None:
    assert quiz_bundle._study_source_unit_reason("Bought a loaf of sourdough.", "english")
    assert quiz_bundle._study_source_unit_reason("while I made soup for dinner.", "english")
    assert quiz_bundle._study_source_unit_reason(
        "I stopped by a small bakery on my way home.", "english"
    ) is None


def test_invalid_llm_segmentation_requires_retry_or_whole_statement() -> None:
    source = (
        "I stopped by a small bakery on my way home and bought a loaf of sourdough. "
        "The smell filled the kitchen while I made soup for dinner."
    )
    failures = quiz_bundle._validate_study_source_units(
        source,
        [
            "I stopped by a small bakery on my way home.",
            "bought a loaf of sourdough.",
            "The smell filled the kitchen.",
            "while I made soup for dinner.",
        ],
        "english",
    )

    assert any("subjectless predicate" in failure for failure in failures)
    assert any("dangling connective" in failure for failure in failures)


def test_coordinated_main_clauses_can_split_but_purpose_clause_stays_attached() -> None:
    source = (
        "Ha Seung-mok, a researcher, just spilled water on his table, "
        "and I gave him some tissues so that he can wipe it."
    )
    units = [
        "Ha Seung-mok, a researcher, just spilled water on his table,",
        "and I gave him some tissues so that he can wipe it.",
    ]

    assert quiz_bundle._validate_study_source_units(source, units, "english") == []
    prompt = quiz_bundle._build_segment_system_prompt(
        "English",
        "Korean",
        native_language="english",
        target_language="korean",
    )
    assert "so that" in prompt
    assert "keep purpose clauses" in prompt


def test_learning_unit_prompts_never_ask_to_shorten_the_reference() -> None:
    """A card that documents a clause it then drops (see test_scramble_contract.py's
    ``test_a_documented_clause_missing_from_the_reference_is_a_release_failure``)
    traced back to this prompt telling the model to "simplify wording" past a word
    budget. The fix removes the budget entirely: length is handled by how the
    scramble game groups words into pieces (``scramble_units``), never by
    shortening the sentence itself."""
    segment_prompt = quiz_bundle._build_segment_system_prompt(
        "English",
        "Korean",
        native_language="english",
        target_language="korean",
    )
    plan_prompt = quiz_bundle._build_plan_system_prompt(
        "English",
        "Korean",
        35,
        "plain learner sentence",
        "korean",
        "english",
    )
    review_prompt = quiz_bundle._build_plan_qa_system_prompt(
        "English",
        "Korean",
        35,
        "korean",
        "english",
    )

    assert "original Statement stays intact in the graph" in segment_prompt
    assert "sentence scramble and writing cards" in segment_prompt
    assert "short standalone learning prompt" in plan_prompt
    assert "short learner-facing quiz sentences" in review_prompt

    for prompt in (segment_prompt, plan_prompt, review_prompt):
        assert "simplify" not in prompt.lower()
        assert "shorten" not in prompt.lower() or "never" in prompt.lower()

    assert "scramble_units" in plan_prompt
    assert "scramble_units" in review_prompt
    assert "length is never a reason" in plan_prompt.lower()
    assert "never a reason to shorten" in review_prompt.lower()
    assert str(quiz_bundle._SCRAMBLE_MAX_CHUNKS) in plan_prompt


def test_scramble_rejects_multi_sentence_target() -> None:
    payload, reason = quiz_bundle._scramble_payload(
        "종로에서 친구를 만나고 저녁을 얻어먹었어요. 오랫동안 못 만났어요.",
        seed="multi-sentence",
    )

    assert payload is None
    assert reason == "multiple_target_sentences"


def test_sentence_fallback_never_keeps_two_explicit_sentences_together() -> None:
    units = quiz_bundle._deterministic_sentence_units(
        "I bought tea. I drank it at home."
    )
    assert units == ["I bought tea.", "I drank it at home."]
    assert quiz_bundle._study_source_unit_reason(
        "I bought tea. I drank it at home.", "english"
    ) == "source unit contains multiple sentences"


def test_expression_candidates_reject_dangling_connectors_and_whole_sentence_spans() -> None:
    chunks = [
        {
            "canonical_form": "met a friend in Jongro and",
            "surface_form": "met a friend in Jongro and",
            "kind": "verb_phrase",
            "quality_score": 99,
            "reference_answers": [{"text": "I met a friend in Jongro and had dinner."}],
        },
        {
            "canonical_form": "haven't met for a long time",
            "surface_form": "haven't met for a long time",
            "kind": "verb_phrase",
            "quality_score": 95,
            "reference_answers": [{"text": "We haven't met for a long time."}],
        },
        {
            "canonical_form": "long time",
            "surface_form": "long time",
            "kind": "collocation",
            "quality_score": 90,
            "reference_answers": [{"text": "We haven't met for a long time."}],
        },
    ]

    selected = quiz_bundle._select_quality_expression_chunks(
        chunks, language="english", limit=3, native_language="english"
    )

    assert [chunk["canonical_form"] for chunk in selected] == ["long time"]


def test_korean_surface_rejects_contextual_possessive() -> None:
    pack = quiz_bundle.target_pack("korean")

    assert pack.surface_boundary_reason(
        answer="\ub0b4 \ud578\ub4dc\ud3f0 \uc18d",
        sentence_target="\uc624\ub298 \uc800\ub141\uc5d0 \ub0b4 \ud578\ub4dc\ud3f0 \uc18d \uc0ac\uc9c4\uc744 \uc815\ub9ac\ud588\ub2e4.",
        canonical_form="\ud734\ub300\ud3f0 \uc18d",
    )


def test_expression_candidates_reject_context_possessive_added_to_surface() -> None:
    selected = quiz_bundle._select_quality_expression_chunks(
        [{
            "canonical_form": "improve mood",
            "surface_form": "improved my mood",
            "kind": "collocation",
            "quality_score": 99,
            "reference_answers": [{"text": "Drinking tea improved my mood."}],
        }],
        language="english",
        native_language="korean",
    )
    assert selected == []


def test_german_contract_rejects_missing_reciprocal_reflexive() -> None:
    reason = quiz_bundle._plan_domain_contract_reason(
        "오래 못 만나서 이야기를 많이 나눴다.",
        [{"reference_answers": [{"text": "Wir haben lange nicht getroffen und viel geredet."}]}],
        native_language="korean",
        target_language="german",
    )
    assert reason and reason.startswith("german_reciprocal_missing")


def test_domain_contract_requires_established_lost_update_terms() -> None:
    generic_german = [{
        "reference_answers": [{
            "text": "Bei der Aktualisierung des Kontostands kann es zu Verlusten kommen."
        }]
    }]
    correct_german = [{
        "reference_answers": [{
            "text": "Bei gleichzeitigen Anfragen kann ein Lost Update auftreten."
        }],
        "expressions": [{
            "canonical_form": "ein Lost Update",
            "surface_form": "ein Lost Update",
        }],
    }]

    assert quiz_bundle._plan_domain_contract_reason(
        "잔액에 갱신 손실이 발생할 수 있다.",
        generic_german,
        native_language="korean",
        target_language="german",
    ) is not None
    assert quiz_bundle._plan_domain_contract_reason(
        "잔액에 갱신 손실이 발생할 수 있다.",
        correct_german,
        native_language="korean",
        target_language="german",
    ) is None
    assert quiz_bundle._plan_domain_contract_reason(
        "잔액에 갱신 손실이 발생할 수 있다.",
        [{"reference_answers": [{
            "text": "Gleichzeitige Anfragen können einen Aktualisierungsverlust verursachen."
        }], "expressions": [{
            "canonical_form": "ein Aktualisierungsverlust",
            "surface_form": "einen Aktualisierungsverlust",
        }]}],
        native_language="korean",
        target_language="german",
    ) is None
    assert quiz_bundle._plan_domain_contract_reason(
        "잔액에 갱신 손실이 발생할 수 있다.",
        [{"reference_answers": [{"text": "A lost update may occur to the balance."}]}],
        native_language="korean",
        target_language="english",
    ) is not None


def test_domain_contract_requires_term_in_expression_candidate() -> None:
    references_only = [{
        "reference_answers": [{
            "text": "When requests overlap, they can cause a lost update."
        }],
        "expressions": [{
            "canonical_form": "overlapping requests",
            "surface_form": "requests overlap",
        }],
    }]
    includes_term = [{
        **references_only[0],
        "expressions": [{
            "canonical_form": "a lost update",
            "surface_form": "a lost update",
        }],
    }]

    assert quiz_bundle._plan_domain_contract_reason(
        "동시에 여러 요청이 들어오면 잔액에 갱신 손실이 발생할 수 있다.",
        references_only,
        native_language="korean",
        target_language="english",
    ) is not None
    assert quiz_bundle._plan_domain_contract_reason(
        "동시에 여러 요청이 들어오면 잔액에 갱신 손실이 발생할 수 있다.",
        includes_term,
        native_language="korean",
        target_language="english",
    ) is None


def test_enko_domain_contract_requires_korean_term_in_expression() -> None:
    references_only = [{
        "reference_answers": [{"text": "동시 요청은 갱신 손실을 일으킬 수 있다."}],
        "expressions": [{
            "canonical_form": "동시에 요청하다",
            "surface_form": "동시 요청은",
        }],
    }]

    assert quiz_bundle._plan_domain_contract_reason(
        "Concurrent requests can cause a lost update.",
        references_only,
        native_language="english",
        target_language="korean",
    ) is not None


def test_near_duplicate_segment_does_not_create_second_composition() -> None:
    segments = [
        {
            "source_text": "동시에 여러 요청이 들어오면 잔액에 갱신 손실이 발생할 수 있다.",
            "prompt_native": "동시에 여러 요청이 들어오면 잔액에 갱신 손실이 발생할 수 있다.",
        },
        {
            "source_text": "여러 요청이 들어오면 잔액에 갱신 손실이 발생할 수 있다.",
            "prompt_native": "여러 요청이 들어오면 잔액에 갱신 손실이 발생할 수 있다.",
        },
    ]

    quiz_bundle._trim_overlapping_segment_sources(segments)

    assert len(segments) == 1


def test_pair_plan_rejects_dangling_english_prompt_and_hangul_in_german() -> None:
    dangling = [{
        "prompt_native": "so I moved my reservation to the afternoon.",
        "reference_answers": [{"text": "그래서 예약을 오후로 옮겼다."}],
    }]
    german_leak = [{
        "prompt_native": "담당자에게 계약 해지를 물어봤다.",
        "reference_answers": [{"text": "Ich habe den 담당자 nach der Kündigung gefragt."}],
    }]

    assert quiz_bundle._plan_has_incomplete_units(
        dangling, native_language="english", target_language="korean"
    ) is True
    assert quiz_bundle._plan_has_incomplete_units(
        german_leak, native_language="korean", target_language="german"
    ) is True


def test_pair_plan_rejects_noncontiguous_or_possessive_german_surface() -> None:
    broken = [{
        "prompt_native": "그는 보수적인 할인율을 적용한다.",
        "reference_answers": [{"text": "Er wendet einen konservativen Diskontsatz an."}],
        "expressions": [{"surface_form": "einen konservativen Diskontsatz anwendet"}],
    }]
    possessive = [{
        "prompt_native": "그는 남는 시간에 자료를 다듬었다.",
        "reference_answers": [{"text": "Er hat in seiner freien Zeit die Unterlagen überarbeitet."}],
        "expressions": [{"surface_form": "in seiner freien Zeit"}],
    }]

    assert quiz_bundle._plan_has_incomplete_units(
        broken, native_language="korean", target_language="german"
    ) is True
    assert quiz_bundle._plan_has_incomplete_units(
        possessive, native_language="korean", target_language="german"
    ) is True


def test_german_frozen_expression_normalizes_only_reviewed_exact_spans() -> None:
    possessive = quiz_bundle._normalize_german_frozen_expression(
        {
            "canonical_form": "Präsentation überarbeiten",
            "surface_form": "seine Präsentation überarbeitet",
            "kind": "verb_phrase",
        },
        "Er hat seine Präsentation überarbeitet.",
    )
    separable = quiz_bundle._normalize_german_frozen_expression(
        {
            "canonical_form": "einen konservativen Diskontsatz anwenden",
            "surface_form": "einen konservativen Diskontsatz anwendet",
            "kind": "verb_phrase",
            "meaning": "보수적인 할인율을 적용하다",
            "meaning_parts": [
                {"target": "einen konservativen Diskontsatz", "native": "보수적인 할인율"},
                {"target": "anwenden", "native": "적용하다"},
            ],
        },
        "Er wendet einen konservativen Diskontsatz an.",
    )

    assert possessive["surface_form"] == "Präsentation überarbeitet"
    assert possessive["canonical_form"] == "Präsentation überarbeiten"
    assert separable["surface_form"] == "einen konservativen Diskontsatz"
    assert separable["meaning"] == "보수적인 할인율"
    assert separable["kind"] == "domain_term"


def test_german_separable_action_cannot_keep_only_the_stranded_prefix() -> None:
    from app.language_packs import target_pack

    reason = target_pack("german").surface_boundary_reason(
        answer="einen konservativen Diskontsatz an",
        sentence_target="Er wendet einen konservativen Diskontsatz an.",
        canonical_form="einen konservativen Diskontsatz anwenden",
    )

    assert reason is not None
    assert "de_separable_split" in reason


def test_german_surface_answer_cannot_end_with_coordinator() -> None:
    from app.language_packs import target_pack

    reason = target_pack("german").surface_boundary_reason(
        answer="zahlt und",
        sentence_target="Die Gesellschaft zahlt und kauft die Aktien zurück.",
        canonical_form="zahlen",
    )

    assert reason is not None
    assert "sibling_join" in reason


def test_german_subject_predicate_clause_is_not_teachable() -> None:
    from app.language_packs import target_pack

    reason = target_pack("german").teachability_reason(
        "Eine Put-Option gibt einem Investor das Recht"
    )

    assert reason is not None
    assert "not_teachable" in reason


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
    review = {"reviews": [
        {"expression_id": "0:0", "verdict": "pass", "score": 92, "issues": []},
        {"expression_id": "1:0", "verdict": "pass", "score": 95, "issues": []},
    ]}
    repaired = {"alignments": [{
        "expression_id": "0:0",
        "canonical_form": "review a report",
        "answer_en": "reviewed",
        "meaning_ko": "검토했다",
    }]}
    repaired_review = {"reviews": [{
        "expression_id": "0:0", "verdict": "pass", "score": 94, "issues": [],
    }]}
    completions = _Completions([plan, plan, repaired, repaired_review])
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
        "composition", "composition", "cloze"
    ]
    compositions = [quiz for quiz in created if quiz.quiz_type == "composition"]
    assert [quiz.question_native for quiz in compositions] == [
        "보고서를 확인했습니다.", "화면을 더 자세히 살펴봤습니다."
    ]
    clozes = [quiz for quiz in created if quiz.quiz_type == "cloze"]
    assert {quiz.quiz_data["surface_form"] for quiz in clozes} == {
        "took a closer look at"
    }
    assert len(completions.calls) == 3
