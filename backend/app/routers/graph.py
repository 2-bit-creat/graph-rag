import uuid



from fastapi import APIRouter, Depends, HTTPException, Query, status

from sqlalchemy.ext.asyncio import AsyncSession



from .. import crud

from ..agent import tools as agent_tools

from ..dev_user import dev_user_dep

from ..db import get_session

from ..models import User

from ..schemas import (

    EdgeCreate,

    EdgeOut,

    EdgeUpdate,

    GenerateRequest,

    GraphOut,

    NodeCreate,

    NodeOut,

    NodeUpdate,

    RecommendedNodeOut,

    SpeakerCandidateOut,

    SpeakerConfirmRequest,

    SpeakerConfirmResponse,

    SpeakerRecommendResponse,

    StagedEdge,

    StagedNode,

    StagingGraph,

)

from ..speaker_confirmation import confirm_speaker_identity, recommend_speaker_node



router = APIRouter(prefix="/graph", tags=["graph"])

v1_router = APIRouter(prefix="/api/v1/graphs", tags=["graph"])


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
            RecommendedNodeOut(id=n.id, name=n.name) for n in result.person_nodes
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

        ),

        transcript_replacements=result.transcript_replacements,

        edges_reassigned=result.edges_reassigned,

    )





@router.get("/speaker-recommend", response_model=SpeakerRecommendResponse)

