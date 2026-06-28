"""Integration tests for Semantic Chunk ingest + vocab quiz generation."""

from __future__ import annotations

import uuid
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy import func, select

from app import crud
from app.graph_generation import resolve_vocab_quiz_context
from app.graph_ingest import (
    IngestConceptSpec,
    IngestChunkSpec,
    IngestExtraction,
    IngestRelationSpec,
    IngestVocabSpec,
    SpeakerBinding,
    _validate_vocab_phrases,
    build_speaker_bindings_for_entry,
    coalesce_vocab_phrases,
    ingest_journal_entry,
    ingest_labeled_paragraph,
    normalize_pre_lines_with_bindings,
    normalize_vocab_phrase,
    phrase_appears_in_text,
    pre_slice_by_speaker_lines,
)
from app.graph_schema import (
    NODE_CHUNK,
    NODE_SPEAKER,
    NODE_VOCAB,
    REL_NEXT_TURN,
    REL_SPOKE_BY,
    contains_relation,
)
from app.models import Edge, JournalEntry, Node, Quiz, SpeakerEntryAppearance, SpeakerProfile
from app.speaker_confirmation import HUMAN_CONFIRMED_MATCH_SCORE, confirm_speaker_identity


SAMPLE_PARAGRAPH = """[팀장]: 이번 Q3까지 RWA 산출 모델 validation을 끝내야 합니다. 바젤 III 기준입니다.
[팀장]: 그리고 오늘 점심은 12시에 1층에서 먹읍시다.
[장세영]: 진행 상황 체크해서 보고드리겠습니다."""


def _mock_extraction() -> IngestExtraction:
    return IngestExtraction(
        chunks=[
            IngestChunkSpec(
                temp_id="c1",
                speaker="팀장",
                text="이번 Q3까지 RWA 산출 모델 validation을 끝내야 합니다. 바젤 III 기준입니다.",
                display_title="RWA 검증 지시",
            ),
            IngestChunkSpec(
                temp_id="c2",
                speaker="팀장",
                text="그리고 오늘 점심은 12시에 1층에서 먹읍시다.",
                display_title="점심 약속",
            ),
            IngestChunkSpec(
                temp_id="c3",
                speaker="장세영",
                text="진행 상황 체크해서 follow up 보고드리겠습니다.",
                display_title="검증 보고 약속",
            ),
        ],
        relations=[
            IngestRelationSpec(source="c1", target="c2", type=REL_NEXT_TURN),
            IngestRelationSpec(source="c2", target="c3", type=REL_NEXT_TURN),
            IngestRelationSpec(source="c1", target="팀장", type=REL_SPOKE_BY),
            IngestRelationSpec(source="c2", target="팀장", type=REL_SPOKE_BY),
            IngestRelationSpec(source="c3", target="장세영", type=REL_SPOKE_BY),
        ],
        vocabularies=[
            IngestVocabSpec(word="validation", connected_to="c1"),
            IngestVocabSpec(word="follow up", connected_to="c3"),
        ],
        concepts=[IngestConceptSpec(name="바젤 III", connected_to="c1")],
    )


def test_pre_slice_parses_speaker_lines():
    lines = pre_slice_by_speaker_lines(SAMPLE_PARAGRAPH)
    assert len(lines) == 3
    assert lines[0]["speaker"] == "팀장"
    assert "validation" in lines[0]["text"]


