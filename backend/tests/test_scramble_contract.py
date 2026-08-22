import uuid

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Quiz, User
from app.quiz_bundle import (
    _merge_scramble_units_to_cap,
    _scramble_payload,
    _scramble_units_contract_reason,
    _scramble_word_content_reason,
    _target_reference_reason,
    _translation_note_contract_reason,
)
from app.quiz_queue import grade_answer
from app.quiz_types import ENABLED_QUIZ_TYPES, validate_quiz_type
from app.routers.quiz import scramble_hint
from app.schemas import ScrambleHintRequest


class _Quiz:
    quiz_type = "scramble"
    language = "english"

    def __init__(self, data):
        self.quiz_data = data


def test_scramble_uses_opaque_ids_for_repeated_words_and_keeps_punctuation():
    payload, reason = _scramble_payload("I really really like this.", seed="unit")
    assert reason is None
    assert payload is not None
    assert [piece["text"] for piece in payload["chunks"]].count("really") == 2
    assert len({piece["id"] for piece in payload["chunks"]}) == 5
    assert payload["sentence_target"].endswith("this.")
    assert all(isinstance(value, str) for value in payload["correct_order"])


def test_scramble_boundaries_and_id_grading():
    assert _scramble_payload("one two", seed="short")[0] is None
    assert _scramble_payload("1 2 3 4 5 6 7 8 9 10 11 12 13", seed="long")[0] is None
    payload, _ = _scramble_payload("어제 머리를 잘랐어요.", seed="ko")
    assert payload is not None
    quiz = _Quiz(payload)
    assert grade_answer(quiz, {"order": payload["correct_order"]})[0] is True
    assert grade_answer(quiz, {"order": list(reversed(payload["correct_order"]))})[0] is False


def test_valid_alternate_order_is_accepted_at_grading():
    units = ["나는", "어제", "머리를", "잘랐어요."]
    sentence = " ".join(units)
    # swap the two middle adverbial/object units — both orders are natural Korean.
    payload, reason = _scramble_payload(
        sentence, seed="alt-ko", language="korean", scramble_units=units,
        alternate_orders=[[0, 2, 1, 3]],
    )
    assert reason is None
    assert len(payload["accepted_orders"]) == 2
    assert payload["accepted_orders"][0] == payload["correct_order"]
    quiz = _Quiz(payload)
    assert grade_answer(quiz, {"order": payload["correct_order"]})[0] is True
    assert grade_answer(quiz, {"order": payload["accepted_orders"][1]})[0] is True
    assert grade_answer(quiz, {"order": list(reversed(payload["correct_order"]))})[0] is False


def test_malformed_or_duplicate_alternate_orders_are_dropped():
    units = ["나는", "어제", "머리를", "잘랐어요."]
    sentence = " ".join(units)
    # not a permutation of the same 4 indices, and a duplicate of correct_order.
    payload, _ = _scramble_payload(
        sentence, seed="alt-ko-bad", language="korean", scramble_units=units,
        alternate_orders=[[0, 1, 2], [0, 1, 2, 3]],
    )
    assert payload["accepted_orders"] == [payload["correct_order"]]


def test_alternate_orders_are_ignored_when_scramble_units_fall_back():
    # No valid scramble_units supplied, so tokens no longer line up with the
    # indices alternate_orders was written against — must not be applied.
    payload, _ = _scramble_payload(
        "I really really like this and that a lot today.",
        seed="alt-fallback",
        alternate_orders=[[1, 0, 2, 3, 4, 5, 6, 7, 8]],
    )
    assert payload["accepted_orders"] == [payload["correct_order"]]


def test_old_scramble_cards_without_accepted_orders_still_grade():
    quiz = _Quiz({"correct_order": ["a", "b", "c"]})
    assert grade_answer(quiz, {"order": ["a", "b", "c"]})[0] is True
    assert grade_answer(quiz, {"order": ["c", "b", "a"]})[0] is False


def test_scramble_rejects_target_fragments_even_when_token_count_is_valid():
    payload, reason = _scramble_payload(
        "receiving delay information", seed="fragment", language="english"
    )
    assert payload is None
    assert reason == "target_reference_is_gerund_or_infinitive_fragment"
    assert _target_reference_reason("The train was delayed.", "english") is None


def test_cloze_is_legacy_only_but_scramble_is_active():
    assert validate_quiz_type("cloze") == "cloze"
    assert "cloze" not in ENABLED_QUIZ_TYPES
    assert "scramble" in ENABLED_QUIZ_TYPES


