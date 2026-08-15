import pytest

from app.quiz_bundle import _is_teachable_cloze, _normalize_bundle_cloze
from app.quiz_generator import validate_quiz_payload


def test_normalizes_legacy_underscore_run_and_requires_a_korean_meaning() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_target": "I carried out a task to ______ the findings.",
            "blank": "validate",
            "sentence_ko": "결과를 검증하는 작업을 수행했습니다.",
            "target_ko": "검증",
        },
        language="english",
    )

    assert result == (
        "I carried out a task to validate the findings.",
        "I carried out a task to ___ the findings.",
        "validate",
        "결과를 <span color='#FFA500'>검증</span>하는 작업을 수행했습니다.",
    )


def test_rejects_bilingual_sentence_when_target_is_korean() -> None:
    assert _normalize_bundle_cloze(
        {
            "sentence_target": "He applies a discount rate to 불확실성을 반영하기 위해.",
            "surface_answer": "불확실성을 반영하기 위해",
            "sentence_ko": "He applies a discount rate to account for uncertainty.",
            "target_ko": "to account for uncertainty",
        },
        language="korean",
        native_language="english",
    ) is None

def test_normalizes_two_character_model_placeholder() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "Ich habe die Berichte __.",
            "blank": "sorgfältig verglichen",
            "sentence_ko": "\ubcf4\uace0\uc11c\ub97c \uaf3c\uaf3c\ud788 \ube44\uad50\ud588\ub2e4.",
            "target_ko": "\uaf3c\uaf3c\ud788 \ube44\uad50\ud588\ub2e4",
        },
        language="german",
    )

    assert result is not None
    assert result[0] == "Ich habe die Berichte sorgfältig verglichen."
    assert result[1] == "Ich habe die Berichte ___."


def test_rejects_target_language_text_in_korean_alignment_field() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "Ich habe die Berichte sorgfältig verglichen.",
            "blank": "sorgfältig verglichen",
            "sentence_ko": "\ubcf4\uace0\uc11c\ub97c ______\ud588\ub2e4.",
            "target_ko": "sorgfältig vergleichen",
        },
        language="german",
    )

    assert result is None


def test_rejects_native_sentence_with_target_language_answer() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_target": "평가 매뉴얼을 ______하고 있습니다.",
            "blank": "understand",
            "sentence_ko": "평가 매뉴얼을 이해하고 있습니다.",
            "target_ko": "이해",
        },
        language="english",
    )

    assert result is None


def test_rejects_generic_korean_context_without_a_real_meaning() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "Please check out the revised report.",
            "prompt_en": "Please ___ the revised report.",
            "blank": "check out",
            "sentence_ko": "이것은 일반적인 표현입니다.",
            "target_ko": "표현",
        },
        language="english",
    )

    assert result is None


def test_missing_target_alignment_is_rejected_instead_of_highlighting_everything() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "You can inspect the screen on the webpage.",
            "blank": "on the webpage",
            "sentence_ko": "웹페이지에서 화면을 확인할 수 있습니다.",
            "target_ko": "",
        },
        language="english",
    )

    assert result is None


def test_normalized_cloze_passes_the_production_validator() -> None:
    sentence_en, prompt_en, blank, context_ko = _normalize_bundle_cloze(
        {
            "sentence_en": "I need to compare the results before submitting the report.",
            "prompt_en": "I need to ___ the results before submitting the report.",
            "blank": "compare",
            "sentence_ko": "보고서를 제출하기 전에 결과를 비교해야 합니다.",
            "target_ko": "비교",
        },
        language="english",
    )

    validated = validate_quiz_payload(
        "cloze",
        {
            "question_ko": "빈칸에 들어갈 표현을 입력해 보세요.",
            "sentence_en": sentence_en,
            "quiz_data": {
                "prompt_en": prompt_en,
                "blank": blank,
                "accepted_answers": [blank],
                "context_ko": context_ko,
            },
        },
        target_level=20,
        target_language="english",
    )

    assert validated["quiz_data"]["sentence_en_complete"] == sentence_en