async def speaker_recommend(

    journal_entry_id: uuid.UUID = Query(...),

    speaker_label: str = Query(..., min_length=1),

    user: User = Depends(dev_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerRecommendResponse:

    return await _speaker_recommend_handler(

        journal_entry_id, speaker_label, user, session

    )





@router.post("/speaker-confirm", response_model=SpeakerConfirmResponse)

async def speaker_confirm(

    payload: SpeakerConfirmRequest,

    user: User = Depends(dev_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerConfirmResponse:

    return await _speaker_confirm_handler(payload, user, session)





@v1_router.get("/speaker-recommend", response_model=SpeakerRecommendResponse)

async def speaker_recommend_v1(

    journal_entry_id: uuid.UUID = Query(...),

    speaker_label: str = Query(..., min_length=1),

    user: User = Depends(dev_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerRecommendResponse:

    return await _speaker_recommend_handler(

        journal_entry_id, speaker_label, user, session

    )





@v1_router.post("/speaker-confirm", response_model=SpeakerConfirmResponse)

async def speaker_confirm_v1(

    payload: SpeakerConfirmRequest,

    user: User = Depends(dev_user_dep),

    session: AsyncSession = Depends(get_session),

) -> SpeakerConfirmResponse:

    return await _speaker_confirm_handler(payload, user, session)





@router.get("/node-types")
async def graph_node_types(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    """Dynamic node types from DB (GROUP BY) for open-domain UI filters."""
    return await crud.get_dynamic_node_types(session, user.id)


@v1_router.get("/node-types")
async def graph_node_types_v1(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    return await crud.get_dynamic_node_types(session, user.id)


@router.get("", response_model=GraphOut)
async def read_graph(
    user: User = Depends(dev_user_dep),
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
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> NodeOut:
    node = await crud.get_node_out(session, node_id, user.id)
    if node is None:
        raise HTTPException(status_code=404, detail="node not found")
    return node


@router.delete("", status_code=status.HTTP_200_OK)
async def clear_graph(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Wipe the user's entire knowledge graph (nodes, edges, chunks, links)."""
    try:
        stats = await crud.clear_user_knowledge_graph(session, user.id)
        return {"ok": True, **stats}
    except Exception as exc:
        await session.rollback()
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@v1_router.delete("", status_code=status.HTTP_200_OK)
async def clear_graph_v1(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    return await clear_graph(user=user, session=session)


@router.post("/generate", response_model=StagingGraph)

async def generate(

    payload: GenerateRequest, session: AsyncSession = Depends(get_session)

) -> StagingGraph:

    """Extract an ontology-based graph proposal (staging). Does NOT persist."""

    return await agent_tools.generate_graph(session, payload.messages)





@router.post("/apply", response_model=GraphOut)

async def apply(

    payload: StagingGraph, session: AsyncSession = Depends(get_session)

) -> GraphOut:

    await crud.apply_staged_graph(session, payload.nodes, payload.edges)

    nodes = await crud.get_all_nodes(session)

    edges = await crud.get_all_edges(session)

    return GraphOut(nodes=nodes, edges=edges)





@router.post("/edges", response_model=EdgeOut, status_code=status.HTTP_201_CREATED)

async def add_edge(

    payload: EdgeCreate, session: AsyncSession = Depends(get_session)

) -> EdgeOut:

    edge = await crud.create_edge(

        session, payload.source_id, payload.target_id, payload.relation

    )

    if edge is None:

        raise HTTPException(status_code=404, detail="source or target node not found")

    return edge





@router.patch("/edges/{edge_id}", response_model=EdgeOut)

async def edit_edge(

    edge_id: uuid.UUID,

    payload: EdgeUpdate,

    session: AsyncSession = Depends(get_session),

) -> EdgeOut:

    edge = await crud.update_edge(

        session,

        edge_id,

        relation=payload.relation,

        source_id=payload.source_id,

        target_id=payload.target_id,

    )

    if edge is None:

        raise HTTPException(status_code=404, detail="edge not found")

    return edge





@router.delete("/edges/{edge_id}", status_code=status.HTTP_204_NO_CONTENT)

async def remove_edge(

    edge_id: uuid.UUID, session: AsyncSession = Depends(get_session)

) -> None:

    deleted = await crud.delete_edge(session, edge_id)

    if not deleted:

        raise HTTPException(status_code=404, detail="edge not found")





@router.post("/nodes", response_model=NodeOut, status_code=status.HTTP_201_CREATED)
async def add_node(
    payload: NodeCreate,
    user: User = Depends(dev_user_dep),
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
    out = await crud.get_node_out(session, node.id, user.id)
    if out is None:
        raise HTTPException(status_code=404, detail="node not found")
    return out


@router.patch("/nodes/{node_id}", response_model=NodeOut)

async def edit_node(

    node_id: uuid.UUID,

    payload: NodeUpdate,

    user: User = Depends(dev_user_dep),

    session: AsyncSession = Depends(get_session),

) -> NodeOut:

    node = await crud.update_node(

        session, node_id, payload.name, payload.type, payload.description

    )

    if node is None:

        raise HTTPException(status_code=404, detail="node not found")

    out = await crud.get_node_out(session, node_id, user.id)
    if out is None:
        raise HTTPException(status_code=404, detail="node not found")
    return out





@router.delete("/nodes/{node_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_node(
    node_id: uuid.UUID, session: AsyncSession = Depends(get_session)
) -> None:
    deleted = await crud.delete_node(session, node_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="node not found")


@router.get("/nodes/{node_id}/deletion-impact")
async def get_deletion_impact(
    node_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
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
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Soft-delete a Statement node and cascade to orphaned neighbors, quizzes, and expressions."""
    result = await crud.soft_delete_statement_cascade(session, node_id, user.id)
    if not result:
        raise HTTPException(status_code=404, detail="node not found")
    return result


@router.get("/trash")
async def list_trash(
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Return all soft-deleted Statement nodes (trash bin)."""
    from ..schemas import NodeOut
    nodes = await crud.get_trash_nodes(session, user.id)
    return {"nodes": [NodeOut.model_validate(n).model_dump(mode="json") for n in nodes]}


@router.post("/trash/{node_id}/restore")
async def restore_from_trash(
    node_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
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
    user: User = Depends(dev_user_dep),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Permanently delete a node from trash."""
    ok = await crud.purge_trash_node(session, node_id, user.id)
    if not ok:
        raise HTTPException(status_code=404, detail="node not found in trash")


@router.get("/nodes/{node_id}/expressions")
async def get_node_expressions(
    node_id: uuid.UUID,
    user: User = Depends(dev_user_dep),
) -> dict:
    """Return all extracted language expressions for a Statement node, grouped by language."""
    from ..node_expression_store import get_node_expressions_all_languages
    data = await get_node_expressions_all_languages(user.id, str(node_id))
    return {"node_id": str(node_id), "expressions_by_language": data}


@router.post("/admin/backfill-journal-links")
async def backfill_journal_links(
    user: User = Depends(dev_user_dep),
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
    user: User = Depends(dev_user_dep),
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
    user: User = Depends(dev_user_dep),
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