@pytest.mark.asyncio
async def test_hint_reveals_a_prefix_and_never_the_whole_sentence(
    db_session: AsyncSession, iso_user: User
) -> None:
    """A hint assists the arrangement; it must not hand over the answer.

    The chunk ids are opaque and the answer key never reaches the client
    (``_public_quiz_data`` strips it), so the order hint has to come from the
    server — and it is capped at "everything but the last two chunks", past
    which there is nothing left for the learner to work out.
    """
    payload, _ = _scramble_payload("어제 친구를 만나서 밥을 먹었어요.", seed="hint")
    assert payload is not None
    quiz = Quiz(
        user_id=iso_user.id,
        quiz_type="scramble",
        language="korean",
        queue_kind="new",
        quiz_data=payload,
    )
    db_session.add(quiz)
    await db_session.flush()

    first = await scramble_hint(
        quiz.id, ScrambleHintRequest(hint_level=1), user=iso_user, session=db_session
    )
    assert first.ordered_prefix == payload["correct_order"][:1]
    assert first.max_hint_level == len(payload["correct_order"]) - 2

    greedy = await scramble_hint(
        quiz.id, ScrambleHintRequest(hint_level=99), user=iso_user, session=db_session
    )
    assert greedy.ordered_prefix == payload["correct_order"][: first.max_hint_level]
    assert len(greedy.ordered_prefix) < len(payload["correct_order"])


def test_a_documented_clause_missing_from_the_reference_is_a_release_failure():
    """The card that motivated this gate: the plan documented "so that he could
    wipe it" → "닦을 수 있도록", then shipped a reference without the clause."""
    segment = {
        "reference_answers": [
            {"text": "오늘 동료가 책상에 물을 쏟는 것을 보고, 휴지를 주었어요."}
        ],
        "translation_notes": [
            {
                "source": "my colleague Ha Seung-mok",
                "target": "동료",
                "note": "고유명사를 일반 표현으로 처리했습니다.",
            },
            {
                "source": "so that he could wipe it",
                "target": "닦을 수 있도록",
                "note": "목적을 '-도록'으로 옮겼습니다.",
            },
        ],
    }
    reason = _translation_note_contract_reason(segment)
    assert reason is not None
    assert reason.startswith("plan_clause_dropped: ")
    assert "닦을 수 있도록" in reason


def test_a_realized_note_passes_even_when_the_form_is_inflected():
    """Only an *absent* realization is a failure — a note is allowed to quote a
    slightly different form of what the sentence actually says."""
    realized = {
        "reference_answers": [
            {"text": "나는 그가 그것을 닦을 수 있도록 휴지를 주었어요."}
        ],
        "translation_notes": [
            {"source": "so that he could wipe it", "target": "닦도록", "note": "목적 표현"}
        ],
    }
    assert _translation_note_contract_reason(realized) is None
    assert _translation_note_contract_reason({"reference_answers": [], "translation_notes": []}) is None


def test_a_long_reference_survives_via_author_supplied_phrase_chunks():
    """The bug this defends against: a model asked to keep a reference under
    a word budget drops a clause instead. The fix removes the budget and lets
    the author group its own words into playable pieces for the game instead —
    a sentence with more than 12 raw words is fine as long as it groups into
    at most 12 semantic chunks that reconstruct it exactly."""
    sentence = (
        "오늘 동료가 책상에 물을 쏟는 것을 보고, 내가 그가 그것을 닦을 수 있도록 휴지를 주었어요."
    )
    raw_tokens = sentence.split(" ")
    assert len(raw_tokens) > 12  # would have been rejected by the old word-count gate

    units = [
        "오늘",
        "동료가",
        "책상에 물을 쏟는 것을",
        "보고,",
        "내가",
        "그가 그것을 닦을 수 있도록",
        "휴지를",
        "주었어요.",
    ]
    assert " ".join(units) == sentence
    assert len(units) <= 12

    payload, reason = _scramble_payload(sentence, seed="long-chunked", scramble_units=units)
    assert reason is None
    assert payload is not None
    assert sorted(piece["text"] for piece in payload["chunks"]) == sorted(units)
    quiz = _Quiz(payload)
    assert grade_answer(quiz, {"order": payload["correct_order"]})[0] is True


def test_a_long_reference_without_valid_chunks_still_falls_back_and_rejects():
    """No author grouping (or a broken one) degrades to the original per-word
    behaviour rather than shipping an unplayable double-digit-piece card."""
    sentence = (
        "오늘 동료가 책상에 물을 쏟는 것을 보고, 내가 그가 그것을 닦을 수 있도록 휴지를 주었어요."
    )
    assert _scramble_payload(sentence, seed="long-unchunked")[0] is None
    # A grouping whose pieces don't reconstruct the sentence is rejected the
    # same way, not silently accepted with the wrong text.
    broken_units = ["오늘", "동료가", "책상에 물을 쏟았다"]
    assert _scramble_payload(sentence, seed="long-broken", scramble_units=broken_units)[0] is None


