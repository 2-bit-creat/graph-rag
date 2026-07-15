"""_enrich_person_concepts Pass 1 (EXACT) homonym safety.

Exercises app.routers.kg_build._enrich_person_concepts directly rather than
going through the /apply endpoint (test_person_mention_resolution.py's `_apply`
helper is broken against the current apply_entry_graph signature — a pre-
existing, unrelated issue). A single exact/whitespace-only name match still
auto-links; anything ambiguous (2+ candidates, or only a title/honorific-
stripped match) must downgrade to a reviewer suggestion instead of silently
merging two different people.
"""

from __future__ import annotations

import pytest

from app import crud
from app.routers.kg_build import _enrich_person_concepts


def _claims(name: str) -> list[dict]:
    return [{"concepts": [{"name": name, "importance": 3, "kind": "person"}]}]


@pytest.mark.asyncio
async def test_single_exact_match_still_auto_links(db_session, iso_user):
    node = await crud._get_or_create_node(
        db_session, name="김철수", type_="Person", user_id=iso_user.id
    )
    await db_session.commit()

    claims = _claims("김철수")
    await _enrich_person_concepts(db_session, iso_user.id, claims)

    res = claims[0]["concepts"][0]["resolution"]
    assert res["action"] == "link"
    assert res["node_id"] == str(node.id)


@pytest.mark.asyncio
async def test_whitespace_only_variant_still_auto_links(db_session, iso_user):
    """The bug from the real transcript: '하승목 연구원' (mention text) vs
    '하승목연구원' (stored node name) differ only by spacing — must still link,
    not fall back to fuzzy/suggest."""
    node = await crud._get_or_create_node(
        db_session, name="하승목연구원", type_="Person", user_id=iso_user.id
    )
    await db_session.commit()

    claims = _claims("하승목 연구원")
    await _enrich_person_concepts(db_session, iso_user.id, claims)

    res = claims[0]["concepts"][0]["resolution"]
    assert res["action"] == "link"
    assert res["node_id"] == str(node.id)


@pytest.mark.asyncio
async def test_two_candidates_downgrades_to_suggest(db_session, iso_user):
    """Two distinct people share the same base name → homonym risk, must NOT
    silently auto-merge."""
    a = await crud._get_or_create_node(
        db_session, name="김철수", type_="Person", user_id=iso_user.id
    )
    b = await crud._get_or_create_node(
        db_session, name="김철수", type_="Identity", user_id=iso_user.id
    )
    await db_session.commit()

    claims = _claims("김철수")
    await _enrich_person_concepts(db_session, iso_user.id, claims)

    res = claims[0]["concepts"][0]["resolution"]
    assert res["action"] == "suggest"
    assert res["node_id"] in {str(a.id), str(b.id)}


@pytest.mark.asyncio
async def test_title_only_match_downgrades_to_suggest(db_session, iso_user):
    """Mention carries a title/honorific the stored node doesn't ('김철수부장'
    vs '김철수') — base names agree but surface forms don't, so this is treated
    as ambiguous rather than auto-linked."""
    node = await crud._get_or_create_node(
        db_session, name="김철수", type_="Person", user_id=iso_user.id
    )
    await db_session.commit()

    claims = _claims("김철수부장")
    await _enrich_person_concepts(db_session, iso_user.id, claims)

    res = claims[0]["concepts"][0]["resolution"]
    assert res["action"] == "suggest"
    assert res["node_id"] == str(node.id)


@pytest.mark.asyncio
async def test_no_candidates_falls_through_to_fuzzy_pass(db_session, iso_user):
    """No base-name match at all → Pass 1 leaves it unresolved for Pass 2
    (embedding fuzzy suggest), unchanged behavior."""
    claims = _claims("완전히새로운이름")
    await _enrich_person_concepts(db_session, iso_user.id, claims)

    concept = claims[0]["concepts"][0]
    # No identity at all and no alias embeddings indexed yet → Pass 2 is a
    # no-op (user_has_alias_embeddings is False), so it stays unresolved.
    assert "resolution" not in concept