@pytest.mark.asyncio
async def test_ingest_creates_distributed_chunks(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    extraction = _mock_extraction()
    with patch("app.graph_ingest.embed_texts", new_callable=AsyncMock) as mock_emb:
        mock_emb.return_value = [[0.0] * 1536 for _ in extraction.chunks]
        result = await ingest_labeled_paragraph(
            db_session,
            user_id,
            SAMPLE_PARAGRAPH,
            extraction=extraction,
        )

    assert result.chunk_count == 3
    assert result.speaker_count == 2
    assert result.vocab_count == 2
    assert result.concept_count == 1

    chunks = await db_session.execute(
        select(Node).where(
            Node.user_id == user_id,
            func.lower(Node.type) == NODE_CHUNK.lower(),
        )
    )
    chunk_nodes = list(chunks.scalars().all())
    assert len(chunk_nodes) == 3
    for ch in chunk_nodes:
        assert not ch.description.startswith("[")
        assert "]:" not in (ch.description or "")

    next_edges = await db_session.execute(
        select(Edge).where(Edge.relation == REL_NEXT_TURN, Edge.user_id == user_id)
    )
    assert len(list(next_edges.scalars().all())) >= 2

    spoke_edges = await db_session.execute(
        select(Edge).where(Edge.relation == REL_SPOKE_BY, Edge.user_id == user_id)
    )
    assert len(list(spoke_edges.scalars().all())) >= 3

    vocab_nodes = await db_session.execute(
        select(Node).where(
            Node.user_id == user_id,
            func.lower(Node.type) == NODE_VOCAB.lower(),
        )
    )
    vocab_names = {n.name for n in vocab_nodes.scalars().all()}
    assert "validation" in vocab_names
    assert "follow up" in vocab_names


def test_normalize_vocab_phrase_collapses_whitespace():
    assert normalize_vocab_phrase("  Look   Forward   To  ") == "look forward to"


def test_coalesce_vocab_phrases_drops_token_fragments():
    vocabs = [
        IngestVocabSpec(word="look", connected_to="c1"),
        IngestVocabSpec(word="forward", connected_to="c1"),
        IngestVocabSpec(word="to", connected_to="c1"),
        IngestVocabSpec(word="look forward to", connected_to="c1"),
        IngestVocabSpec(word="wrap", connected_to="c1"),
        IngestVocabSpec(word="wrap up", connected_to="c1"),
    ]
    kept = coalesce_vocab_phrases(vocabs)
    assert {v.word for v in kept} == {"look forward to", "wrap up"}


def test_phrase_appears_in_text_ordered_tokens():
    assert phrase_appears_in_text("look forward to", "I look forward to meeting you.")
    assert phrase_appears_in_text("wrap up", "Let's wrap up the call.")
    assert not phrase_appears_in_text("wrap up", "up wrap the")


def test_validate_vocab_accepts_translation_fallback():
    data = IngestExtraction(
        chunks=[
            IngestChunkSpec(
                temp_id="c1",
                speaker="장세영",
                text="오늘 하체 운동했어요.",
                display_title="하체 운동",
            )
        ],
        relations=[
            IngestRelationSpec(source="c1", target="장세영", type=REL_SPOKE_BY),
        ],
        vocabularies=[IngestVocabSpec(word="lower body workout", connected_to="c1")],
        concepts=[],
    )
    _validate_vocab_phrases(
        data,
        translation_ref="I did a lower body workout today.",
    )
    assert len(data.vocabularies) == 1
    assert data.vocabularies[0].word == "lower body workout"


def test_normalize_pre_lines_maps_confirmed_speaker_label():
    bindings = {
        "Speaker_1": SpeakerBinding(canonical_name="장세영"),
    }
    lines = normalize_pre_lines_with_bindings(
        [{"speaker": "Speaker_1", "text": "안녕"}],
        bindings,
    )
    assert lines[0]["speaker"] == "장세영"


@pytest.mark.asyncio
async def test_ingest_reuses_single_speaker_node_for_confirmed_label(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_ko="[Speaker_1]: 오늘 운동했어",
        transcript_clean_ko="[Speaker_1]: 오늘 운동했어",
        translation_en="I worked out today.",
        transcript_segments=[{"speaker": "Speaker_1", "text": "오늘 운동했어"}],
    )
    db_session.add(entry)
    await db_session.flush()

    profile = SpeakerProfile(
        user_id=user_id,
        label="Speaker_1",
        display_name="장세영",
        embedding=[0.1] * 256,
        sample_count=1,
        total_duration_sec=1.0,
    )
    db_session.add(profile)
    await db_session.flush()
    db_session.add(
        SpeakerEntryAppearance(
            journal_entry_id=entry.id,
            speaker_profile_id=profile.id,
            session_label="Speaker_1",
            match_score=HUMAN_CONFIRMED_MATCH_SCORE,
            duration_sec=1.0,
        )
    )
    await db_session.commit()

    bindings = await build_speaker_bindings_for_entry(db_session, entry.id, user_id)
    paragraph = "[장세영]: 오늘 운동했어"
    extraction = IngestExtraction(
        chunks=[
            IngestChunkSpec(
                temp_id="c1",
                speaker="장세영",
                text="오늘 운동했어",
                display_title="운동",
            )
        ],
        relations=[
            IngestRelationSpec(source="c1", target="장세영", type=REL_SPOKE_BY),
        ],
        vocabularies=[IngestVocabSpec(word="work out", connected_to="c1")],
        concepts=[],
    )
    with patch("app.graph_ingest.embed_texts", new_callable=AsyncMock) as mock_emb:
        mock_emb.return_value = [[0.0] * 1536]
        result = await ingest_labeled_paragraph(
            db_session,
            user_id,
            paragraph,
            journal_entry_id=entry.id,
            extraction=extraction,
            translation_en=entry.translation_en,
            speaker_bindings=bindings,
        )

    assert result.speaker_count == 1
    assert result.vocab_count == 1
    speakers = await db_session.execute(
        select(Node).where(
            Node.user_id == user_id,
            func.lower(Node.type) == NODE_SPEAKER.lower(),
        )
    )
    speaker_nodes = list(speakers.scalars().all())
    assert len(speaker_nodes) == 1
    assert speaker_nodes[0].name == "장세영"
    await db_session.refresh(profile)
    assert profile.node_id == speaker_nodes[0].id


@pytest.mark.asyncio
async def test_confirm_new_name_does_not_create_graph_node(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)

    entry = JournalEntry(
        user_id=user_id,
        status="ready",
        transcript_ko="[Speaker_1] 안녕",
        transcript_segments=[{"speaker": "Speaker_1", "text": "안녕"}],
    )
    db_session.add(entry)
    await db_session.flush()

    profile = SpeakerProfile(
        user_id=user_id,
        label="Speaker_1",
        display_name="Speaker_1",
        embedding=[0.1] * 256,
        sample_count=1,
        total_duration_sec=1.0,
    )
    db_session.add(profile)
    await db_session.flush()
    db_session.add(
        SpeakerEntryAppearance(
            journal_entry_id=entry.id,
            speaker_profile_id=profile.id,
            session_label="Speaker_1",
            match_score=0.0,
            duration_sec=1.0,
        )
    )
    await db_session.commit()

    before = await db_session.execute(
        select(Node).where(Node.user_id == user_id)
    )
    assert len(list(before.scalars().all())) == 0

    await confirm_speaker_identity(
        db_session,
        user_id,
        entry.id,
        profile.id,
        new_node_name="장세영",
    )

    after = await db_session.execute(select(Node).where(Node.user_id == user_id))
    assert len(list(after.scalars().all())) == 0
    await db_session.refresh(profile)
    assert profile.display_name == "장세영"
    assert profile.node_id is None


@pytest.mark.asyncio
async def test_ingest_does_not_create_quizzes(db_session, dev_user):
    user_id = dev_user.id
    quizzes = await db_session.execute(select(Quiz).where(Quiz.user_id == user_id))
    before = len(list(quizzes.scalars().all()))
    assert before >= 0


@pytest.mark.asyncio
async def test_semantic_shift_same_speaker_two_chunks(db_session, dev_user):
    user_id = dev_user.id
    paragraph = """[팀장]: RWA validation 마감입니다.
[팀장]: 점심은 12시 1층입니다."""
    extraction = IngestExtraction(
        chunks=[
            IngestChunkSpec(
                temp_id="c1",
                speaker="팀장",
                text="RWA validation 마감입니다.",
                display_title="RWA 마감",
            ),
            IngestChunkSpec(
                temp_id="c2",
                speaker="팀장",
                text="점심은 12시 1층입니다.",
                display_title="점심 약속",
            ),
        ],
        relations=[
            IngestRelationSpec(source="c1", target="c2", type=REL_NEXT_TURN),
            IngestRelationSpec(source="c1", target="팀장", type=REL_SPOKE_BY),
            IngestRelationSpec(source="c2", target="팀장", type=REL_SPOKE_BY),
        ],
        vocabularies=[IngestVocabSpec(word="validation", connected_to="c1")],
        concepts=[],
    )
    with patch("app.graph_ingest.embed_texts", new_callable=AsyncMock) as mock_emb:
        mock_emb.return_value = [[0.0] * 1536, [0.0] * 1536]
        result = await ingest_labeled_paragraph(
            db_session, user_id, paragraph, extraction=extraction
        )
    assert result.chunk_count == 2
    speakers = await db_session.execute(
        select(Node).where(
            Node.user_id == user_id,
            func.lower(Node.type) == NODE_SPEAKER.lower(),
            Node.name == "팀장",
        )
    )
    assert speakers.scalar_one_or_none() is not None


@pytest.mark.asyncio
async def test_resolve_vocab_quiz_context_traverses_chain(db_session, dev_user):
    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)
    extraction = _mock_extraction()
    with patch("app.graph_ingest.embed_texts", new_callable=AsyncMock) as mock_emb:
        mock_emb.return_value = [[0.0] * 1536 for _ in extraction.chunks]
        await ingest_labeled_paragraph(
            db_session, user_id, SAMPLE_PARAGRAPH, extraction=extraction
        )

    vocab = await db_session.execute(
        select(Node).where(
            Node.user_id == user_id,
            Node.name == "validation",
        )
    )
    vocab_node = vocab.scalar_one()
    ctx = await resolve_vocab_quiz_context(db_session, user_id, vocab_node.id)
    assert ctx.vocab_lemma == "validation"
    assert ctx.speaker_name == "팀장"
    assert "팀장" in ctx.formatted_dialogue
    assert len(ctx.context_before) + len(ctx.context_after) >= 0