def test_word_content_gate_catches_a_dropped_word_but_tolerates_punctuation():
    """A model that splits "쏟는 것을 보고," into a bare "보고" unit (dropping
    the comma) turned out to be the common case, not the exception — punctuation
    placement across pieces has no effect on grading or on what's shown to the
    learner (sentence_target is always shown verbatim), so it must not cost the
    card. A missing *word* still must, and does."""
    sentence = "오늘 동료가 책상에 물을 쏟았다."
    assert _scramble_word_content_reason(sentence, ["오늘", "동료가", "책상에", "물을", "쏟았다."]) is None
    # Comma/period dropped or shifted between pieces: tolerated.
    assert _scramble_word_content_reason(sentence, ["오늘", "동료가", "책상에", "물을", "쏟았다"]) is None
    assert _scramble_word_content_reason(sentence, ["오늘", "동료가,", "책상에", "물을", "쏟았다."]) is None
    # A whole word missing: still rejected.
    assert _scramble_word_content_reason(sentence, ["오늘", "동료가", "물을", "쏟았다."]) == (
        "word_content_mismatch"
    )
    assert _scramble_word_content_reason(sentence, []) == "empty_or_missing"
    assert _scramble_word_content_reason(sentence, ["오늘"]) == "chunk_count:1"


def test_over_cap_author_grouping_is_merged_down_not_discarded():
    """The exact grouping a live test1 account got back for a real sentence:
    13 pieces for a 13-word sentence (one over the cap) AND the trailing period
    dropped from the last piece — both defects this session's fixes exist for.
    Discarding the grouping and falling back to raw words would just re-trigger
    the same length rejection; recovering it by merging the smallest adjacent
    pieces is strictly better than losing the scramble card outright."""
    sentence = "이 아침에 나는 주방 창가에 있는 작은 바질 식물에 잎이 축 늘어지기 시작해서 물을 주었다."
    units = [
        "이", "아침에", "나는", "주방", "창가에", "있는", "작은", "바질",
        "식물에", "잎이", "축 늘어지기 시작해서", "물을", "주었다",  # no trailing period
    ]
    assert len(units) == 13  # one over the cap

    payload, reason = _scramble_payload(sentence, seed="merge-down", scramble_units=units)
    assert reason is None
    assert payload is not None
    assert len(payload["chunks"]) <= 12
    # The graded answer key is chunk-id order, not a text rejoin — grading
    # works regardless of the dropped period.
    quiz = _Quiz(payload)
    assert grade_answer(quiz, {"order": payload["correct_order"]})[0] is True
    # What the learner sees after grading is sentence_target verbatim, not a
    # reconstruction of the pieces — so the period is never actually lost.
    assert payload["sentence_target"] == sentence


def test_merge_scramble_units_to_cap_prefers_smallest_adjacent_pair():
    merged = _merge_scramble_units_to_cap(["a", "bb", "c", "dddd"], 3)
    assert len(merged) == 3
    assert " ".join(merged) == "a bb c dddd"
    # "a" and "c" are the shortest non-adjacent... but only adjacent pairs are
    # eligible, so the smallest adjacent combined pair ("a"+"bb" vs "bb"+"c" vs
    # "c"+"dddd") gets merged first: "bb"+"c" (2+1=3) ties "a"+"bb" (1+2=3) —
    # leftmost wins by `min`'s stable tie-break.
    assert merged[0] == "a bb"


def test_merge_scramble_units_to_cap_is_a_noop_within_cap():
    units = ["one", "two", "three"]
    assert _merge_scramble_units_to_cap(units, 5) == units


def test_scramble_units_contract_reason_only_flags_real_word_loss():
    """Feeds the retry loop (see the ``unit_domain_reason`` chain in
    generate_quiz_bundle) so the reviewer gets one targeted chance to fix a
    broken grouping — but only for a genuine dropped/changed word. An
    over-cap or punctuation-shifted grouping is left alone: those are
    recovered deterministically at build time (merge-down / word-content
    tolerance in ``_scramble_payload``), so retrying the whole unit over them
    would just spend a call fixing something that was never actually broken.
    """
    segment = {
        "reference_answers": [{
            "text": "오늘 동료가 책상에 물을 쏟았다.",
            "scramble_units": ["오늘", "동료가", "물을", "쏟았다."],  # "책상에" missing
        }]
    }
    reason = _scramble_units_contract_reason(segment)
    assert reason is not None
    assert reason.startswith("plan_scramble_units_invalid: ")

    # Punctuation-only difference: not a retry trigger.
    fine_punctuation = {
        "reference_answers": [{
            "text": "오늘 동료가 책상에 물을 쏟았다.",
            "scramble_units": ["오늘", "동료가", "책상에", "물을", "쏟았다"],
        }]
    }
    assert _scramble_units_contract_reason(fine_punctuation) is None

    # No units at all: the build-time fallback handles it, not a retry trigger.
    no_units = {"reference_answers": [{"text": "오늘 동료가 책상에 물을 쏟았다.", "scramble_units": []}]}
    assert _scramble_units_contract_reason(no_units) is None

    assert _scramble_units_contract_reason({"reference_answers": []}) is None


