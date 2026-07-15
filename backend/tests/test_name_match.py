"""Pure-function tests for deterministic identity-mention scanning — no DB."""

from __future__ import annotations

import uuid

from app.models import Node
from app.name_match import base_name_key, norm_compact, scan_identity_mentions, strip_title


def _identity(name: str, aliases: list[str] | None = None, type_: str = "Identity") -> Node:
    return Node(id=uuid.uuid4(), name=name, type=type_, aliases=aliases or [])


def test_norm_compact_strips_all_whitespace_and_lowers():
    assert norm_compact("하승목 연구원") == "하승목연구원"
    assert norm_compact("  Kim   Tae Yeon ") == "kimtaeyeon"


def test_strip_title_removes_known_suffix_when_base_long_enough():
    assert strip_title("하승목연구원") == "하승목"
    assert strip_title("김태연상무") == "김태연"
    # No known suffix -> untouched.
    assert strip_title("하승목") == "하승목"


def test_base_name_key_ignores_spacing_and_title():
    assert base_name_key("하승목 연구원") == base_name_key("하승목연구원") == "하승목"


def test_scan_matches_whitespace_variant():
    node = _identity("하승목연구원")
    matches = scan_identity_mentions(
        "하승목 연구원이 어떤 질문을 했었지? 성장성 모형 관련해서", [node]
    )
    assert len(matches) == 1
    assert matches[0].node.id == node.id


def test_scan_matches_exact_compact_form():
    node = _identity("하승목연구원")
    matches = scan_identity_mentions("하승목연구원이 물어봤어", [node])
    assert len(matches) == 1


def test_scan_respects_alias():
    node = _identity("김태연상무님", aliases=["태연상무"])
    matches = scan_identity_mentions("태연상무가 그랬어", [node])
    assert len(matches) == 1
    assert matches[0].node.id == node.id


def test_scan_excludes_stoplist_self_pronoun():
    node = _identity("나", type_="Identity")
    matches = scan_identity_mentions("나는 오늘 산책했다", [node])
    assert matches == []


def test_scan_excludes_single_char_name():
    node = _identity("민")
    matches = scan_identity_mentions("민이 뭐라고 했어?", [node])
    assert matches == []


def test_scan_word_boundary_avoids_substring_false_positive():
    node = _identity("민수")
    matches = scan_identity_mentions("민수기라는 책을 읽었다", [node])
    assert matches == []


def test_scan_no_match_for_unrelated_message():
    node = _identity("하승목연구원")
    matches = scan_identity_mentions("오늘 날씨가 좋다", [node])
    assert matches == []


def test_scan_picks_longer_overlapping_span():
    a = _identity("김철수")
    b = _identity("김철수부장")
    matches = scan_identity_mentions("김철수부장이 발표했다", [a, b])
    assert len(matches) == 1
    assert matches[0].node.id == b.id


def test_scan_multiple_distinct_speakers():
    a = _identity("하승목연구원")
    b = _identity("김태연상무님")
    matches = scan_identity_mentions(
        "하승목 연구원이 김태연 상무님한테 물어봤어", [a, b]
    )
    ids = {m.node.id for m in matches}
    assert ids == {a.id, b.id}
