from app.quiz_audio_engine import (
    answer_audio_asset_key,
    quiz_audio_relative_path,
    resolve_cloze_answer_tts_text,
)


def test_cloze_answer_audio_uses_complete_multiword_expression():
    validated = {
        "quiz_data": {
            "blank": "look forward to",
            "accepted_answers": ["look forward to"],
        }
    }
    assert resolve_cloze_answer_tts_text(validated) == "look forward to"


def test_answer_audio_has_a_distinct_deterministic_path():
    import uuid

    quiz_id = uuid.UUID("00000000-0000-0000-0000-000000000123")
    assert quiz_audio_relative_path(quiz_id).endswith("000000000123.mp3")
    assert quiz_audio_relative_path(quiz_id, variant="answer").endswith(
        "000000000123-answer.mp3"
    )


def test_answer_audio_asset_key_is_shared_only_for_same_voice_and_text():
    assert answer_audio_asset_key("has", "english") == answer_audio_asset_key(
        "has", "english"
    )
    assert answer_audio_asset_key("has", "english") != answer_audio_asset_key(
        "has", "german"
    )
