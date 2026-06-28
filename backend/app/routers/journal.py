import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, Query, UploadFile, status
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..db import get_session
from ..dev_user import dev_user_dep
from ..journal_pipeline import (
    generate_example_sentences,
    generate_quiz_cards,
)
from ..models import User
from ..pipeline_runner import (
    run_graph_ingest_pipeline,
    run_journal_fast_pipeline,
    run_journal_slow_pipeline,
    run_journal_text_pipeline,
)
from ..quiz_pipeline import run_quiz_generate_pipeline
from ..quiz_types import validate_quiz_type
from ..rag import hybrid_retrieve
from ..speaker_confirmation import (
    build_speaker_summaries_for_entry,
    unconfirmed_speaker_labels,
)
from ..schemas import (
    ExamplesResponse,
    ExampleSentence,
    GraphBuildOut,
    GraphSummaryOut,
    JournalEntryOut,
    RecommendedNodeOut,
    SpeakerSummaryOut,
    QuizCard,
    QuizGenerateOut,
    QuizGenerateRequest,
    QuizResponse,
    ReviewItemOut,
    ReviewResultRequest,
    JournalTextEntryRequest,
    SpeakerProfileOut,
)

router = APIRouter(prefix="/journal", tags=["journal"])


def _schedule_graph_ingest(
    background_tasks: BackgroundTasks,
    entry_id: uuid.UUID,
    user_id: uuid.UUID,
) -> None:
    from ..workers.graph_processor import enqueue_graph_ingest

    if enqueue_graph_ingest(entry_id, user_id) is None:
        background_tasks.add_task(run_graph_ingest_pipeline, entry_id, user_id)


async def _entry_out(
    session: AsyncSession, user_id: uuid.UUID, entry
) -> JournalEntryOut:
    """Journal entry + per-session speaker confirmation status for STT UI."""
    out = JournalEntryOut.model_validate(entry)
    trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
    entry_source = trace.get("entry_source")
    if entry_source is None and entry.audio_url is None:
        from ..precision_text import is_precision_text_entry

        if is_precision_text_entry(entry):
            entry_source = "precision_text"
    if entry_source:
        out = out.model_copy(update={"entry_source": str(entry_source)})

    trace = entry.pipeline_trace if isinstance(entry.pipeline_trace, dict) else {}
    graph_status = trace.get("graph_status")
    if graph_status is None and entry.status in (
        "graph_processing",
        "graph_ready",
        "graph_failed",
    ):
        graph_status = entry.status
    # Authoritative override: if graph nodes are actually committed for this entry,
    # the graph IS ready — self-heal a stuck 'graph_processing'/'graph_failed'.
    if graph_status != "graph_ready":
        if await crud.entry_has_graph_nodes(session, entry.id):
            graph_status = "graph_ready"
    ingest_summary = trace.get("ingest_summary")
    if graph_status or ingest_summary:
        out = out.model_copy(
            update={
                "graph_status": graph_status,
                "ingest_summary": ingest_summary,
            }
        )

    from ..speaker_profiles import (
        entry_speaker_bindings_mismatched,
        entry_speaker_bindings_need_repair,
        repair_entry_speaker_bindings,
    )

    segments = entry.transcript_segments
    if isinstance(segments, list) and segments:
        needs_repair = entry_speaker_bindings_need_repair(entry) or await entry_speaker_bindings_mismatched(
            session, user_id, entry
        )
        if needs_repair:
            await repair_entry_speaker_bindings(session, user_id, entry)

    summaries = await build_speaker_summaries_for_entry(session, user_id, entry.id)
    if not summaries:
        return out
    return out.model_copy(
        update={
            "speaker_summaries": [
                SpeakerSummaryOut(
                    session_label=s.session_label,
                    speaker_profile_id=s.speaker_profile_id,
                    needs_confirmation=s.needs_confirmation,
                    confirmed_node=(
                        RecommendedNodeOut(
                            id=s.confirmed_node.id,
                            name=s.confirmed_node.name,
                        )
                        if s.confirmed_node is not None
                        else None
                    ),
                    suggested_node=(
                        RecommendedNodeOut(
                            id=s.suggested_node.id,
                            name=s.suggested_node.name,
                        )
                        if s.suggested_node is not None
                        else None
                    ),
                    auto_assigned=s.auto_assigned,
                )
                for s in summaries
            ]
        }
    )


