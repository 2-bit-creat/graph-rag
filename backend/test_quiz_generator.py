"""Tests for quiz payload validation (no LLM)."""

from app.quiz_generator import (
    _normalize_question_ko,
    generate_malheoboca_hint,
    validate_quiz_payload,
    _compute_scramble_order,
    _apply_freedom_seed,
    _tokenize_scramble_sentence,
    _prepare_scramble_chunks,
    _sentence_contains_seed,
    _build_system_prompt,
    _validate_mcq_nuance_coherence,
    _MCQ_NUANCE_DISTRACTOR_RULES,
)


def test_malheoboca_hint_low_level():
    hint = generate_malheoboca_hint("restaurant", 20)
    assert hint.startswith("r e s")
    assert len(hint.split()) == len("restaurant")


def test_malheoboca_hint_mid_level():
    hint = generate_malheoboca_hint("restaurant", 50)
    assert hint.startswith("r")
    assert len(hint.split()) == len("restaurant")


def test_malheoboca_hint_high_level_long_word():
    hint = generate_malheoboca_hint("restaurant", 80)
    assert hint.startswith("r")
    assert hint.count("_") == len("restaurant") - 1


def test_malheoboca_hint_high_level_short_word():
    hint = generate_malheoboca_hint("coffee", 80)
    assert hint == "_ _ _ _ _ _"


def test_malheoboca_hint_multi_word_phrase():
    hint = generate_malheoboca_hint("cause a stir", 50)
    parts = hint.split("   ")
    assert len(parts) == 3
    assert parts[0].startswith("c")
    assert "   " in hint


def test_freedom_seed_overrides_blank():
    quiz_data = {
        "prompt_en": "Jennifer was in a bad situation.",
        "blank": "arrived",
        "accepted_answers": ["arrived"],
        "context_ko": "제니퍼는 <span color='#FFA500'>도착</span>했다.",
        "sentence_en": "Jennifer was precarious.",
    }
    payload = {
        "difficulty_level": 10,
        "question_ko": "x",
        "sentence_en": "Jennifer found herself in a precarious situation.",
        "quiz_data": quiz_data,
    }
    out = validate_quiz_payload(
        "cloze",
        payload,
        freedom_seed="precarious",
        target_level=97,
    )
    assert out["quiz_data"]["blank"] == "precarious"
    assert out["difficulty_level"] == 97
    assert "blank_display" in out["quiz_data"]


def test_freedom_seed_multi_word_phrase():
    payload = {
        "difficulty_level": 10,
        "question_ko": "x",
        "sentence_en": "The news will cause a stir among locals.",
        "quiz_data": {
            "prompt_en": "The news will ___ among locals.",
            "blank": "arrive",
            "accepted_answers": ["arrive"],
            "context_ko": "그 소식은 <span color='#FFA500'>소동</span>을 일으킬 것이다.",
        },
    }
    out = validate_quiz_payload(
        "cloze",
        payload,
        freedom_seed="cause a stir",
        target_level=90,
    )
    assert out["quiz_data"]["blank"] == "cause a stir"
    assert "cause" in out["quiz_data"]["blank_display"] or "_" in out["quiz_data"]["blank_display"]


def test_apply_freedom_seed_syncs_prompt():
    quiz_data = {
        "prompt_en": "She felt precarious about the investment.",
        "sentence_en": "She felt precarious about the investment.",
    }
    _apply_freedom_seed(quiz_data, "precarious", 80)
    assert quiz_data["blank"] == "precarious"
    assert "___" in quiz_data["prompt_en"]


def test_cloze_validate_malheoboca():
    payload = {
        "difficulty_level": 35,
        "question_ko": "핵심 영어 단어를 쓰세요",
        "sentence_en": "I drank an espresso.",
        "quiz_data": {
            "prompt_en": "I drank an ___",
            "blank": "espresso",
            "accepted_answers": ["espresso"],
            "context_ko": "나는 <span color='#FFA500'>에스프레소</span>를 마셨다.",
            "hint_ko": "카페 음료",
        },
    }
    out = validate_quiz_payload("cloze", payload)
    assert out["difficulty_level"] == 35
    assert "blank_display" in out["quiz_data"]
    assert out["quiz_data"]["blank_display"] == generate_malheoboca_hint("espresso", 35)


def test_cloze_auto_wraps_missing_span():
    payload = {
        "difficulty_level": 10,
        "question_ko": "x",
        "quiz_data": {
            "prompt_en": "I visited the ___",
            "blank": "river",
            "accepted_answers": ["river"],
            "context_ko": "강가에 갔다",
        },
    }
    out = validate_quiz_payload("cloze", payload)
    assert "FFA500" in out["quiz_data"]["context_ko"]
    assert "강가에 갔다" in out["quiz_data"]["context_ko"]


def test_cloze_reuses_english_accepted_answer_for_bad_blank():
    payload = {
        "difficulty_level": 10,
        "question_ko": "x",
        "quiz_data": {
            "prompt_en": "I visited the ___",
            "blank": "강",
            "accepted_answers": ["river", "River"],
            "context_ko": "강가에 갔다",
        },
    }
    out = validate_quiz_payload("cloze", payload)
    assert out["quiz_data"]["blank"] == "river"


