"""Smoke tests for native x target language combinations beyond the original
korean-native/english-or-german-target assumption. Pure unit tests — no DB.
"""

from app.languages import LANGUAGES, SUPPORTED_NATIVE, SUPPORTED_TARGET, valid_target_for_native
from app.name_match import scan_identity_mentions
from app.models import Node
from app.prompts import native_pack
from app.quiz_audio_engine import voice_for_language
from app.quiz_bundle import _normalize_bundle_cloze
from app.quiz_queue import _normalize_answer


def test_registry_covers_supported_languages():
    for lang in SUPPORTED_NATIVE | SUPPORTED_TARGET:
        assert lang in LANGUAGES


def test_native_cannot_learn_itself():
    assert "english" not in valid_target_for_native("english")
    assert "korean" not in valid_target_for_native("korean")
    # Only 3 pairs are supported: ko->en, ko->de, en->ko. An english native no
    # longer sees german as a target (dropped when SUPPORTED_PAIRS narrowed).
    assert valid_target_for_native("english") == {"korean"}
    assert valid_target_for_native("korean") == {"english", "german"}


def test_tts_voice_covers_korean_target():
    assert voice_for_language("korean") == "ko-KR-SunHiNeural"
    assert voice_for_language("english") == "en-US-JennyNeural"


def test_native_pack_english_has_self_label_me():
    pack = native_pack("english")
    assert pack.self_label == "Me"
    assert pack.memory_label == "Memory"
    pack_ko = native_pack("korean")
    assert pack_ko.self_label == "나"


def test_scan_identity_mentions_english_stoplist_excludes_self_pronoun():
    """Self node named "Me" (English native) must not match every occurrence
    of the common word "me" in a message — that would make every chat turn
    seed the self node."""
    me_node = Node(name="Me", type="Person", is_self=True)
    matches = scan_identity_mentions("Can you remind me about my plans?", [me_node], "english")
    assert matches == []


def test_scan_identity_mentions_english_matches_real_name():
    node = Node(name="Sarah", type="Person")
    matches = scan_identity_mentions("Sarah asked about the project.", [node], "english")
    assert len(matches) == 1
    assert matches[0].node is node


def test_grade_answer_korean_target_tolerates_spacing():
    assert _normalize_answer("그 사람", "korean") == _normalize_answer("그사람", "korean")
    assert _normalize_answer("Validate", "english") == "validate"


def test_normalize_bundle_cloze_native_english_script_check():
    """When native=english, the native-script guard must check for Latin script
    in the native field instead of assuming Korean/Hangul."""
    result = _normalize_bundle_cloze(
        {
            "sentence_target": "오늘 날씨가 맑았다.",  # placeholder target text
            "blank": "맑았다",
            "sentence_ko": "The weather was clear today.",
            "target_ko": "clear",
        },
        language="korean",
        native_language="english",
    )
    assert result is not None
    assert result[3] == "The weather was <span color='#FFA500'>clear</span> today."
