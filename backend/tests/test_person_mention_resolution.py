"""Person-mention resolution at commit time.

A concept tagged kind="person" must resolve to a Person/self identity — linking to
an existing node (never forking a duplicate), creating a new Person node, or being
downgraded back to an ordinary Concept — with the mention attached via a MENTIONS
edge (concepts use CONTEXT). See app.routers.kg_build._persist_concept.
"""

from __future__ import annotations

import pytest

from app import crud
from app.models import JournalEntry, NodeAliasEmbedding
from app.routers.journal import apply_entry_graph
from app.routers.kg_build import _persist_claims
from app.schemas import GraphApplyRequest


def _unit_vec(dim: int = 1536, hot: int = 0) -> list[float]:
    """A 1536-d one-hot vector — lets us test cosine search without live embeddings."""
    v = [0.0] * dim
    v[hot] = 1.0
    return v


async def _fresh_entry(db_session, user_id) -> JournalEntry:
    entry = JournalEntry(
        user_id=user_id,
        status="graph_staging_ready",
        source_type="개인일기",
        transcript_clean_ko="테스트",
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)
    return entry


def _person_concept(name, action="new_person", node_id=None):
    res = {"action": action}
    if node_id is not None:
        res["node_id"] = str(node_id)
    return {"name": name, "importance": 3, "kind": "person", "resolution": res}


async def _apply(db_session, user, entry, concepts):
    payload = GraphApplyRequest(
        claims=[{
            "speaker": "나",
            "title": "제목",
            "statement": "어떤 진술",
            "concepts": concepts,
        }],
        context_type="개인일기",
    )
    return await apply_entry_graph(entry.id, payload, user, db_session)


async def _nodes_by_name(db_session, user_id):
    nodes = await crud.get_all_nodes(db_session, user_id)
    return {n.name: n for n in nodes if n.deleted_at is None}


async def _relations(db_session, user_id):
    """{(source_name, target_name): relation} for active nodes."""
    nodes = {n.id: n.name for n in await crud.get_all_nodes(db_session, user_id)}
    edges = await crud.get_all_edges(db_session, user_id)
    return {
        (nodes.get(e.source_id), nodes.get(e.target_id)): e.relation
        for e in edges
    }


@pytest.mark.asyncio
async def test_new_person_creates_person_node_with_mentions_edge(db_session, iso_user):
    entry = await _fresh_entry(db_session, iso_user.id)
    await _apply(db_session, iso_user, entry, [_person_concept("할머니")])

    nodes = await _nodes_by_name(db_session, iso_user.id)
    assert "할머니" in nodes
    # A brand-new mention becomes an Identity node (정체성 tier), never assumed
    # Person (could be a pet) and never a Concept.
    assert crud.is_identity_type(nodes["할머니"].type)
    assert crud.normalize_entity_type(nodes["할머니"].type) == "Identity"

    rels = await _relations(db_session, iso_user.id)
    assert rels.get(("제목", "할머니")) == "MENTIONS"


@pytest.mark.asyncio
async def test_link_to_existing_person_does_not_duplicate(db_session, iso_user):
    existing = await crud._get_or_create_node(
        db_session, name="제니", type_="Person", user_id=iso_user.id
    )
    await db_session.commit()

    entry = await _fresh_entry(db_session, iso_user.id)
    await _apply(
        db_session, iso_user, entry,
        [_person_concept("제니", action="link", node_id=existing.id)],
    )

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    jennys = [n for n in nodes if n.name == "제니" and n.deleted_at is None]
    assert len(jennys) == 1  # linked, not forked
    rels = await _relations(db_session, iso_user.id)
    assert rels.get(("제목", "제니")) == "MENTIONS"


@pytest.mark.asyncio
async def test_person_auto_resolves_by_name_without_resolution(db_session, iso_user):
    await crud._get_or_create_node(
        db_session, name="엄마", type_="Person", user_id=iso_user.id
    )
    await db_session.commit()

    entry = await _fresh_entry(db_session, iso_user.id)
    # kind=person but NO resolution decision (e.g. one-shot / unreviewed path).
    await _apply(
        db_session, iso_user, entry,
        [{"name": "엄마", "importance": 3, "kind": "person"}],
    )

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    moms = [n for n in nodes if n.name == "엄마" and n.deleted_at is None]
    assert len(moms) == 1


@pytest.mark.asyncio
async def test_downgrade_to_concept(db_session, iso_user):
    entry = await _fresh_entry(db_session, iso_user.id)
    await _apply(
        db_session, iso_user, entry,
        [_person_concept("사과", action="concept")],
    )

    nodes = await _nodes_by_name(db_session, iso_user.id)
    assert "사과" in nodes
    assert crud.normalize_entity_type(nodes["사과"].type) == "Concept"
    rels = await _relations(db_session, iso_user.id)
    assert rels.get(("제목", "사과")) == "CONTEXT"  # ordinary concept edge


