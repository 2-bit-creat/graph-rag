"""Placeholder concepts never reach the graph.

Extraction asks for 1–5 concepts and the response schema enforces minItems=1
(the 2026-07-03 concept-loss guard), so a claim whose real subject was named in
an earlier claim leaves the model nothing to comply with except a referring
phrase — "결국 두 방법을 모두 적용하기로 했다" yielded a permanent "두 방법" node.
The prompt now asks for the referent; this is the net under it.
"""

from app.routers.kg_build import _drop_referring_concepts


def _claim(*names: str) -> dict:
    return {
        "statement": "...",
        "concepts": [{"name": n, "importance": 3, "kind": "concept"} for n in names],
    }


def test_drops_the_placeholder_and_keeps_the_real_concept():
    claims = [_claim("두 방법", "밴드")]

    removed = _drop_referring_concepts(claims)

    assert removed == 1
    assert [c["name"] for c in claims[0]["concepts"]] == ["밴드"]


def test_empties_a_claim_that_carries_nothing_else():
    # "결국 둘 다 넣기로 했다" has no concept of its own. Leaving the placeholder
    # in was the actual observed bug: it committed a permanent "둘 다" node.
    # _persist_claims still writes the Statement and its speaker edge.
    claims = [_claim("둘 다")]

    removed = _drop_referring_concepts(claims)

    assert removed == 1
    assert claims[0]["concepts"] == []


def test_leaves_ordinary_concepts_alone():
    claims = [_claim("비교기업 분석", "DCF", "할인율")]

    assert _drop_referring_concepts(claims) == 0
    assert len(claims[0]["concepts"]) == 3


def test_matches_ignoring_case_and_padding():
    claims = [_claim("  That  ", "DCF")]

    assert _drop_referring_concepts(claims) == 1
    assert [c["name"] for c in claims[0]["concepts"]] == ["DCF"]


def test_realigns_positional_matched_flags():
    claim = _claim("두 방법", "밴드", "그것")
    claim["concepts_matched"] = [False, True, False]

    _drop_referring_concepts([claim])

    # The flag must still describe 밴드, not slide onto another name.
    assert [c["name"] for c in claim["concepts"]] == ["밴드"]
    assert claim["concepts_matched"] == [True]


def test_tolerates_malformed_claims():
    claims = [{"concepts": None}, {}, {"concepts": ["not a dict"]}, "not a claim"]

    assert _drop_referring_concepts(claims) == 0