def test_cloze_rejects_korean_blank():
    payload = {
        "difficulty_level": 10,
        "question_ko": "x",
        "quiz_data": {
            "prompt_en": "visited the ___",
            "blank": "강남",
            "accepted_answers": ["강남"],
            "context_ko": "<span color='#FFA500'>강남</span>",
        },
    }
    try:
        validate_quiz_payload("cloze", payload)
        raise AssertionError("expected ValueError")
    except ValueError as e:
        assert "English" in str(e)


def test_normalize_personal_trivia_question():
    q = _normalize_question_ko("장세영은 어디를 방문했나요?", "cloze")
    assert "방문" not in q
    assert "영어" in q


def test_scramble_order_computed():
    chunks = ["met", "I", "Cheolsu", "at", "Starbucks"]
    sentence = "I met Cheolsu at Starbucks"
    order = _compute_scramble_order(chunks, sentence)
    assert len(order) == len(chunks)
    payload = {
        "difficulty_level": 20,
        "quiz_data": {"sentence_en": sentence},
    }
    out = validate_quiz_payload("scramble", payload)
    assert "correct_order" in out["quiz_data"]
    assert len(out["quiz_data"]["chunks"]) == 5
    assert all(" " not in c for c in out["quiz_data"]["chunks"])


def test_scramble_single_word_tokenization():
    sentence = "Jennifer prepared matcha for Jang Seyoung."
    tokens = _tokenize_scramble_sentence(sentence)
    assert tokens == [
        "Jennifer",
        "prepared",
        "matcha",
        "for",
        "Jang",
        "Seyoung.",
    ]
    assert all(" " not in t for t in tokens)


def test_scramble_chunks_shuffled_not_sequential():
    sentence = "Jennifer prepared matcha for Jang Seyoung."
    import random

    rng = random.Random(42)
    chunks, order = _prepare_scramble_chunks(sentence, rng=rng)
    assert len(chunks) == 6
    assert order != list(range(len(chunks)))
    assert all(" " not in c for c in chunks)
    rebuilt = " ".join(chunks[i] for i in order)
    assert rebuilt.replace(" .", ".").startswith("Jennifer")


def test_scramble_rejects_multiword_llm_chunks():
    """Server ignores LLM clumps and re-tokenizes from sentence_en."""
    sentence = "Jennifer prepared matcha for Jang Seyoung."
    payload = {
        "difficulty_level": 38,
        "quiz_data": {
            "sentence_en": sentence,
            "chunks": ["Jennifer prepared", "matcha for", "Jang Seyoung."],
        },
    }
    out = validate_quiz_payload("scramble", payload, target_level=38)
    assert len(out["quiz_data"]["chunks"]) == 6
    assert out["quiz_data"]["correct_order"] != list(range(6))


def test_scramble_freedom_mode_requires_seed():
    sentence = "Jennifer deliberately prepared matcha for Jang Seyoung."
    payload = {
        "difficulty_level": 38,
        "sentence_en": sentence,
        "quiz_data": {"sentence_en": sentence},
    }
    out = validate_quiz_payload(
        "scramble", payload, freedom_seed="deliberately", target_level=38
    )
    assert _sentence_contains_seed(out["sentence_en"], "deliberately")


def test_scramble_freedom_off_literal_fact():
    sentence = "Jennifer prepared matcha for Jang Seyoung."
    prompt = _build_system_prompt(
        "scramble", 38, "graph", is_freedom_on=False, vocab_seed=None
    )
    assert "STRICT FACT-BASED" in prompt
    assert "ZERO CREATIVITY" in prompt
    out = validate_quiz_payload(
        "scramble",
        {"difficulty_level": 38, "quiz_data": {"sentence_en": sentence}},
        target_level=38,
    )
    assert out["difficulty_level"] == 38


def test_scramble_freedom_on_weaves_vocab():
    sentence = "Jennifer deliberately prepared refined matcha for Jang Seyoung."
    prompt = _build_system_prompt(
        "scramble",
        38,
        "graph",
        is_freedom_on=True,
        vocab_seed={"word": "deliberately", "cefr": "b1"},
    )
    assert "FREEDOM MODE" in prompt
    assert "deliberately" in prompt
    out = validate_quiz_payload(
        "scramble",
        {"difficulty_level": 38, "quiz_data": {"sentence_en": sentence}},
        freedom_seed="deliberately",
        target_level=38,
    )
    assert out["quiz_data"]["correct_order"] != list(range(len(out["quiz_data"]["chunks"])))


def test_mcq_freedom_mode_requires_seed_in_correct_option():
    payload = {
        "difficulty_level": 38,
        "quiz_data": {
            "prompt_ko": "제니퍼가 말차를 정성껏 준비할 때",
            "options": [
                "Jennifer made matcha in a very deliberate way for the guest.",
                "Jennifer deliberately prepared matcha for Seyoung with great care.",
                "Jennifer made the matcha too deliberately and it looked odd.",
                "Jennifer was deliberately focused while preparing matcha for Seyoung.",
            ],
            "correct_index": 1,
            "explanation": "deliberately가 의도를 자연스럽게 표현합니다.",
        },
    }
    out = validate_quiz_payload(
        "mcq_nuance", payload, freedom_seed="deliberately", target_level=38
    )
    assert out["difficulty_level"] == 38