@router.post("/upload", response_model=JournalEntryOut, status_code=status.HTTP_201_CREATED)
async def upload_journal(
    file: UploadFile = File(...),
    source_type: str | None = None,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    """Fast Path only: STT → cleanup/translate. GraphRAG is manual per entry."""
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty file")

    try:
        entry, _trace = await run_journal_fast_pipeline(
            session,
            user.id,
            data,
            file.filename or "recording.m4a",
            source_type=source_type,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Processing failed: {exc}") from exc

    await session.refresh(entry)
    return await _entry_out(session, user.id, entry)


@router.post("/entries", response_model=JournalEntryOut, status_code=status.HTTP_201_CREATED)
async def create_text_journal_entry(
    payload: JournalTextEntryRequest,
    background_tasks: BackgroundTasks,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    """Precision text path: user-labeled paragraph or dialogue."""
    try:
        if payload.paragraph_text and payload.paragraph_text.strip():
            entry, _trace = await run_journal_text_pipeline(
                session,
                user.id,
                paragraph_text=payload.paragraph_text.strip(),
                source_type=payload.source_type,
            )
        else:
            dialogue = [line.model_dump() for line in (payload.dialogue or [])]
            entry, _trace = await run_journal_text_pipeline(
                session, user.id, dialogue, source_type=payload.source_type
            )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Processing failed: {exc}") from exc

    await session.refresh(entry)
    return await _entry_out(session, user.id, entry)


@router.delete("/entries")
async def delete_all_entries(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Delete ALL of the user's journal entries, then GC orphaned voice profiles."""
    deleted = await crud.delete_all_journal_entries(session, user.id)
    await crud.sanitize_stale_voice_links(session, user.id)
    return {"deleted": deleted}


@router.delete("/entries/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_journal_entry(
    entry_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
):
    """Delete an entry and its cascaded data, then GC orphaned voice profiles."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    await crud.delete_journal_entry(session, entry)
    # Remove voice profiles/embeddings left with no node and no other entry.
    await crud.sanitize_stale_voice_links(session, user.id)


@router.post("/entries/{entry_id}/graph", response_model=GraphBuildOut)
async def build_entry_graph(
    entry_id: uuid.UUID,
    background_tasks: BackgroundTasks,
    force: bool = False,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphBuildOut:
    """Manually trigger GraphRAG slow path (batch background job)."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    if not entry.translation_en:
        raise HTTPException(status_code=400, detail="Entry not yet translated")

    from ..precision_text import is_precision_text_entry

    if not is_precision_text_entry(entry):
        pending = await unconfirmed_speaker_labels(session, user.id, entry_id)
        if pending:
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "speakers_unconfirmed",
                    "message": "화자 확인 후 GraphRAG를 실행할 수 있습니다.",
                    "pending_labels": pending,
                },
            )

    if entry.status == "graph_processing" and not force:
        return GraphBuildOut(
            entry_id=entry_id,
            status="graph_processing",
            message="GraphRAG build already in progress",
        )

    await crud.update_journal_entry(
        session,
        entry,
        graph_build_requested_at=datetime.now(UTC),
        status="graph_processing",
    )

    background_tasks.add_task(run_journal_slow_pipeline, entry_id, user.id)
    return GraphBuildOut(
        entry_id=entry_id,
        status="graph_processing",
        message="Semantic Chunk ingest 시작 (비동기)",
    )


@router.get("/entries", response_model=list[JournalEntryOut])
async def list_entries(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[JournalEntryOut]:
    entries = await crud.list_journal_entries(session, user.id)
    return [await _entry_out(session, user.id, e) for e in entries]


@router.get("/entries/{entry_id}", response_model=JournalEntryOut)
async def get_entry(
    entry_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> JournalEntryOut:
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    return await _entry_out(session, user.id, entry)


@router.post("/entries/{entry_id}/examples", response_model=ExamplesResponse)
async def generate_examples(
    entry_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> ExamplesResponse:
    """GraphRAG-backed personalized example sentences (5)."""
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    if not entry.translation_en:
        raise HTTPException(status_code=400, detail="Entry not yet translated")

    query = entry.translation_en[:200]
    rc = await hybrid_retrieve(session, query, user.id)
    raw = await generate_example_sentences(
        entry.translation_en,
        entry.transcript_clean_ko or entry.transcript_ko or "",
        rc.context,
    )
    examples = [ExampleSentence(**e) for e in raw]
    while len(examples) < 5:
        examples.append(ExampleSentence(en="(placeholder)", ko="", note=""))
    return ExamplesResponse(
        examples=examples[:5],
        graph_context_used=bool(rc.context.strip()),
        retrieval_preview=rc.context[:500] if rc.context else "",
    )


@router.post("/entries/{entry_id}/quiz/generate", response_model=QuizGenerateOut)
async def generate_quiz_item(
    entry_id: uuid.UUID,
    quiz_type: str = Query(..., description="cloze | scramble | mcq_nuance"),
    body: QuizGenerateRequest | None = None,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizGenerateOut:
    try:
        validate_quiz_type(quiz_type)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    try:
        quiz, trace = await run_quiz_generate_pipeline(
            session,
            user.id,
            quiz_type,
            entry_id=entry_id,
            is_freedom_on=body.is_freedom_on if body else None,
            selected_vocab_id=body.selected_vocab_id if body else None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return QuizGenerateOut(
        quiz_id=quiz.id,
        quiz_type=quiz.quiz_type,
        difficulty_level=quiz.difficulty_level,
        trace_step_count=len(trace.get("steps") or []),
    )


@router.post("/entries/{entry_id}/quiz", response_model=QuizResponse)
async def generate_quiz(
    entry_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> QuizResponse:
    entry = await crud.get_journal_entry(session, entry_id, user.id)
    if entry is None:
        raise HTTPException(status_code=404, detail="Entry not found")
    if not entry.translation_en:
        raise HTTPException(status_code=400, detail="Entry not yet translated")

    query = entry.translation_en[:200]
    rc = await hybrid_retrieve(session, query, user.id)
    cards_raw = await generate_quiz_cards(
        entry.translation_en,
        rc.context,
        premium=True,
    )
    cards = [QuizCard(**c) for c in cards_raw]
    return QuizResponse(cards=cards)


@router.get("/reviews", response_model=list[ReviewItemOut])
async def list_reviews(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[ReviewItemOut]:
    schedules = await crud.list_due_reviews(session, user.id)
    return [
        ReviewItemOut(
            journal_entry_id=s.journal_entry_id,
            next_review_at=s.next_review_at,
            interval_days=s.interval_days,
            repetitions=s.repetitions,
        )
        for s in schedules
    ]


@router.post("/reviews/{entry_id}/complete")
async def complete_review(
    entry_id: uuid.UUID,
    payload: ReviewResultRequest,
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
):
    from sqlalchemy import select

    from ..models import ReviewSchedule

    result = await session.execute(
        select(ReviewSchedule).where(
            ReviewSchedule.user_id == user.id,
            ReviewSchedule.journal_entry_id == entry_id,
        )
    )
    sched = result.scalar_one_or_none()
    if sched is None:
        raise HTTPException(status_code=404, detail="Review schedule not found")
    await crud.record_review_result(session, sched, payload.quality)
    return {"status": "ok"}


@router.get("/graph/summary", response_model=GraphSummaryOut)
async def graph_summary(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphSummaryOut:
    data = await crud.get_graph_summary(session, user.id)
    return GraphSummaryOut(**data)


@router.get("/speaker-profiles", response_model=list[SpeakerProfileOut])
async def list_speaker_profiles(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[SpeakerProfileOut]:
    """Voice memory profiles — linked to Person nodes after GraphRAG."""
    profiles = await crud.list_speaker_profiles(session, user.id)
    return profiles