@pytest.mark.asyncio
async def test_alias_registered_on_link_and_resolves_next_time(db_session, iso_user):
    node = await crud._get_or_create_node(
        db_session, name="제니", type_="Person", user_id=iso_user.id
    )
    assert crud.add_node_alias(node, "제니가") is True
    await db_session.commit()

    found = await crud.find_identity_node_by_name_or_alias(
        db_session, iso_user.id, "제니가"
    )
    assert found is not None and found.id == node.id
    # Idempotent + name-noop.
    assert crud.add_node_alias(node, "제니가") is False
    assert crud.add_node_alias(node, "제니") is False


@pytest.mark.asyncio
async def test_concept_kind_sticks_to_existing_identity(db_session, iso_user):
    """One promotion must hold forever: a name already resolved to an identity
    keeps converging there even when a later extraction tags it kind=concept."""
    ident = await crud._get_or_create_node(
        db_session, name="앤톡", type_="Identity", user_id=iso_user.id
    )
    base_importance = ident.importance_score or 0
    await db_session.commit()

    claims = [{
        "speaker": "나",
        "title": "앤톡 웹사이트 확인",
        "statement": "앤톡 웹사이트에서 화면을 찾았다",
        # LLM re-tagged it concept — no reviewer resolution attached.
        "concepts": [{"name": "앤톡", "importance": 4, "kind": "concept"}],
    }]
    await _persist_claims(db_session, iso_user.id, claims, "대화")
    await db_session.commit()

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    antoks = [n for n in nodes if n.name == "앤톡" and n.deleted_at is None]
    assert len(antoks) == 1                      # no Concept fork
    assert antoks[0].id == ident.id
    assert antoks[0].importance_score == base_importance + 4  # accumulates

    rels = await _relations(db_session, iso_user.id)
    assert rels.get(("앤톡 웹사이트 확인", "앤톡")) == "MENTIONS"


@pytest.mark.asyncio
async def test_explicit_concept_demotion_opts_out_of_stickiness(db_session, iso_user):
    """Reviewer's explicit '개념으로' decision beats the sticky identity check."""
    await crud._get_or_create_node(
        db_session, name="사과", type_="Identity", user_id=iso_user.id
    )
    await db_session.commit()

    claims = [{
        "speaker": "나",
        "title": "사과를 먹음",
        "statement": "사과를 먹었다",
        "concepts": [{
            "name": "사과", "importance": 2, "kind": "concept",
            "resolution": {"action": "concept"},
        }],
    }]
    await _persist_claims(db_session, iso_user.id, claims, "개인일기")
    await db_session.commit()

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    apples = [n for n in nodes if n.name == "사과" and n.deleted_at is None]
    assert len(apples) == 2  # Identity + explicit Concept coexist
    types = {crud.normalize_entity_type(n.type) for n in apples}
    assert types == {"Identity", "Concept"}
    rels = await _relations(db_session, iso_user.id)
    assert rels.get(("사과를 먹음", "사과")) == "CONTEXT"


@pytest.mark.asyncio
async def test_merge_repoints_journal_provenance(db_session, iso_user):
    """Merging a node must carry its 일기 연결(JournalGraphLink) to the target —
    the ON DELETE CASCADE would otherwise silently erase the timeline trace."""
    from app.models import JournalGraphLink

    entry = await _fresh_entry(db_session, iso_user.id)
    dup = await crud._get_or_create_node(
        db_session, name="앤톡중복", type_="Concept", user_id=iso_user.id
    )
    canonical = await crud._get_or_create_node(
        db_session, name="앤톡", type_="Identity", user_id=iso_user.id
    )
    db_session.add(JournalGraphLink(journal_entry_id=entry.id, node_id=dup.id))
    await db_session.commit()

    await crud.merge_node_into(db_session, iso_user.id, dup.id, canonical.id)
    await db_session.commit()

    from sqlalchemy import select as sa_select
    rows = await db_session.execute(
        sa_select(JournalGraphLink.node_id).where(
            JournalGraphLink.journal_entry_id == entry.id,
            JournalGraphLink.node_id.is_not(None),
        )
    )
    linked = {nid for (nid,) in rows.all()}
    assert canonical.id in linked   # provenance survived onto the target
    assert dup.id not in linked