def test_mcq_rejects_disconnected_distractors():
    """Regression: gym/matcha/travel options when theme is consulting."""
    payload = {
        "difficulty_level": 50,
        "quiz_data": {
            "prompt_ko": "컨설팅 업계의 복잡한 관계망에 대해 이야기할 때",
            "options": [
                "The web of connections in the consulting industry is quite complex.",
                "Jennifer arrived in Korea for a meeting.",
                "Jang Seyoung used the hip thrust machine during her workout.",
                "The matcha was prepared by Jennifer.",
            ],
            "correct_index": 0,
        },
    }
    try:
        validate_quiz_payload("mcq_nuance", payload)
        raise AssertionError("expected ValueError")
    except ValueError as e:
        assert "contextually disconnected" in str(e)


def test_mcq_accepts_on_theme_nuance_distractors():
    payload = {
        "difficulty_level": 50,
        "quiz_data": {
            "prompt_ko": "컨설팅 업계의 복잡한 관계망에 대해 이야기할 때",
            "options": [
                "The web of connections in the consulting industry is quite complex.",
                "The consulting industry's human relationship net is very twisted.",
                "Consulting networking is super messy and crazy.",
                "There are many consultants networking across the consulting industry.",
            ],
            "correct_index": 0,
            "explanation": "web of connections가 관계망을 자연스럽게 표현합니다.",
        },
    }
    out = validate_quiz_payload("mcq_nuance", payload)
    assert out["sentence_en"] == payload["quiz_data"]["options"][0]
    assert out["quiz_data"]["options"][1].startswith("The consulting")


def test_mcq_nuance_prompt_includes_distractor_rules():
    prompt = _build_system_prompt("mcq_nuance", 50, "graph", is_freedom_on=False)
    assert "MCQ NUANCE" in prompt
    assert "동일 맥락" in _MCQ_NUANCE_DISTRACTOR_RULES
    assert "AWKWARD/LITERAL" in prompt or "AWKWARD" in prompt
    assert "FORBIDDEN" in prompt


def test_mcq_freedom_mode_rejects_missing_seed():
    payload = {
        "difficulty_level": 38,
        "quiz_data": {
            "prompt_ko": "제니퍼가 말차를 정성껏 준비할 때",
            "options": [
                "Jennifer made matcha carefully for the guest.",
                "Jennifer bought tea at the store instead of making matcha.",
                "Jennifer stirred matcha with a bamboo whisk slowly.",
                "Jennifer served matcha in a traditional bowl.",
            ],
            "correct_index": 0,
        },
    }
    try:
        validate_quiz_payload(
            "mcq_nuance", payload, freedom_seed="deliberately", target_level=38
        )
        raise AssertionError("expected ValueError")
    except ValueError as e:
        assert "deliberately" in str(e)


def test_mcq_validate():
    payload = {
        "difficulty_level": 50,
        "quiz_data": {
            "prompt_ko": "분위기가 싸해졌다",
            "options": [
                "The atmosphere became tense between them.",
                "The air between them got very stiff and awkward.",
                "Things got super weird and tense, like, really bad.",
                "The tense atmosphere between them felt painfully awkward.",
            ],
            "correct_index": 0,
        },
    }
    out = validate_quiz_payload("mcq_nuance", payload)
    assert out["difficulty_level"] == 50


if __name__ == "__main__":
    test_malheoboca_hint_low_level()
    test_malheoboca_hint_mid_level()
    test_malheoboca_hint_high_level_long_word()
    test_malheoboca_hint_high_level_short_word()
    test_malheoboca_hint_multi_word_phrase()
    test_freedom_seed_overrides_blank()
    test_freedom_seed_multi_word_phrase()
    test_apply_freedom_seed_syncs_prompt()
    test_cloze_validate_malheoboca()
    test_cloze_auto_wraps_missing_span()
    test_cloze_reuses_english_accepted_answer_for_bad_blank()
    test_cloze_rejects_korean_blank()
    test_normalize_personal_trivia_question()
    test_scramble_order_computed()
    test_scramble_single_word_tokenization()
    test_scramble_chunks_shuffled_not_sequential()
    test_scramble_rejects_multiword_llm_chunks()
    test_scramble_freedom_mode_requires_seed()
    test_scramble_freedom_off_literal_fact()
    test_scramble_freedom_on_weaves_vocab()
    test_mcq_freedom_mode_requires_seed_in_correct_option()
    test_mcq_rejects_disconnected_distractors()
    test_mcq_accepts_on_theme_nuance_distractors()
    test_mcq_nuance_prompt_includes_distractor_rules()
    test_mcq_freedom_mode_rejects_missing_seed()
    test_mcq_validate()
    print("OK")
