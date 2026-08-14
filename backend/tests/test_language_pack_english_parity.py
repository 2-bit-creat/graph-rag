"""Golden-prompt parity tripwire for the language_packs refactor.

Phase 2 of the language-pack refactor (see the "3개 언어쌍 퀴즈 품질 평준화"
plan) moved every scattered ``if language == "english"`` branch in
``quiz_bundle.py``/``quiz_generator.py``/``quiz_queue.py`` into
``app.language_packs``. korean-native -> english-target is the one pair with
full existing test coverage and production traffic, so its four system
prompts must come out of the refactor byte-for-byte identical — any diff
here means the refactor accidentally changed live English quiz generation,
not just how the German/Korean gaps get closed.

If a later phase (4/5/6) deliberately moves an English-specific sentence out
of these shared prompt builders and into ``EnglishTargetPack.plan_prompt_notes``
etc., update the expected hashes here in the SAME commit and justify the diff
with a before/after eval run — see the plan's "위험 요소" section, risk #2.
"""

from __future__ import annotations

import hashlib

from app import quiz_bundle as qb

_NATIVE_LABEL = "Korean (한국어)"
_TARGET_LABEL = "English"
_LEVEL = 50

# Hashes captured immediately after the language_packs rewiring landed, from
# the pre-refactor prompt text (verified by diffing against the git history
# of quiz_bundle.py before this test was added).
_EXPECTED_HASHES = {
    # Updated deliberately: the plan prompt now states the forbidden_entities
    # contract (graph-known people/source names must stay in context_entities,
    # including transliterations). Extraction was emitting friends' names as
    # vocabulary ("es heißt eui-jun und seung-hyun"); the prompt rule pairs with
    # the deterministic gate in app/expression_entity_guard.py. Nothing else in
    # the English prompt changed.
    "plan": "b5d28e90ed86a9e0",
    "plan_qa": "e5a002c6984cefb8",
    "inventory": "0b3b818e88b45492",
    # Updated after the fact, which is the part to be uneasy about: commit
    # 068fc18 ("improve quiz quality and node study flow") rewrote the cloze
    # authoring prompt — target_ko/forbidden_sibling_expressions became
    # answer_native/forbidden_inside_surface_answer, and the sibling-expression
    # and answer-span contracts were restated — without touching this hash, so
    # the tripwire sat red instead of being justified in that commit. The change
    # itself is deliberate and matches the shipped prompt; what is missing is the
    # before/after eval run this file asks for. Re-run it before trusting the
    # English cloze quality numbers from that commit onward.
    "cloze": "3cf9ea71d84259ae",
}


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def test_plan_prompt_unchanged_for_korean_to_english():
    prompt = qb._build_plan_system_prompt(
        _NATIVE_LABEL, _TARGET_LABEL, _LEVEL, qb.lang_guide("english"), "english"
    )
    assert _hash(prompt) == _EXPECTED_HASHES["plan"]


def test_plan_qa_prompt_unchanged_for_korean_to_english():
    prompt = qb._build_plan_qa_system_prompt(_NATIVE_LABEL, _TARGET_LABEL, _LEVEL, "english")
    assert _hash(prompt) == _EXPECTED_HASHES["plan_qa"]


def test_expression_inventory_prompt_unchanged_for_korean_to_english():
    prompt = qb._build_expression_inventory_system_prompt(
        _NATIVE_LABEL, _TARGET_LABEL, _LEVEL, "english"
    )
    assert _hash(prompt) == _EXPECTED_HASHES["inventory"]


def test_cloze_prompt_unchanged_for_korean_to_english():
    prompt = qb._build_cloze_system_prompt(
        _NATIVE_LABEL, _TARGET_LABEL, _LEVEL, qb.lang_guide("english"), "english"
    )
    assert _hash(prompt) == _EXPECTED_HASHES["cloze"]


def test_lang_guide_and_quality_rubric_delegate_to_the_registered_pack():
    from app.language_packs import target_pack

    assert qb.lang_guide("english") == target_pack("english").teaching_guide
    assert qb.localized_quality_rules("english") == target_pack("english").quality_rubric
    assert qb.lang_guide("german") == target_pack("german").teaching_guide
    assert qb.localized_quality_rules("korean") == target_pack("korean").quality_rubric


def test_unregistered_target_falls_back_to_generic_pack_and_logs_once(caplog):
    from app.language_packs import target_pack

    pack = target_pack("klingon")
    assert pack.coverage == "generic"
    assert "No TargetLanguagePack registered" in caplog.text