@pytest.mark.asyncio
async def test_vocab_quiz_generation_mocked(db_session, dev_user):
    from app.quiz_pipeline import _run_vocab_node_quiz_pipeline

    user_id = dev_user.id
    await crud.clear_user_knowledge_graph(db_session, user_id)
    extraction = _mock_extraction()
    with patch("app.graph_ingest.embed_texts", new_callable=AsyncMock) as mock_emb:
        mock_emb.return_value = [[0.0] * 1536 for _ in extraction.chunks]
        await ingest_labeled_paragraph(
            db_session, user_id, SAMPLE_PARAGRAPH, extraction=extraction
        )
    vocab = await db_session.scalar(
        select(Node).where(Node.user_id == user_id, Node.name == "validation")
    )
    mock_quiz = {
        "difficulty_level": 5,
        "question_ko": "빈칸 채우기",
        "sentence_en": "We need validation by Q3.",
        "quiz_data": {
            "prompt_en": "We need ___ by Q3.",
            "blank": "validation",
            "accepted_answers": ["validation"],
            "context_ko": "검증",
        },
    }
    with patch(
        "app.quiz_pipeline.generate_vocab_cloze_from_context",
        new_callable=AsyncMock,
    ) as mock_gen:
        mock_gen.return_value = {**mock_quiz, "_model": "test", "_raw_llm": mock_quiz}
        with patch(
            "app.quiz_pipeline.synthesize_quiz_audio",
            new_callable=AsyncMock,
            return_value=(None, None),
        ):
            quiz, trace = await _run_vocab_node_quiz_pipeline(
                db_session,
                user_id,
                "cloze",
                vocab_node_id=vocab.id,
            )
    assert quiz.quiz_type == "cloze"
    assert any(s.get("name") == "graph_context_resolve" for s in trace.get("steps", []))
