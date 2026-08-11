import logging
import uuid



from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession



from .. import crud

from ..deps import request_user_dep

from ..db import get_session

from ..models import Node, User

from ..schemas import (

    EdgeCreate,

    EdgeOut,

    EdgeUpdate,

    GraphOut,

    NodeCreate,

    NodeOut,

    NodeUpdate,

    RecommendedNodeOut,

    SpeakerCandidateOut,

    SpeakerConfirmRequest,

    SpeakerConfirmResponse,

    SpeakerRecommendResponse,

)

from ..speaker_confirmation import confirm_speaker_identity, recommend_speaker_node



logger = logging.getLogger(__name__)

router = APIRouter(prefix="/graph", tags=["graph"])

v1_router = APIRouter(prefix="/api/v1/graphs", tags=["graph"])


async def _schedule_statement_learning(
    background: BackgroundTasks,
    session: AsyncSession,
    user: User,
    node_id: uuid.UUID,
    *,
    priority: int = 0,
) -> None:
    languages = crud.get_effective_target_languages(user)
    from ..quiz_materials import analyse_nodes_and_refill_background

    background.add_task(
        analyse_nodes_and_refill_background,
        user.id,
        [node_id],
        languages,
        priority=priority,
    )


# 2026-07-06 정책 변경: 확정 그래프도 지식그래프 화면에서 사후 수정(이름·타입·설명,
# 병합, 엣지 추가) 가능. 일기 provenance는 편집 시 그대로 유지되고 병합 시 대상
# 노드로 승계된다. 초기 "확정 후 불변" 게이트(_graph_locked_error)는 제거됨 —
# 그래프 재생성(draft→apply 재커밋)만 여전히 잠긴다 (journal.py의 graph_locked).





async def _speaker_recommend_handler(

    journal_entry_id: uuid.UUID,

    speaker_label: str,

    user: User,

    session: AsyncSession,

) -> SpeakerRecommendResponse:

    try:

        result = await recommend_speaker_node(

            session,

            user.id,

            journal_entry_id,

            speaker_label,

        )

    except ValueError as exc:

        raise HTTPException(status_code=404, detail=str(exc)) from exc



    recommended = None

    if result.recommended_node is not None:

        recommended = RecommendedNodeOut(

            id=result.recommended_node.id,

            name=result.recommended_node.name,

            type=result.recommended_node.type,

        )

    return SpeakerRecommendResponse(

        recommended_node=recommended,

        match_score=result.match_score,

        speaker_profile_id=result.speaker_profile_id,

        session_speaker_label=result.session_speaker_label,

        already_confirmed=result.already_confirmed,

        confirmed_node=(
            RecommendedNodeOut(
                id=result.confirmed_node.id,
                name=result.confirmed_node.name,
                type=result.confirmed_node.type,
            )
            if result.confirmed_node is not None
            else None
        ),

        above_threshold=result.above_threshold,

        likely_unregistered=result.likely_unregistered,

        session_conflict_hint=result.session_conflict_hint,

        candidates=[
            SpeakerCandidateOut(id=c.id, name=c.name, match_score=c.match_score)
            for c in result.candidates
        ],

        person_nodes=[
            RecommendedNodeOut(id=n.id, name=n.name, type=n.type)
            for n in result.person_nodes
        ],

    )





async def _speaker_confirm_handler(

    payload: SpeakerConfirmRequest,

    user: User,

    session: AsyncSession,

) -> SpeakerConfirmResponse:

    # Speaker identity is a structural input to the graph — once it's committed
    # for this entry, lock confirmation so we don't desync the built graph.
    if await crud.entry_has_graph_nodes(session, payload.journal_entry_id):

        raise HTTPException(

            status_code=409,

            detail={

                "code": "graph_locked",

                "message": "지식그래프가 생성되어 화자는 잠겼습니다. "
                "수정하려면 그래프를 삭제 후 다시 생성하세요.",

            },

        )

    try:

        result = await confirm_speaker_identity(

            session,

            user.id,

            payload.journal_entry_id,

            payload.speaker_profile_id,

            node_id=payload.node_id,

            new_node_name=payload.new_node_name,

            wrong_name=payload.wrong_name,

            session_label=payload.session_label,

            as_self=payload.as_self,

            as_source=payload.as_source,

        )

    except ValueError as exc:

        msg = str(exc)

        code = 404 if "not found" in msg else 400

        raise HTTPException(status_code=code, detail=msg) from exc



    return SpeakerConfirmResponse(

        speaker_profile_id=result.speaker_profile_id,

        confirmed_node=RecommendedNodeOut(

            id=result.confirmed_node.id,

            name=result.confirmed_node.name,

            type=result.confirmed_node.type,

        ),

        transcript_replacements=result.transcript_replacements,

        edges_reassigned=result.edges_reassigned,

    )