@pytest.mark.asyncio
async def test_reclassify_refuses_merging_self_as_source(db_session, iso_user):
    from fastapi import HTTPException
    from app.routers.kg_build import ReclassifyNodeRequest, kg_reclassify_node

    self_node = await crud.get_or_create_self_node(db_session, iso_user.id)
    other = await crud._get_or_create_node(
        db_session, name="다른사람", type_="Person", user_id=iso_user.id
    )
    await db_session.commit()

    with pytest.raises(HTTPException) as exc:
        await kg_reclassify_node(
            self_node.id,
            ReclassifyNodeRequest(merge_into=other.id),
            iso_user,
            db_session,
        )
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_alias_embedding_search_and_gate(db_session, iso_user):
    """Fuzzy identity search: a near vector matches, an orthogonal one doesn't,
    and the cheap gate reflects index presence. (Uses one-hot vectors so no live
    embedding calls are needed.)"""
    assert not await crud.user_has_alias_embeddings(db_session, iso_user.id)

    node = await crud._get_or_create_node(
        db_session, name="장세영", type_="Person", user_id=iso_user.id
    )
    db_session.add(NodeAliasEmbedding(
        user_id=iso_user.id, node_id=node.id, text="장세영",
        embedding=_unit_vec(hot=0),
    ))
    await db_session.commit()

    assert await crud.user_has_alias_embeddings(db_session, iso_user.id)

    # Near-identical vector → match.
    near = _unit_vec(hot=0)
    near[1] = 0.05
    hit = await crud.find_identity_by_alias_embedding(db_session, iso_user.id, near)
    assert hit is not None and hit[0].id == node.id

    # Orthogonal vector (distance ~1) → no match under the 0.25 threshold.
    ortho = _unit_vec(hot=7)
    assert await crud.find_identity_by_alias_embedding(
        db_session, iso_user.id, ortho
    ) is None


@pytest.mark.asyncio
async def test_aliases_exposed_in_node_output(db_session, iso_user):
    """A learned alias (장세영→나) and its embedding-index count surface on the
    node so the inspector can show them."""
    self_node = await crud.get_or_create_self_node(db_session, iso_user.id)
    assert crud.add_node_alias(self_node, "장세영") is True
    db_session.add(NodeAliasEmbedding(
        user_id=iso_user.id, node_id=self_node.id, text="장세영",
        embedding=_unit_vec(hot=0),
    ))
    await db_session.commit()

    nodes = await crud.list_nodes_out(db_session, iso_user.id)
    self_out = next(n for n in nodes if n.id == self_node.id)
    assert "장세영" in self_out.aliases
    assert self_out.alias_embedding_count == 1


@pytest.mark.asyncio
async def test_speaker_head_reuses_and_promotes_identity(db_session, iso_user):
    # '엄마' first appears only as a mentioned Identity node.
    ident = await crud._get_or_create_node(
        db_session, name="엄마", type_="Identity", user_id=iso_user.id
    )
    await db_session.commit()

    # Now '엄마' is the SPEAKER of a statement (external multi-speaker path).
    claims = [{
        "speaker": "엄마",
        "speaker_type": "Person",
        "title": "엄마의 말",
        "statement": "엄마가 얘기했다",
        "concepts": [{"name": "대화", "importance": 2, "kind": "concept"}],
    }]
    await _persist_claims(db_session, iso_user.id, claims, "대화")
    await db_session.commit()

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    moms = [n for n in nodes if n.name == "엄마" and n.deleted_at is None]
    assert len(moms) == 1                       # reused, NOT forked into a Person
    assert moms[0].id == ident.id
    assert crud.is_person_like_type(moms[0].type)  # generic Identity promoted → Person

    rels = await _relations(db_session, iso_user.id)
    assert rels.get(("엄마", "엄마의 말")) == "SPOKE_OR_PUBLISHED"


@pytest.mark.asyncio
async def test_source_head_does_not_hijack_person_of_same_name(db_session, iso_user):
    # A human '뉴스' already exists (contrived name clash).
    person = await crud._get_or_create_node(
        db_session, name="뉴스", type_="Person", user_id=iso_user.id
    )
    await db_session.commit()

    # A Source head named '뉴스' must NOT reuse the Person — incompatible role.
    claims = [{
        "speaker": "뉴스",
        "speaker_type": "Source",
        "title": "속보",
        "statement": "속보가 전해졌다",
        "concepts": [{"name": "사건", "importance": 3, "kind": "concept"}],
    }]
    await _persist_claims(db_session, iso_user.id, claims, "뉴스")
    await db_session.commit()

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    newes = [n for n in nodes if n.name == "뉴스" and n.deleted_at is None]
    assert len(newes) == 2  # separate Person and Source identities
    types = {crud.normalize_entity_type(n.type) for n in newes}
    assert types == {"Person", "Source"}
    assert person.id in {n.id for n in newes}  # original Person untouched
