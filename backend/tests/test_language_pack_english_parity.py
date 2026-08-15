"""Tripwires for independently owned native->target prompt profiles."""

from __future__ import annotations

from app import quiz_bundle as qb

_NATIVE_LABEL = "Korean (한국어)"
_TARGET_LABEL = "English"
_LEVEL = 50

def test_each_direction_has_an_independent_plan_profile():
    ko_en = qb._build_plan_system_prompt(
        _NATIVE_LABEL, _TARGET_LABEL, _LEVEL, qb.lang_guide("english"), "english", "korean"
    )
    ko_de = qb._build_plan_system_prompt(
        _NATIVE_LABEL, "German (Deutsch)", _LEVEL, qb.lang_guide("german"), "german", "korean"
    )
    en_ko = qb._build_plan_system_prompt(
        "English", "Korean (한국어)", _LEVEL, qb.lang_guide("korean"), "korean", "english"
    )
    assert "[PAIR ko-en]" in ko_en
    assert "[PAIR ko-de]" in ko_de
    assert "[PAIR en-ko]" in en_ko
    assert len({ko_en, ko_de, en_ko}) == 3


def test_each_direction_has_concrete_alignment_fields():
    ko_en = qb._build_cloze_system_prompt(
        _NATIVE_LABEL, _TARGET_LABEL, _LEVEL, qb.lang_guide("english"), "english", "korean"
    )
    en_ko = qb._build_cloze_system_prompt(
        "English", "Korean (한국어)", _LEVEL, qb.lang_guide("korean"), "korean", "english"
    )
    assert "answer_en" in ko_en and "meaning_ko" in ko_en
    assert "answer_ko" in en_ko and "meaning_en" in en_ko
    assert "answer_native" not in ko_en + en_ko


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
