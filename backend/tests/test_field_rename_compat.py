"""Regression coverage for the transcript_ko/question_ko/sentence_en ->
transcript_native/question_native/sentence_target column rename: the ORM
attribute must be the new name, and read-side API dicts must still expose the
legacy key (for old mobile builds) alongside the new one.
"""

import pytest

from app import crud
from app.models import JournalEntry, Quiz
from app.quiz_presenter import quiz_queue_item_dict
from app.schemas import JournalEntryOut


@pytest.mark.asyncio
async def test_journal_entry_uses_native_column_names(db_session, iso_user):
    entry = JournalEntry(
        user_id=iso_user.id,
        status="ready",
        transcript_native="원문",
        transcript_clean_native="정제문",
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)

    assert entry.transcript_native == "원문"
    assert entry.transcript_clean_native == "정제문"
    assert not hasattr(JournalEntry, "transcript_ko")


@pytest.mark.asyncio
async def test_quiz_dict_exposes_legacy_and_new_keys(db_session, iso_user):
    quiz = await crud.create_quiz(
        db_session,
        user_id=iso_user.id,
        quiz_type="cloze",
        question_ko="빈칸을 완성하세요.",
        sentence_en="I validated the result.",
        quiz_data={"blank": "validated", "prompt_en": "I ___ the result."},
        difficulty_level=20,
        queue_kind="new",
        language="english",
    )

    d = quiz_queue_item_dict(quiz, {})
    assert d["question_ko"] == "빈칸을 완성하세요."
    assert d["sentence_en"] == "I validated the result."
    assert d["question_native"] == "빈칸을 완성하세요."
    assert d["sentence_target"] == "I validated the result."

    as_dict = crud.quiz_to_dict(quiz)
    assert as_dict["question_native"] == "빈칸을 완성하세요."
    assert as_dict["sentence_target"] == "I validated the result."


@pytest.mark.asyncio
async def test_journal_entry_out_populates_legacy_alias_from_renamed_column(
    db_session, iso_user
):
    """Regression: JournalEntryOut.transcript_ko/transcript_clean_ko must still
    populate via model_validate(entry) now that the underlying ORM attribute is
    transcript_native/transcript_clean_native — without the validation_alias,
    FastAPI's automatic response serialization would silently return null for
    every journal entry's transcript fields."""
    entry = JournalEntry(
        user_id=iso_user.id,
        status="ready",
        transcript_native="원문",
        transcript_clean_native="정제문",
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)

    out = JournalEntryOut.model_validate(entry)
    assert out.transcript_ko == "원문"
    assert out.transcript_clean_ko == "정제문"
    assert out.transcript_native == "원문"
    assert out.transcript_clean_native == "정제문"