@pytest.mark.asyncio
async def test_scramble_session_never_injects_a_composition_twin(
    db_session: AsyncSession, iso_user: User
) -> None:
    """Picking scramble mode must stay scramble-only, explicit pick or not.

    Regression #1: selecting a single scramble quiz from a node's detail
    sheet used to come back from /quiz/session with its composition twin
    silently appended.

    Regression #2: start_session used to pair every scramble in the normal
    auto-built queue (picking "scramble" mode from the study menu) with its
    composition twin too — so "study just scramble" kept turning into a mix
    of scramble and composition cards. Pairing is gone entirely now; the two
    quiz types are independent selections.
    """
    from fastapi import BackgroundTasks

    from app.routers.quiz import start_session
    from app.schemas import QuizSessionRequest

    unit_id = "node-explicit:0"
    node_id = uuid.uuid4()
    scramble = Quiz(
        user_id=iso_user.id,
        quiz_type="scramble",
        language="korean",
        queue_kind="new",
        source_nodes=[node_id],
        quiz_data={
            "learning_unit_id": unit_id,
            "sentence_target": "오늘 동료가 책상에 물을 쏟았다.",
            "chunks": [{"id": "t0", "text": "오늘"}, {"id": "t1", "text": "동료가"}],
            "correct_order": ["t0", "t1"],
        },
    )
    composition = Quiz(
        user_id=iso_user.id,
        quiz_type="composition",
        language="korean",
        queue_kind="new",
        source_nodes=[node_id],
        quiz_data={"learning_unit_id": unit_id},
    )
    db_session.add_all([scramble, composition])
    await db_session.flush()

    explicit = await start_session(
        QuizSessionRequest(quiz_type="scramble", quiz_ids=[scramble.id]),
        BackgroundTasks(),
        user=iso_user,
        session=db_session,
    )
    assert [item.quiz_type for item in explicit.items] == ["scramble"]

    auto_built = await start_session(
        QuizSessionRequest(quiz_type="scramble"),
        BackgroundTasks(),
        user=iso_user,
        session=db_session,
    )
    assert all(item.quiz_type == "scramble" for item in auto_built.items)


def test_a_dropped_appositive_descriptor_is_exempt_from_the_clause_gate():
    """The exact live failure: the plan documents 'a researcher' -> '연구자'
    ('the title isn't in the learning answer, only used as context') even
    though the reference correctly omits it — the model followed the prompt's
    own rule to drop apposed titles/roles (list the name in context_entities,
    keep the reference to just the name), then wrote a note about the very
    thing it correctly left out. That cost an entire card for zero reason: no
    clause went missing, only a one-word descriptor the reference was never
    supposed to carry. A short target is exempt for exactly this reason — a
    real dropped clause always has a verb and several tokens ("so that he
    could wipe it" / "닦을 수 있도록" is 3), unlike a bare title (1-2)."""
    segment = {
        "reference_answers": [{
            "text": "나는 하승목에게 물을 닦을 수 있도록 티슈를 주었다.",
        }],
        "translation_notes": [{
            "source": "a researcher",
            "target": "연구자",
            "note": "원문의 직함은 학습 정답에 넣지 않고, 문맥상 정보로만 처리했습니다.",
        }],
    }
    assert _translation_note_contract_reason(segment) is None

    english_variant = {
        "reference_answers": [{"text": "I gave Ha Seung-mok tissues to wipe it up."}],
        "translation_notes": [{
            "source": "a researcher",
            "target": "a researcher",
            "note": "Dropped from the reference; kept only for context.",
        }],
    }
    assert _translation_note_contract_reason(english_variant) is None

    # A genuine dropped clause is not short and must still be caught.
    real_drop = {
        "reference_answers": [{"text": "나는 하승목에게 티슈를 주었다."}],
        "translation_notes": [{
            "source": "so that he could wipe it",
            "target": "닦을 수 있도록",
            "note": "목적절을 자연스럽게 옮겼습니다.",
        }],
    }
    reason = _translation_note_contract_reason(real_drop)
    assert reason is not None
    assert reason.startswith("plan_clause_dropped: ")