def test_rebuilds_a_safe_prompt_from_the_complete_sentence() -> None:
    sentence_en, prompt_en, _, _ = _normalize_bundle_cloze(
        {
            "sentence_en": "The platform has eight drivers.",
            "prompt_en": "The platform has ___ eight drivers.",
            "blank": "eight",
            "sentence_ko": "해당 플랫폼에는 8개의 드라이버가 있다.",
            "target_ko": "8개",
        },
        language="english",
    )

    assert sentence_en == "The platform has eight drivers."
    assert prompt_en == "The platform has ___ drivers."


def test_restores_one_native_placeholder_from_explicit_target_translation() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "I carefully compared the two reports.",
            "blank": "carefully compared",
            "sentence_ko": "\ub450 \ubcf4\uace0\uc11c\ub97c ______\ud588\ub2e4.",
            "target_ko": "\uaf3c\uaf3c\ud788 \ube44\uad50",
        },
        language="english",
    )

    assert result is not None
    assert result[3] == (
        "\ub450 \ubcf4\uace0\uc11c\ub97c "
        "<span color='#FFA500'>\uaf3c\uaf3c\ud788 \ube44\uad50</span>\ud588\ub2e4."
    )


def test_rejects_a_completed_sentence_that_contains_the_answer_twice() -> None:
    result = _normalize_bundle_cloze(
        {
            "sentence_en": "The platform has ____ eight drivers.",
            "blank": "eight",
            "sentence_ko": "해당 플랫폼에는 8개의 드라이버가 있다.",
            "target_ko": "8개",
        },
        language="english",
    )

    assert result is None


def test_rejects_a_card_whose_native_fields_repeat_the_target_sentence() -> None:
    # Observed in an eval run: the author copied the English sentence into both
    # sentence_ko and target_ko, so every alignment check agreed with itself and
    # the card shipped with its "문장 뜻" written in English.
    sentence = (
        "A put option gives investors the right to ask the company to buy back "
        "their stocks or bonds when the stock price falls."
    )
    result = _normalize_bundle_cloze(
        {
            "sentence_en": sentence,
            "blank": "buy back",
            "sentence_ko": sentence,
            "target_ko": "buy back",
        },
        language="english",
    )

    assert result is None


def test_rejects_numbers_function_words_and_word_fragments_as_clozes() -> None:
    assert not _is_teachable_cloze("eight", language="english")
    assert not _is_teachable_cloze("has", language="english")
    assert not _is_teachable_cloze("sub", language="english")
    assert not _is_teachable_cloze("the two reports", language="english")
    assert not _is_teachable_cloze("their key results", language="english")
    assert _is_teachable_cloze("key results", language="english")
    assert _is_teachable_cloze("check out", language="english")


def test_german_possessive_gate_respects_the_sein_homograph() -> None:
    from app.language_packs import target_pack

    de = target_pack("german")

    def flagged(text: str) -> bool:
        reason = de.teachability_reason(text)
        return reason is not None and "internal_possessive" in reason

    # "sein" is also the infinitive "to be" and "ihr" the pronoun "you/her",
    # so a bare stem list would reject real expressions. German capitalizes
    # nouns, which is what separates the two readings.
    assert not flagged("überrascht sein")
    assert not flagged("sich um eine Stunde verspäten")
    assert not flagged("den Vertrag kündigen")
    # A possessive before a noun is the same deixis problem English has.
    assert flagged("in ihrer Freizeit")
    assert flagged("in seiner freien Zeit")
    assert flagged("den Rückkauf der eigenen Aktien oder Anleihen")
    assert flagged("auf seinen Vorschlag eingehen")
    # Position 0 too: German's leading-determiner rule only covers answers of
    # two words or fewer and lists articles only, so this is caught here.
    assert flagged("ihre Unterlagen überarbeiten")
    assert flagged("euer Angebot annehmen")


