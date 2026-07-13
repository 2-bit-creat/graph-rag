"""Traced quiz generation pipeline — graph-based with optional journal entry scope."""

from __future__ import annotations

import asyncio
import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from . import crud
from .level_guidelines import cefr_label, window_for_level
from .models import Quiz, User
from .pipeline_flow import build_flow_layout
from .pipeline_trace import PipelineTracer
from .quiz_generator import (
    generate_one,
    generate_vocab_cloze_from_context,
    validate_quiz_payload,
)
from .quiz_graph_selector import select_quiz_subgraph, select_quiz_subgraph_from_graph
from .quiz_audio_engine import resolve_quiz_tts_text, synthesize_quiz_audio
from .quiz_settings import quiz_selection_settings
from .quiz_types import validate_quiz_type

logger = logging.getLogger(__name__)


def _statement_source_node_ids(statement_expr: dict | None) -> set[uuid.UUID]:
    """Collect the graph node id(s) a statement expression was extracted from.

    Reads the representative ``source_node_id`` plus every ``origins[].node_id`` so a
    lemma shared across several Statement nodes anchors on all of them. Non-UUID or
    empty values are skipped.
    """
    if not statement_expr:
        return set()
    raw_ids: list[str] = []
    primary = statement_expr.get("source_node_id")
    if primary:
        raw_ids.append(str(primary))
    for origin in statement_expr.get("origins") or []:
        if isinstance(origin, dict) and origin.get("node_id"):
            raw_ids.append(str(origin["node_id"]))
    resolved: set[uuid.UUID] = set()
    for rid in raw_ids:
        try:
            resolved.add(uuid.UUID(rid))
        except (ValueError, AttributeError, TypeError):
            continue
    return resolved


def _merge_quiz_trace_into_entry(entry_trace: dict | None, quiz_trace: dict) -> dict:
    """Append quiz_path steps to an existing journal entry trace for canvas display."""
    merged = dict(entry_trace or {})
    quiz_steps = [
        s for s in (quiz_trace.get("steps") or []) if s.get("phase") == "quiz_path"
    ]
    existing = [
        s for s in (merged.get("steps") or []) if s.get("phase") != "quiz_path"
    ]
    merged["steps"] = existing + quiz_steps
    merged["current_phase"] = quiz_trace.get("current_phase", "quiz_path")
    merged["status"] = quiz_trace.get("status", "quiz_path")
    merged["flow_layout"] = build_flow_layout(merged["steps"])
    return merged


async def _run_vocab_node_quiz_pipeline(
    session: AsyncSession,
    user_id: uuid.UUID,
    quiz_type: str,
    *,
    vocab_node_id: uuid.UUID,
    premium: bool = True,
    is_freedom_on: bool | None = None,
) -> tuple[Quiz, dict]:
    """Generate quiz from a Vocab node via Semantic Chunk chain RAG."""
    from .graph_generation import resolve_vocab_quiz_context

    if quiz_type != "cloze":
        raise ValueError("vocab_node_id quiz generation supports cloze only")

    user = await session.get(User, user_id)
    if user is None:
        raise ValueError("User not found")

    tracer = PipelineTracer(vocab_node_id)
    tracer.run.current_phase = "quiz_path"
    tracer.run.status = "quiz_path"
    target_level = user.current_level
    effective_freedom = is_freedom_on if is_freedom_on is not None else user.is_freedom_on

    step = tracer.begin_step(
        "graph_context_resolve",
        "graph",
        phase="quiz_path",
        input_data={"vocab_node_id": str(vocab_node_id)},
    )
    try:
        ctx = await resolve_vocab_quiz_context(session, user_id, vocab_node_id)
    except ValueError as exc:
        tracer.finish_step(step, error=str(exc))
        raise
    tracer.finish_step(
        step,
        output={
            "vocab_lemma": ctx.vocab_lemma,
            "anchor_chunk_id": str(ctx.anchor_chunk_id),
            "speaker_name": ctx.speaker_name,
            "context_turns": len(ctx.context_before) + 1 + len(ctx.context_after),
            "formatted_dialogue_preview": ctx.formatted_dialogue[:500],
        },
        artifacts=[("dialogue_context.txt", ctx.formatted_dialogue, "text/plain")],
    )

    step = tracer.begin_step(
        "quiz_llm_generate",
        "llm",
        phase="quiz_path",
        input_data={"quiz_type": quiz_type, "vocab_lemma": ctx.vocab_lemma},
    )
    generated = await generate_vocab_cloze_from_context(
        ctx,
        target_level=target_level,
        freedom_off=not effective_freedom,
    )
    model = generated.pop("_model", None)
    system_prompt = generated.pop("_system_prompt", None)
    raw_llm = generated.pop("_raw_llm", {})
    step.model = model
    step.system_prompt = system_prompt
    tracer.finish_step(step, output={"quiz_type": quiz_type}, artifacts=[("output.json", raw_llm, "application/json")])

    validated = validate_quiz_payload(
        quiz_type,
        {**generated, "quiz_data": generated["quiz_data"]},
        target_level=target_level,
    )

    quiz = await crud.create_quiz(
        session,
        user_id=user_id,
        quiz_type=quiz_type,
        question_ko=validated["question_ko"],
        sentence_en=validated["sentence_en"],
        quiz_data=validated["quiz_data"],
        difficulty_level=validated["difficulty_level"],
        queue_kind="new",
        source_nodes=[vocab_node_id, ctx.anchor_chunk_id],
        debug_run_dir=tracer.debug_dir_relative,
    )

    tts_text = resolve_quiz_tts_text(quiz_type, validated)
    audio_url, tts_error = await synthesize_quiz_audio(quiz.id, tts_text, language="english")
    if audio_url:
        qd = dict(validated["quiz_data"])
        qd["audio_url"] = audio_url
        quiz.quiz_data = qd

    trace_data = tracer._persist()
    quiz.pipeline_trace = trace_data
    await session.commit()
    await session.refresh(quiz)
    return quiz, trace_data