@router.get("/speaker-recommend", response_model=SpeakerRecommendResponse)

async def speaker_recommend(

    journal_entry_id: uuid.UUID = Query(...),

    speaker_label: str = Query(..., min_length=1),

    user: User = Depends(request_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerRecommendResponse:

    return await _speaker_recommend_handler(

        journal_entry_id, speaker_label, user, session

    )





@router.post("/speaker-confirm", response_model=SpeakerConfirmResponse)

async def speaker_confirm(

    payload: SpeakerConfirmRequest,

    user: User = Depends(request_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerConfirmResponse:

    return await _speaker_confirm_handler(payload, user, session)





@v1_router.get("/speaker-recommend", response_model=SpeakerRecommendResponse)

async def speaker_recommend_v1(

    journal_entry_id: uuid.UUID = Query(...),

    speaker_label: str = Query(..., min_length=1),

    user: User = Depends(request_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerRecommendResponse:

    return await _speaker_recommend_handler(

        journal_entry_id, speaker_label, user, session

    )





@v1_router.post("/speaker-confirm", response_model=SpeakerConfirmResponse)

async def speaker_confirm_v1(

    payload: SpeakerConfirmRequest,

    user: User = Depends(request_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerConfirmResponse:

    return await _speaker_confirm_handler(payload, user, session)





@router.get("/node-types")
async def graph_node_types(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    """Dynamic node types from DB (GROUP BY) for open-domain UI filters."""
    return await crud.get_dynamic_node_types(session, user.id)


@v1_router.get("/node-types")
async def graph_node_types_v1(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    return await crud.get_dynamic_node_types(session, user.id)


@router.get("", response_model=GraphOut)
async def read_graph(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> GraphOut:
    nodes = await crud.list_nodes_out(session, user.id)
    edges = await crud.get_all_edges(session, user_id=user.id)
    if await crud.deduplicate_node_type_casing(session, user.id):
        await session.commit()
        nodes = await crud.list_nodes_out(session, user.id)

    return GraphOut(nodes=nodes, edges=edges)


@router.get("/nodes/{node_id}", response_model=NodeOut)
async def read_node(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> NodeOut:
    node = await crud.get_node_out(session, node_id, user.id)
    if node is None:
        raise HTTPException(status_code=404, detail="node not found")
    return node


@router.get("/nodes/{node_id}/study-quizzes")
async def read_node_study_quizzes(
    node_id: uuid.UUID,
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Return node quizzes and prioritise material analysis when none exist."""
    from ..models import Quiz

    node = await session.get(Node, node_id)
    if node is None or node.user_id != user.id:
        raise HTTPException(status_code=404, detail="node not found")
    if node.type.lower() != "statement":
        raise HTTPException(status_code=400, detail="only Statement nodes have study quizzes")

    rows = await session.execute(
        select(Quiz.id, Quiz.quiz_type, Quiz.language, Quiz.queue_kind)
        .where(
            Quiz.user_id == user.id,
            Quiz.source_nodes.contains([node_id]),
            Quiz.quiz_type.in_(("cloze", "composition")),
            Quiz.queue_kind.in_(("new", "review")),
        )
        .order_by(Quiz.created_at.desc())
    )
    grouped = {"cloze": [], "composition": []}
    reviews = {"cloze": 0, "composition": 0}
    by_language = {"cloze": {}, "composition": {}}
    for quiz_id, quiz_type, language, queue_kind in rows.all():
        kind = str(quiz_type)
        quiz_id_str = str(quiz_id)
        lang = (str(language).strip().lower() if language else "english")
        grouped[kind].append(quiz_id_str)
        by_language[kind].setdefault(lang, []).append(quiz_id_str)
        if queue_kind == "review":
            reviews[kind] += 1
    from ..models import QuizLearningMaterial

    languages = crud.get_effective_target_languages(user)
    material_rows = (
        await session.scalars(
            select(QuizLearningMaterial).where(
                QuizLearningMaterial.user_id == user.id,
                QuizLearningMaterial.node_id == node_id,
                QuizLearningMaterial.language.in_(languages),
            )
        )
    ).all()
    material_status = {row.language: row.status for row in material_rows}
    from ..node_expression_store import get_node_expressions

    expression_by_language: dict[str, dict[str, int]] = {}
    for language in languages:
        expressions = await get_node_expressions(user.id, str(node_id), language)
        expression_by_language[language] = {
            "total": len(expressions),
            "available": sum(
                str(item.get("quiz_status") or "available") == "available"
                for item in expressions
            ),
            "generated": sum(
                str(item.get("quiz_status") or "available") == "emitted"
                for item in expressions
            ),
        }

    from ..models import QuizGenerationRun

    recent_runs = (
        await session.scalars(
            select(QuizGenerationRun)
            .where(
                QuizGenerationRun.user_id == user.id,
                QuizGenerationRun.source.in_(("node_selected", "regeneration")),
            )
            .order_by(QuizGenerationRun.created_at.desc())
            .limit(20)
        )
    ).all()
    active_run = next(
        (
            run for run in recent_runs
            if str(node_id) in (run.node_ids or [])
            and run.status in {"queued", "running"}
        ),
        None,
    )
    # A Statement edited after generation is left archived-and-empty on purpose;
    # only the learner's 재생성 press rebuilds it, so auto-analysis stays off here.
    needs_regeneration = any(row.status == "stale" for row in material_rows)
    if not grouped["cloze"] and not grouped["composition"] and not needs_regeneration:
        if any(material_status.get(language) not in {"ready", "analyzing"} for language in languages):
            await _schedule_statement_learning(
                background, session, user, node_id, priority=100
            )
    return {
        "node_id": str(node_id),
        "material_status": material_status,
        "expressions": {
            "count": sum(value["total"] for value in expression_by_language.values()),
            "available_count": sum(value["available"] for value in expression_by_language.values()),
            "generated_count": sum(value["generated"] for value in expression_by_language.values()),
            "by_language": expression_by_language,
        },
        "generation": (
            {"run_id": str(active_run.id), "status": active_run.status}
            if active_run is not None
            else {"run_id": None, "status": "idle"}
        ),
        "needs_regeneration": needs_regeneration,
        "word": {
            "count": len(grouped["cloze"]),
            "review_count": reviews["cloze"],
            "quiz_ids": grouped["cloze"],
            "by_language": by_language["cloze"],
        },
        "composition": {
            "count": len(grouped["composition"]),
            "review_count": reviews["composition"],
            "quiz_ids": grouped["composition"],
            "by_language": by_language["composition"],
        },
    }


@router.post("/nodes/{node_id}/study-quizzes/generate")
async def generate_node_study_quizzes(
    node_id: uuid.UUID,
    background: BackgroundTasks,
    language: str | None = None,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Generate the next small, high-quality set for a selected Statement.

    This is a learner action, not the operator generation hub.  It reuses a
    ready expression inventory, emits at most three new cloze cards, and is
    durable so the graph card can show progress without holding the request.
    """
    node = await session.get(Node, node_id)
    if node is None or node.user_id != user.id or node.type.lower() != "statement":
        raise HTTPException(status_code=404, detail="Statement node not found")
    languages = crud.get_effective_target_languages(user)
    if language:
        requested = language.strip().lower()
        if requested not in {value.lower() for value in languages}:
            raise HTTPException(status_code=400, detail="Inactive target language")
        languages = [requested]

    from ..models import QuizGenerationRun
    from ..quiz_generation_runs import create_generation_run, process_generation_run

    active = (
        await session.scalars(
            select(QuizGenerationRun)
            .where(
                QuizGenerationRun.user_id == user.id,
                QuizGenerationRun.source == "node_selected",
                QuizGenerationRun.status.in_(("queued", "running")),
            )
            .order_by(QuizGenerationRun.created_at.desc())
            .limit(20)
        )
    ).all()
    existing = next(
        (run for run in active if str(node_id) in (run.node_ids or [])), None
    )
    if existing is not None:
        return {"run_id": str(existing.id), "status": existing.status}

    run, created = await create_generation_run(
        session,
        user,
        node_ids=[node_id],
        languages=languages,
        idempotency_key=f"node-study:{node_id}:{uuid.uuid4()}",
        source="node_selected",
    )
    if created:
        background.add_task(process_generation_run, run.id)
    return {"run_id": str(run.id), "status": run.status}


@router.post("/nodes/{node_id}/regenerate-quizzes")
async def regenerate_node_quizzes(
    node_id: uuid.UUID,
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Rebuild a Statement's learning material after its content was edited."""
    node = await session.get(Node, node_id)
    if node is None or node.user_id != user.id:
        raise HTTPException(status_code=404, detail="node not found")
    if node.type.lower() != "statement":
        raise HTTPException(
            status_code=400, detail="only Statement nodes have study quizzes"
        )
    from ..quiz_bundle import BundleSeedError
    from ..quiz_materials import archive_edited_statement_materials

    # An edit archives eagerly, but running this again is harmless and repairs
    # material left behind by an edit that failed to archive at the time.
    try:
        archived = await archive_edited_statement_materials(
            session, user, node_id=node_id
        )
    except BundleSeedError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    # An explicit rebuild always goes through a generation run so the learner
    # gets the complete set (composition + expression clozes), not just the
    # analysis half that the auto-generation-off path would produce.
    from ..quiz_generation_runs import create_generation_run, process_generation_run

    run, created = await create_generation_run(
        session,
        user,
        node_ids=[node_id],
        languages=crud.get_effective_target_languages(user),
        idempotency_key=f"regenerate:{node_id}:{uuid.uuid4()}",
        source="regeneration",
    )
    if created:
        background.add_task(process_generation_run, run.id)
    return {
        "node_id": str(node_id),
        "status": "scheduled",
        "run_id": str(run.id),
        "archived_quiz_count": archived["archived_quiz_count"],
    }


@router.delete("", status_code=status.HTTP_200_OK)
async def clear_graph(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Wipe the user's entire knowledge graph (nodes, edges, chunks, links)."""
    try:
        stats = await crud.clear_user_knowledge_graph(session, user.id)
        return {"ok": True, **stats}
    except Exception as exc:
        await session.rollback()
        logger.exception("Failed to clear knowledge graph for user %s", user.id)
        raise HTTPException(status_code=500, detail="Failed to clear graph") from exc


@v1_router.delete("", status_code=status.HTTP_200_OK)
async def clear_graph_v1(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    return await clear_graph(user=user, session=session)



@router.post("/edges", response_model=EdgeOut, status_code=status.HTTP_201_CREATED)

async def add_edge(

    payload: EdgeCreate,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),

) -> EdgeOut:

    edge = await crud.create_edge(

        session, payload.source_id, payload.target_id, payload.relation,
        user_id=user.id,

    )

    if edge is None:

        raise HTTPException(status_code=404, detail="source or target node not found")

    return edge





@router.patch("/edges/{edge_id}", response_model=EdgeOut)

async def edit_edge(

    edge_id: uuid.UUID,

    payload: EdgeUpdate,

    user: User = Depends(request_user_dep),

    session: AsyncSession = Depends(get_session),

) -> EdgeOut:

    edge = await crud.update_edge(

        session,

        edge_id,

        relation=payload.relation,

        source_id=payload.source_id,

        target_id=payload.target_id,

        user_id=user.id,

    )

    if edge is None:

        raise HTTPException(status_code=404, detail="edge not found")

    return edge





@router.delete("/edges/{edge_id}", status_code=status.HTTP_204_NO_CONTENT)

async def remove_edge(

    edge_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),

) -> None:

    deleted = await crud.delete_edge(session, edge_id, user_id=user.id)

    if not deleted:

        raise HTTPException(status_code=404, detail="edge not found")





@router.post("/nodes", response_model=NodeOut, status_code=status.HTTP_201_CREATED)
async def add_node(
    payload: NodeCreate,
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> NodeOut:
    """Manually add a node from the KG edit surface (dedupes by name+type).

    Identity-category nodes get their name embedding-indexed so they participate
    in fuzzy mention resolution immediately.
    """
    name = (payload.name or "").strip()
    if not name:
        raise HTTPException(status_code=422, detail="이름이 필요합니다.")
    node = await crud.upsert_typed_node(
        session, user.id, name, payload.type, payload.description
    )
    await crud.index_identity_alias(session, user.id, node, name)
    await session.commit()
    if node.type == "Statement":
        from ..graph_retrieval import statement_content

        if len(statement_content(node).strip()) >= 6:
            await _schedule_statement_learning(background, session, user, node.id)
    out = await crud.get_node_out(session, node.id, user.id)
    if out is None:
        raise HTTPException(status_code=404, detail="node not found")
    return out


@router.patch("/nodes/{node_id}", response_model=NodeOut)
async def edit_node(
    node_id: uuid.UUID,
    payload: NodeUpdate,
    background: BackgroundTasks,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> NodeOut:
    existing = await session.get(Node, node_id)
    # Ownership is checked before anything is written. The trailing get_node_out
    # is user-scoped and would 404, but only after the mutation had committed.
    if existing is None or existing.user_id != user.id:
        raise HTTPException(status_code=404, detail="node not found")

    before = (existing.name, existing.type, existing.description)

    # An event-date correction is its own retained change (see
    # apply_manual_event_date), independent of any text edit in the same PATCH.
    if payload.occurred_at is not None:
        from ..config import get_settings
        from ..temporal_backfill import apply_manual_event_date

        apply_manual_event_date(
            session,
            existing,
            payload.occurred_at,
            timezone_name=get_settings().chat_timezone,
        )
        await session.commit()

    node = await crud.update_node(
        session, node_id, payload.name, payload.type, payload.description
    )
    if node is None:
        raise HTTPException(status_code=404, detail="node not found")

    changed = before != (node.name, node.type, node.description)
    # Source text is the contract for every derived expression and quiz.  A text
    # edit therefore has one simple lifecycle: retire the old derivatives,
    # clear their expression inventory, and analyse the new source automatically.
    was_statement = str(before[1] or "").lower() == "statement"
    is_statement = str(node.type or "").lower() == "statement"
    if changed and (was_statement or is_statement):
        from ..quiz_bundle import BundleSeedError
        from ..quiz_materials import retire_statement_derivatives

        try:
            await retire_statement_derivatives(session, user, node_id=node.id)
        except BundleSeedError:
            pass
        if is_statement:
            from ..graph_retrieval import statement_content

            if len(statement_content(node).strip()) >= 6:
                await _schedule_statement_learning(
                    background, session, user, node.id, priority=100
                )

    out = await crud.get_node_out(session, node_id, user.id)
    if out is None:
        raise HTTPException(status_code=404, detail="node not found")
    return out





@router.delete("/nodes/{node_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_node(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> None:
    deleted = await crud.delete_node(session, node_id, owner_id=user.id)
    if not deleted:
        raise HTTPException(status_code=404, detail="node not found")


@router.get("/nodes/{node_id}/deletion-impact")
async def get_deletion_impact(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Preview counts of what will be deleted when this node is removed."""
    from sqlalchemy import func, select as sa_select, or_
    from ..models import Edge, Quiz, Node as _Node
    from ..node_expression_store import get_node_expressions_all_languages

    node = await session.get(_Node, node_id)
    if node is None or node.user_id != user.id:
        raise HTTPException(status_code=404, detail="node not found")

    # Edge count
    edge_result = await session.execute(
        sa_select(func.count()).select_from(Edge).where(
            or_(Edge.source_id == node_id, Edge.target_id == node_id)
        )
    )
    edge_count = edge_result.scalar_one()

    # Find neighbor node IDs
    neighbor_result = await session.execute(
        sa_select(Edge.source_id, Edge.target_id).where(
            or_(Edge.source_id == node_id, Edge.target_id == node_id)
        )
    )
    neighbor_ids: set[uuid.UUID] = set()
    for row in neighbor_result:
        nid = row.target_id if row.source_id == node_id else row.source_id
        neighbor_ids.add(nid)

    # Count orphan neighbors (nodes that would become isolated)
    orphan_count = 0
    for nid in neighbor_ids:
        other_edges = await session.execute(
            sa_select(func.count()).select_from(Edge).where(
                or_(Edge.source_id == nid, Edge.target_id == nid),
                Edge.source_id != node_id,
                Edge.target_id != node_id,
            )
        )
        if other_edges.scalar_one() == 0:
            orphan_count += 1

    # Quiz count — use raw SQL for UUID array containment
    quiz_result = await session.execute(
        sa_select(func.count()).select_from(Quiz).where(
            Quiz.user_id == user.id,
            Quiz.source_nodes.contains([node_id]),
        )
    )
    quiz_count = quiz_result.scalar_one()

    # Expression count (across all languages)
    exprs = await get_node_expressions_all_languages(user.id, str(node_id))
    expr_count = sum(len(v) for v in exprs.values())

    return {
        "edge_count": edge_count,
        "orphan_node_count": orphan_count,
        "quiz_count": quiz_count,
        "expression_count": expr_count,
    }


@router.delete("/nodes/{node_id}/cascade")
async def remove_node_cascade(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Soft-delete a Statement node and cascade to orphaned neighbors, quizzes, and expressions."""
    result = await crud.soft_delete_statement_cascade(session, node_id, user.id)
    if not result:
        raise HTTPException(status_code=404, detail="node not found")
    return result


@router.get("/trash")
async def list_trash(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Return all soft-deleted Statement nodes (trash bin)."""
    from ..schemas import NodeOut
    nodes = await crud.get_trash_nodes(session, user.id)
    return {"nodes": [NodeOut.model_validate(n).model_dump(mode="json") for n in nodes]}


@router.post("/trash/{node_id}/restore")
async def restore_from_trash(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Restore a soft-deleted Statement node from trash."""
    ok = await crud.restore_statement_from_trash(session, node_id, user.id)
    if not ok:
        raise HTTPException(status_code=404, detail="node not in trash")
    return {"restored": str(node_id)}


@router.delete("/trash/{node_id}/purge", status_code=status.HTTP_204_NO_CONTENT)
async def purge_from_trash(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Permanently delete a node from trash."""
    ok = await crud.purge_trash_node(session, node_id, user.id)
    if not ok:
        raise HTTPException(status_code=404, detail="node not found in trash")


@router.get("/nodes/{node_id}/expressions")
async def get_node_expressions(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
) -> dict:
    """Return all extracted language expressions for a Statement node, grouped by language."""
    from ..node_expression_store import get_node_expressions_all_languages
    data = await get_node_expressions_all_languages(user.id, str(node_id))
    return {"node_id": str(node_id), "expressions_by_language": data}


@router.post("/admin/backfill-journal-links")
async def backfill_journal_links(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """One-time backfill: create JournalGraphLink entries for nodes that lack them,
    using Quiz.source_nodes → Quiz.associated_entry_id as provenance."""
    from sqlalchemy import text

    result = await session.execute(text("""
        INSERT INTO journal_graph_links (journal_entry_id, node_id)
        SELECT DISTINCT q.associated_entry_id, n.node_id
        FROM quizzes q
        CROSS JOIN LATERAL unnest(q.source_nodes) AS n(node_id)
        WHERE q.source_nodes IS NOT NULL
          AND q.associated_entry_id IS NOT NULL
          AND q.user_id = :user_id
          AND NOT EXISTS (
              SELECT 1 FROM journal_graph_links jgl
              WHERE jgl.journal_entry_id = q.associated_entry_id
                AND jgl.node_id = n.node_id
          )
    """), {"user_id": user.id})
    await session.commit()
    return {"inserted": result.rowcount}


@router.post("/admin/cleanup-orphan-speaker-profiles")
async def cleanup_orphan_speaker_profiles(
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Clear display_name on SpeakerProfiles whose linked node was deleted."""
    from sqlalchemy import update as sa_update, select
    from ..models import SpeakerProfile as _SP, Node as _N

    # Profiles pointing to non-existent (or deleted) nodes
    result = await session.execute(
        sa_update(_SP)
        .where(
            _SP.user_id == user.id,
            _SP.node_id.is_not(None),
            ~_SP.node_id.in_(
                select(_N.id).where(_N.user_id == user.id, _N.deleted_at.is_(None))
            ),
        )
        .values(node_id=None, display_name=None)
    )
    await session.commit()
    return {"cleared": result.rowcount}


@router.delete("/nodes/{node_id}/voice-link", response_model=NodeOut)
async def unlink_node_voice(
    node_id: uuid.UUID,
    user: User = Depends(request_user_dep),
    session: AsyncSession = Depends(get_session),
) -> NodeOut:
    """Remove voice embedding link from a Speaker graph node."""
    node = await crud.unlink_voice_from_node(session, user.id, node_id)
    if node is None:
        raise HTTPException(status_code=404, detail="node not found")
    out = await crud.get_node_out(session, node_id, user.id)
    if out is None:
        raise HTTPException(status_code=404, detail="node not found")
    return out