def test_korean_verb_phrases_are_not_mistaken_for_whole_clauses() -> None:
    # Korean is verb-final, so nearly every Korean verb phrase ends in a
    # 다-form. The clause-answer rule used to reject any 3+ 어절 answer ending
    # that way, which contradicted this same pack's base_form_reason (it
    # REQUIRES canonical forms to be the 하다-lemma, i.e. to end in 다) and
    # cost en-ko most of its cards.
    from app.language_packs import target_pack

    ko = target_pack("korean")

    def rejected(text: str) -> bool:
        return ko.teachability_reason(text) is not None

    assert not rejected("회의를 정리했다")
    assert not rejected("발표 자료를 검토했다")
    assert not rejected("보수적인 할인율을 적용하다")
    assert not rejected("예약을 오후로 옮겼다")
    assert not rejected("지출 내역을 매주 정리했다")
    # A real clause still goes, caught by its subject-marked eojeol.
    assert rejected("나는 발표 자료를 검토했다")
    assert rejected("그는 할인율을 적용하고 있다")
    # A finished polite sentence is still a clause even with no subject.
    assert rejected("오늘 회의를 모두 마쳤습니다")


def test_repair_feedback_uses_the_actual_target_language_pack() -> None:
    # The caller passed native_language but never language, so `language`
    # defaulted to "english" for every pair. A Korean sentence tokenized by
    # the English pack yields zero tokens, and the author was told
    # "sentence has 0 tokens, need 3" about a perfectly good Korean sentence.
    from app.quiz_bundle import _cloze_structural_reason

    item = {
        "surface_answer": "발표를 검토했다",
        "sentence_target": "회의 전에 발표를 검토했다.",
        "sentence_ko": "I reviewed the presentation before the meeting.",
        "target_ko": "reviewed the presentation",
    }
    korean = _cloze_structural_reason(item, 0, "english", "korean")
    assert "0 tokens" not in korean

    # German answers must not be measured with English word boundaries either.
    german = _cloze_structural_reason(
        {
            "surface_answer": "die Unterlagen überarbeitet",
            "sentence_target": "Ich habe im Café die Unterlagen überarbeitet.",
            "sentence_ko": "카페에서 자료를 다듬었다.",
            "target_ko": "자료를 다듬었다",
        },
        0,
        "korean",
        "german",
    )
    assert "0 tokens" not in german


def test_korean_gloss_must_reach_the_predicate_for_a_verb_phrase() -> None:
    # "예약을" cannot be the meaning of "die Reservierung ... verschoben": the
    # gloss stops where the Korean verb should start. The planner's `kind` is
    # what keeps this safe for noun-phrase answers.
    from app.language_packs import native_quiz_pack

    ko = native_quiz_pack("korean")

    assert ko.gloss_scope_reason("예약을", "verb_phrase") is not None
    assert ko.gloss_scope_reason("계약을", "verb_phrase") is not None
    assert ko.gloss_scope_reason("보수적인 할인율", "verb_phrase") is not None
    assert ko.gloss_scope_reason("젖은 신발을 말리", "verb_phrase") is not None
    assert ko.gloss_scope_reason("보수적인 할인율을 적용하고", "verb_phrase") is not None
    assert ko.gloss_scope_reason("예약을 오후로 옮겼다", "verb_phrase") is None
    assert ko.gloss_scope_reason("보험금을 지급한다", "verb_phrase") is None
    # A noun-phrase answer is legitimately glossed with an object-marked span.
    assert ko.gloss_scope_reason("두 보고서를", "domain_term") is None
    assert ko.gloss_scope_reason("두 보고서를", "collocation") is None