async def run_quiz_generate_pipeline(
    session: AsyncSession,
    user_id: uuid.UUID,
    quiz_type: str,
    *,
    premium: bool = True,
    entry_id: uuid.UUID | None = None,
    selected_vocab_id: str | None = None,
    vocab_node_id: uuid.UUID | None = None,
    target_language: str | None = None,
    # Legacy param — ignored, kept for call-site compat
    is_freedom_on: bool | None = None,
) -> tuple[Quiz, dict]:
    """Generate a quiz from the knowledge graph; trace stored on the quiz row."""
    quiz_type = validate_quiz_type(quiz_type)

    if vocab_node_id is not None:
        return await _run_vocab_node_quiz_pipeline(
            session,
            user_id,
            quiz_type,
            vocab_node_id=vocab_node_id,
            premium=premium,
            is_freedom_on=is_freedom_on,
        )

    user = await session.get(User, user_id)
    if user is None:
        raise ValueError("User not found")

    translation_en = ""
    transcript_clean_ko = ""
    source = "graph"
    entry = None
    if entry_id is not None:
        entry = await crud.get_journal_entry(session, entry_id, user_id)
        if entry is None:
            raise ValueError("Entry not found")
        translation_en = entry.translation_en or ""
        transcript_clean_ko = entry.transcript_clean_ko or ""
        if translation_en:
            source = "journal"

    run_id = entry_id or uuid.uuid4()
    tracer = PipelineTracer(run_id)
    tracer.run.current_phase = "quiz_path"
    tracer.run.status = "quiz_path"

    # ── Vocab-based mode: selected_vocab_id determines behavior ─────────────
    # statement_bank:* → use graph-extracted expression (old "freedom OFF")
    # default:* or user vocab → use CEFR random seed (old "freedom ON")
    # The legacy entry endpoint now defaults to graph statements. External
    # vocabulary pools are no longer valid quiz seeds.
    selected_vocab = "graph"
    # legacy "default" → english
    if selected_vocab == "default":
        selected_vocab = "default:english"

    from .crud import get_effective_target_languages, get_language_level

    # Derive language: from vocab_id prefix > caller override > user default
    def _lang_from_vocab(vid: str) -> str | None:
        if vid.startswith("statement_bank:"):
            return vid.split(":", 1)[1]
        if vid.startswith("default:"):
            return vid.split(":", 1)[1]
        return None

    vocab_lang = _lang_from_vocab(selected_vocab)
    available_langs = get_effective_target_languages(user)
    if vocab_lang and vocab_lang.lower() in [l.lower() for l in available_langs]:
        lang = vocab_lang.lower()
    elif target_language and target_language.lower() in [l.lower() for l in available_langs]:
        lang = target_language.lower()
    else:
        lang = available_langs[0]

    target_level = get_language_level(user, lang)
    use_statement_bank = selected_vocab.startswith("statement_bank:")
    # For tracing we keep this name; effectively replaces old is_freedom_on
    effective_freedom = False if selected_vocab == "graph" else not use_statement_bank

    # Pick expression (statement bank mode) or vocab seed (default/custom mode)
    statement_expr: dict | None = None
    vocab_seed = None

    if use_statement_bank:
        from .node_expression_store import pick_random_expression_for_quiz
        statement_expr = await pick_random_expression_for_quiz(user_id, lang, target_level=target_level)
    elif selected_vocab == "graph":
        # No external vocabulary fallback: use the entry/graph selector below.
        vocab_seed = None
    else:
        from .user_vocab_store import VocabularyNotFoundError, get_vocab_seed
        try:
            vocab_seed = await get_vocab_seed(user_id, selected_vocab, target_level, language=lang)
        except VocabularyNotFoundError as exc:
            raise ValueError(str(exc)) from exc
        except ValueError as exc:
            raise ValueError(str(exc)) from exc

    lo, hi = window_for_level(target_level)
    settings_snapshot = quiz_selection_settings(target_level)

    step = tracer.begin_step(
        "quiz_manual_trigger",
        "policy",
        phase="quiz_path",
        input_data={
            "quiz_type": quiz_type,
            "source": "journal_entry" if entry_id else "knowledge_graph",
            "entry_id": str(entry_id) if entry_id else None,
        },
    )
    tracer.finish_step(
        step,
        output={
            "trigger": "manual",
            "quiz_type": quiz_type,
            "graph_based": True,
            "entry_id": str(entry_id) if entry_id else None,
        },
    )

    step = tracer.begin_step(
        "quiz_level_load",
        "policy",
        phase="quiz_path",
        input_data={
            "user_id": str(user_id),
            "settings": settings_snapshot,
            "level_window": [lo, hi],
        },
    )
    tracer.finish_step(
        step,
        output={
            "current_level": target_level,
            "target_level": target_level,
            "is_freedom_on": effective_freedom,
            "selected_vocab_id": selected_vocab,
            "vocab_seed": vocab_seed,
            "cefr_label": cefr_label(target_level),
            "level_window": [lo, hi],
        },
        artifacts=[(
            "level.json",
            {
                "current_level": target_level,
                "is_freedom_on": effective_freedom,
                "selected_vocab_id": selected_vocab,
                "vocab_seed": vocab_seed,
                **settings_snapshot,
            },
            "application/json",
        )],
    )

    step = tracer.begin_step(
        "quiz_source_fetch",
        "graph",
        phase="quiz_path",
        input_data={
            "settings": settings_snapshot,
            "source": "journal_entry" if entry_id else "knowledge_graph",
            "entry_id": str(entry_id) if entry_id else None,
        },
    )
    if entry_id is not None:
        selection = await select_quiz_subgraph(
            session, user_id, entry_id, translation_en
        )
    else:
        # In statement-bank mode, anchor the subgraph on the node(s) the chosen
        # expression was extracted from so the LLM sees the context where the
        # expression actually appeared — not a random slice of the graph.
        #
        # In freedom mode (IELTS / default pool / custom vocab) the seed word has no
        # linked node, so pass the word itself as a semantic query: the background
        # nodes woven into the sentence are then thematically adjacent to the word
        # rather than just the most recent ones.
        stmt_seed_ids = _statement_source_node_ids(statement_expr)
        vocab_query = ""
        if not stmt_seed_ids and vocab_seed:
            vocab_query = str(vocab_seed.get("word") or "").strip()
        selection = await select_quiz_subgraph_from_graph(
            session,
            user_id,
            seed_node_ids=stmt_seed_ids or None,
            query=vocab_query,
        )
    graph_context = selection.context_text
    tracer.finish_step(
        step,
        output={
            "seed_count": len(selection.seed_nodes),
            "seed_nodes": selection.seed_nodes,
            "candidate_count": selection.candidate_count,
            "selected_nodes": selection.selected_nodes,
            "selected_edges": selection.selected_edges,
            "pick_breakdown": selection.pick_breakdown,
            "graph_context_length": len(graph_context),
        },
        artifacts=[
            ("selection_settings.json", selection.settings, "application/json"),
            ("seed_nodes.json", selection.seed_nodes, "application/json"),
            ("selected_subgraph.json", {
                "nodes": selection.selected_nodes,
                "edges": selection.selected_edges,
                "pick_breakdown": selection.pick_breakdown,
            }, "application/json"),
            ("graph_context.txt", graph_context, "text/plain"),
        ],
    )

    # When Freedom OFF and a statement expression exists, augment context with it.
    effective_graph_context = graph_context
    if not effective_freedom and statement_expr:
        stmt_note = (
            f"\n[TARGET EXPRESSION for this quiz]\n"
            f"expression: {statement_expr['expression']}\n"
            f"meaning: {statement_expr.get('meaning', '')}\n"
            f"source_node: {statement_expr.get('source_node_id', '')}\n"
        )
        effective_graph_context = graph_context + stmt_note

    step = tracer.begin_step(
        "quiz_llm_generate",
        "llm",
        phase="quiz_path",
        input_data={
            "quiz_type": quiz_type,
            "target_level": target_level,
            "is_freedom_on": effective_freedom,
            "selected_vocab_id": selected_vocab,
            "vocab_seed": vocab_seed,
            "statement_expr": statement_expr,
            "source": source,
            "entry_id": str(entry_id) if entry_id else None,
        },
    )
    generated = await generate_one(
        translation_en=translation_en,
        transcript_clean_ko=transcript_clean_ko,
        graph_context=effective_graph_context,
        quiz_type=quiz_type,
        target_level=target_level,
        premium=premium,
        source=source,
        is_freedom_on=effective_freedom,
        vocab_seed=vocab_seed,
        statement_expression=statement_expr,
        native_language=getattr(user, "native_language", None) or "korean",
        target_language=lang,
    )
    model = generated.pop("_model", None)
    system_prompt = generated.pop("_system_prompt", None)
    raw_llm = generated.pop("_raw_llm", {})
    generated.pop("_vocab_seed", None)
    generated.pop("_is_freedom_on", None)
    judge_verdict = generated.pop("_judge", {"ok": True, "reason": ""})
    step.model = model
    step.system_prompt = system_prompt
    tracer.finish_step(
        step,
        output={
            "difficulty_level": generated["difficulty_level"],
            "quiz_type": quiz_type,
            "is_freedom_on": effective_freedom,
            "selected_vocab_id": selected_vocab,
            "vocab_seed": vocab_seed,
            "quality_judge": judge_verdict,
        },
        artifacts=[("output.json", raw_llm, "application/json")],
    )

    step = tracer.begin_step(
        "quiz_validate",
        "policy",
        phase="quiz_path",
        input_data={"quiz_type": quiz_type},
    )
    validated = validate_quiz_payload(
        quiz_type,
        {**generated, "quiz_data": generated["quiz_data"]},
        freedom_seed=(
            vocab_seed["word"] if effective_freedom and vocab_seed
            else statement_expr["expression"] if not effective_freedom and statement_expr
            else None
        ),
        target_level=target_level,
        target_language=lang,
    )
    tracer.finish_step(
        step,
        output={"valid": True, "difficulty_level": validated["difficulty_level"]},
        artifacts=[("validated.json", validated, "application/json")],
    )

    # Stamp provenance onto the quiz so the UI can show which vocab source it came
    # from (statement bank / default pool / custom list) and so sessions can filter
    # by source. Stored inside quiz_data (JSONB) to avoid a schema migration.
    if use_statement_bank:
        source_mode = "statement"
    elif selected_vocab.startswith("default:"):
        source_mode = "default"
    elif selected_vocab == "graph":
        source_mode = "graph"
    else:
        source_mode = "custom"
    source_meta: dict = {
        "vocab_id": selected_vocab,
        "mode": source_mode,
        "language": lang,
    }
    if use_statement_bank and statement_expr:
        source_meta["expression"] = statement_expr.get("expression")
        source_meta["source_node_id"] = statement_expr.get("source_node_id")
    elif vocab_seed:
        source_meta["seed_word"] = vocab_seed.get("word")
        source_meta["cefr"] = vocab_seed.get("cefr")
    quiz_data_out = dict(validated["quiz_data"])
    quiz_data_out["_source"] = source_meta
    validated["quiz_data"] = quiz_data_out

    step = tracer.begin_step(
        "quiz_enqueue_new",
        "storage",
        phase="quiz_path",
        input_data={"quiz_type": quiz_type, "queue_kind": "new"},
    )
    quiz = await crud.create_quiz(
        session,
        user_id=user_id,
        quiz_type=quiz_type,
        associated_entry_id=entry_id,
        question_ko=validated["question_ko"],
        sentence_en=validated["sentence_en"],
        quiz_data=validated["quiz_data"],
        difficulty_level=validated["difficulty_level"],
        queue_kind="new",
        source_nodes=selection.source_node_ids or None,
        debug_run_dir=tracer.debug_dir_relative,
    )
    tracer.finish_step(
        step,
        output={"quiz_id": str(quiz.id), "difficulty_level": quiz.difficulty_level},
        artifacts=[("quiz_row.json", crud.quiz_to_dict(quiz), "application/json")],
    )

    tts_text = resolve_quiz_tts_text(quiz_type, validated)
    step = tracer.begin_step(
        "quiz_audio_tts",
        "api",
        phase="quiz_path",
        input_data={
            "quiz_id": str(quiz.id),
            "sentence_en": tts_text,
            "raw_sentence_en": validated.get("sentence_en"),
        },
    )
    audio_url, tts_error = await synthesize_quiz_audio(quiz.id, tts_text, language=lang)
    if audio_url:
        qd = dict(validated["quiz_data"])
        qd["audio_url"] = audio_url
        quiz.quiz_data = qd
    tracer.finish_step(
        step,
        output={
            "audio_url": audio_url,
            "available": audio_url is not None,
            "tts_text": tts_text,
        },
        error=tts_error,
        artifacts=[(
            "audio_meta.json",
            {"audio_url": audio_url, "error": tts_error, "tts_text": tts_text},
            "application/json",
        )],
    )

    trace_data = tracer._persist()
    quiz.pipeline_trace = trace_data
    await session.commit()
    await session.refresh(quiz)

    if entry is not None:
        merged = _merge_quiz_trace_into_entry(entry.pipeline_trace, trace_data)
        await crud.update_journal_entry(session, entry, pipeline_trace=merged)

    return quiz, trace_data


