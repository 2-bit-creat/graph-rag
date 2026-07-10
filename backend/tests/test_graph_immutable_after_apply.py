"""2026-07-06 정책 변경: 커밋된(일기 provenance가 있는) 그래프도 지식그래프 화면에서
사후 수정할 수 있다 — 이름/타입 수정, 엣지 수정·추가 모두 허용되고 provenance 는
그대로 유지된다. (기존 "확정 후 불변" 게이트는 제거; 그래프 재커밋만 journal.py의
graph_locked 409 로 여전히 잠긴다 — test_entry_graph_draft_apply 참조.)
"""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app.models import Edge, JournalEntry, JournalGraphLink, Node
from app.routers.graph import add_edge, edit_edge, edit_node
from app.schemas import EdgeCreate, EdgeUpdate, NodeUpdate


async def _committed_graph(db_session, user_id):
    entry = JournalEntry(user_id=user_id, status="graph_ready")
    db_session.add(entry)
    await db_session.flush()
    speaker = Node(user_id=user_id, name="나", type="Person")
    concept = Node(user_id=user_id, name="말차", type="Concept")
    db_session.add_all([speaker, concept])
    await db_session.flush()
    edge = Edge(
        user_id=user_id, source_id=speaker.id, target_id=concept.id, relation="CONTEXT"
    )
    db_session.add(edge)
    await db_session.flush()
    db_session.add(JournalGraphLink(journal_entry_id=entry.id, node_id=speaker.id))
    db_session.add(
        JournalGraphLink(journal_entry_id=entry.id, node_id=concept.id, edge_id=edge.id)
    )
    await db_session.commit()
    return entry, speaker, concept, edge


@pytest.mark.asyncio
async def test_edit_node_allowed_after_commit_keeps_provenance(db_session, iso_user):
    entry, _, concept, _ = await _committed_graph(db_session, iso_user.id)
    out = await edit_node(concept.id, NodeUpdate(name="커피"), iso_user, db_session)
    assert out.name == "커피"

    # 일기 연결(provenance)은 수정 후에도 살아있다.
    rows = await db_session.execute(
        select(JournalGraphLink.node_id).where(
            JournalGraphLink.journal_entry_id == entry.id,
            JournalGraphLink.node_id == concept.id,
        )
    )
    assert rows.scalar_one_or_none() == concept.id


@pytest.mark.asyncio
async def test_edit_edge_allowed_after_commit(db_session, iso_user):
    _, _, _, edge = await _committed_graph(db_session, iso_user.id)
    out = await edit_edge(edge.id, EdgeUpdate(relation="RENAMED"), db_session)
    assert out.relation == "RENAMED"


@pytest.mark.asyncio
async def test_add_edge_allowed_between_committed_nodes(db_session, iso_user):
    _, speaker, concept, _ = await _committed_graph(db_session, iso_user.id)
    out = await add_edge(
        EdgeCreate(source_id=concept.id, target_id=speaker.id, relation="REL"),
        db_session,
    )
    assert out.relation == "REL"


@pytest.mark.asyncio
async def test_edit_allowed_for_non_journal_node(db_session, iso_user):
    """A node with no JournalGraphLink (e.g. dev-tool created) stays editable."""
    node = Node(user_id=iso_user.id, name="freeform", type="Concept")
    db_session.add(node)
    await db_session.commit()
    out = await edit_node(node.id, NodeUpdate(name="renamed"), iso_user, db_session)
    assert out.name == "renamed"