def test_cloze_origin_survives_candidate_normalization() -> None:
    from app.quiz_bundle import _prepare_cloze_candidates

    candidates, reasons = _prepare_cloze_candidates(
        [{
            "_origin": "reviewed_plan",
            "expression_id": "0:0",
            "canonical_form": "review a report",
            "surface_answer": "reviewed the report",
            "sentence_target": "I carefully reviewed the report before lunch.",
            "sentence_ko": "점심 전에 보고서를 꼼꼼히 검토했다.",
            "target_ko": "보고서를 꼼꼼히 검토했다",
        }],
        language="english",
        level=50,
        source_meta={"node_id": "node-1"},
        expression_contracts={
            "0:0": {"canonical_form": "review a report", "kind": "verb_phrase"}
        },
        native_language="korean",
    )

    assert reasons == []
    assert candidates[0]["spec"]["quiz_data"]["_origin"] == "reviewed_plan"


def test_blank_may_not_swallow_the_whole_sentence() -> None:
    # "Ich habe ___." is a translation exercise, not a cloze: the stem carries
    # no information the learner can use to choose the answer.
    assert _normalize_bundle_cloze(
        {
            "sentence_en": "Ich habe die Präsentationsunterlagen genau geprüft.",
            "blank": "die Präsentationsunterlagen genau geprüft",
            "sentence_ko": "발표 자료를 자세히 검토했다.",
            "target_ko": "발표 자료를 자세히 검토했다",
        },
        language="german",
    ) is None
    # The same answer keeps its card when real context remains around it.
    assert _normalize_bundle_cloze(
        {
            "sentence_en": "Vor der Sitzung habe ich am Abend die Unterlagen genau geprüft.",
            "blank": "die Unterlagen genau geprüft",
            "sentence_ko": "회의 전에 저녁에 자료를 자세히 검토했다.",
            "target_ko": "자료를 자세히 검토했다",
        },
        language="german",
    ) is not None


def test_rejects_a_blank_that_swallows_a_possessive_object() -> None:
    # "buy back their shares or bonds" makes the learner guess a pronoun whose
    # referent flips with the speaker: the Korean gloss says "내 주식/채권"
    # while the English sentence says "their". Only "buy back" is vocabulary.
    assert not _is_teachable_cloze("buy back their shares or bonds", language="english")
    assert not _is_teachable_cloze("pay back his investment", language="english")
    assert _is_teachable_cloze("buy back", language="english")
    assert _is_teachable_cloze("pay back the investment", language="english")


def test_production_validator_rejects_a_prompt_that_leaks_the_answer() -> None:
    with pytest.raises(ValueError, match="leaks the answer"):
        validate_quiz_payload(
            "cloze",
            {
                "sentence_en": "The platform has eight drivers.",
                "quiz_data": {
                    "prompt_en": "The platform has ___ eight drivers.",
                    "blank": "eight",
                    "accepted_answers": ["eight"],
                    "context_ko": "플랫폼에는 <span color='#FFA500'>8개</span>의 드라이버가 있다.",
                },
            },
            target_level=20,
            target_language="english",
        )


def test_german_unicode_cloze_survives_normalization_and_validation() -> None:
    sentence, prompt, blank, context = _normalize_bundle_cloze(
        {
            "sentence_en": "Berücksichtigen Sie alle relevanten Faktoren.",
            "blank": "Berücksichtigen",
            "sentence_ko": "모든 관련 요소를 고려하세요.",
            "target_ko": "고려하세요",
        },
        language="german",
    )

    validated = validate_quiz_payload(
        "cloze",
        {
            "question_ko": "빈칸을 완성하세요.",
            "sentence_en": sentence,
            "quiz_data": {
                "prompt_en": prompt,
                "blank": blank,
                "accepted_answers": [blank],
                "context_ko": context,
            },
        },
        target_level=45,
        target_language="german",
    )

    assert validated["quiz_data"]["prompt_en"] == "___ Sie alle relevanten Faktoren."