async def trace_quiz_queue_pick(
    session: AsyncSession,
    quiz_id: uuid.UUID,
    user_id: uuid.UUID,
    quiz_type: str,
    picked: list[Quiz],
    *,
    level: int,
    window: tuple[int, int],
) -> dict:
    """Append quiz_queue_pick step to quiz generation trace."""
    quiz = await crud.get_quiz(session, quiz_id, user_id)
    if quiz is None or not quiz.pipeline_trace:
        return {}
    tracer = PipelineTracer(quiz_id, resume=quiz.pipeline_trace)
    step = tracer.begin_step(
        "quiz_queue_pick",
        "policy",
        phase="quiz_path",
        input_data={
            "quiz_type": quiz_type,
            "level": level,
            "window": list(window),
        },
    )
    new_n = sum(1 for q in picked if q.queue_kind == "new")
    tracer.finish_step(
        step,
        output={
            "picked_count": len(picked),
            "new_count": new_n,
            "review_count": len(picked) - new_n,
            "picked_ids": [str(q.id) for q in picked],
        },
    )
    trace_data = tracer._persist()
    quiz.pipeline_trace = trace_data
    await session.commit()
    return trace_data


async def trace_quiz_sm2_update(
    session: AsyncSession,
    quiz_id: uuid.UUID,
    user_id: uuid.UUID,
    quiz: Quiz,
    *,
    correct: bool,
    quality: int,
) -> dict:
    """Append quiz_sm2_update step to quiz generation trace."""
    base = await crud.get_quiz(session, quiz_id, user_id)
    if base is None or not base.pipeline_trace:
        return {}
    tracer = PipelineTracer(quiz_id, resume=base.pipeline_trace)
    step = tracer.begin_step(
        "quiz_sm2_update",
        "policy",
        phase="quiz_path",
        input_data={"quiz_id": str(quiz.id), "correct": correct},
    )
    tracer.finish_step(
        step,
        output={
            "quality": quality,
            "correct": correct,
            "next_review_at": quiz.next_review_at.isoformat() if quiz.next_review_at else None,
            "queue_kind": quiz.queue_kind,
            "repetitions": quiz.repetitions,
            "interval_days": quiz.interval_days,
        },
    )
    trace_data = tracer._persist()
    base.pipeline_trace = trace_data
    await session.commit()
    return trace_data
