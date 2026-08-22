"""외부 출처(Source) 귀속: 붙여넣은 소스 자료의 진술 head는 Person이 아닌
is_source=True Identity 노드가 된다.

Source는 더 이상 별도의 저장 type이 아니다 — head node의 type은 항상
"Identity"이고, `is_source` 플래그가 매체·기관·책·AI 출처를 구분한다
(entity_types.py 참고).

- Source는 person-like가 아니므로 동명의 Person과 병합되지 않는다 — 그래도
  둘 다 화자 피커에는 노출된다: 정체성 전체(is_source 여부와 무관하게)가
  화자가 될 수 있다는 것이 이 그래프 모델의 핵심 컨셉이다.
- 리뷰 클라이언트가 claims에서 speaker_type을 떨어뜨려도, 엔트리의
  attribution_kind='source'에서 head의 is_source 플래그가 복원된다
  (Person 오염 방지).
- content-type 게이트: 출처 귀속 텍스트는 단일 화자여도 개인일기가 될 수 없다.
"""

from __future__ import annotations

import pytest
from fastapi import BackgroundTasks

from app import crud
from app.entity_types import (
    identity_merge_group,
    identity_types_compatible,
    is_source_like_type,
    resolve_is_source,
)
from app.journal_pipeline import DIARY_CATEGORY, gate_source_type
from app.models import JournalEntry
from app.routers.journal import apply_entry_graph
from app.routers.kg_build import _claim_head_type
from app.schemas import GraphApplyRequest


@pytest.fixture(autouse=True)
def _disable_llm_learning_materials(monkeypatch):
    """Source-attribution tests cover graph types, not LLM-backed quiz generation."""

    async def _noop(*_args, **_kwargs):
        return None

    monkeypatch.setattr(
        "app.quiz_materials.analyse_nodes_and_refill_background", _noop
    )


# ─── Pure helpers ──────────────────────────────────────────────────────────────

def test_source_never_merges_with_a_plain_identity():
    """is_source is its own merge bucket — a same-name Identity must not absorb it."""
    assert is_source_like_type("Source")
    assert is_source_like_type("media")
    assert not is_source_like_type("Identity")

    assert identity_merge_group(True) != identity_merge_group(False)
    assert not identity_types_compatible(True, False)
    assert identity_types_compatible(False, False)
    # Legacy rows on an un-migrated graph share the (non-source) Identity bucket.
    assert identity_types_compatible(resolve_is_source("Person"), False)
    assert not identity_types_compatible(resolve_is_source("Person"), True)


@pytest.mark.parametrize(
    "raw,expected",
    [
        # head type is always "Identity" now — Source is a flag, not a type.
        ("Source", "Identity"),
        ("source", "Identity"),
        ("Identity", "Identity"),
        (None, "Identity"),
        ("", "Identity"),
        ("Concept", "Identity"),
        ("Statement", "Identity"),
        # legacy wire values from stored drafts / older clients
        ("Person", "Identity"),
        ("Speaker", "Identity"),
    ],
)
def test_claim_head_type_sanitized(raw, expected):
    assert _claim_head_type(raw) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("Source", True),
        ("source", True),
        ("media", True),
        ("Identity", False),
        ("Person", False),
        ("Concept", False),
        (None, False),
        ("", False),
    ],
)
def test_claim_head_is_source_resolved(raw, expected):
    assert resolve_is_source(raw) is expected


@pytest.mark.parametrize(
    "content_type,single,expected",
    [
        # 출처 귀속이면 일기 분류는 불가능 — 정리된 지식(자료)으로 폴백.
        ("일기", True, "자료"),
        ("개인일기", True, "자료"),
        ("", True, "자료"),
        (None, True, "자료"),
        ("책", True, "자료"),         # 산문 catch-all도 출처 귀속이면 자료
        # 특정 매체(뉴스/논문/강연)만 유지 — 실제 붙여넣은 기사·논문·강연.
        ("뉴스", True, "뉴스"),
        ("강연", True, "강연"),
        ("논문", True, "논문"),
        # 붙여넣은 대화/회의록도 실제 대화가 아니라 참고 자료 → 자료.
        ("대화", True, "자료"),
        ("회의록", False, "자료"),
        ("일기", False, "자료"),
    ],
)
def test_gate_source_attributed(content_type, single, expected):
    assert (
        gate_source_type(content_type, single_speaker=single, source_attributed=True)
        == expected
    )


def test_gate_unattributed_unchanged():
    # 기존 동작 회귀 방지: source_attributed 기본값은 게이트를 바꾸지 않는다.
    assert gate_source_type("일기", single_speaker=True) == DIARY_CATEGORY
    assert gate_source_type("일기", single_speaker=False) == "대화"


# ─── Commit path (DB) ──────────────────────────────────────────────────────────

async def _staged_source_entry(
    db_session,
    user_id,
    *,
    claims: list[dict],
    attribution_name: str = "Claude",
) -> JournalEntry:
    entry = JournalEntry(
        user_id=user_id,
        status="graph_staging_ready",
        source_type="책",
        attribution_kind="source",
        attribution_name=attribution_name,
        transcript_clean_native="메자닌 투자의 풋옵션 미이행 가능성 점검 지표.",
        translation_en="Checklist for put-option default risk in mezzanine deals.",
        graph_staging={
            "claims": claims,
            "context_type": "책",
            "speaker_count": 1,
        },
    )
    db_session.add(entry)
    await db_session.commit()
    await db_session.refresh(entry)
    return entry


async def _apply_and_commit(entry_id, payload, user, db_session):
    """Call /graph/apply, then run the background task it queued.

    The endpoint accepts the commit and hands the work off (see
    ``run_entry_graph_commit``), so a test that asserts on committed nodes has
    to drive the background task the way Starlette does after responding.
    """
    tasks = BackgroundTasks()
    out = await apply_entry_graph(
        entry_id, payload, user, db_session, background_tasks=tasks
    )
    await tasks()
    return out


@pytest.mark.asyncio
async def test_source_attributed_apply_creates_source_head(db_session, iso_user):
    """attribution_kind='source' 엔트리 커밋 → head 노드 타입은 Source."""
    entry = await _staged_source_entry(
        db_session,
        iso_user.id,
        claims=[{
            "speaker": "Claude",
            "speaker_type": "Source",
            "title": "풋옵션 미이행 가능성 점검",
            "statement": "풋옵션 청구 시 상환재원과 담보를 평가해야 한다",
            "concepts": [{"name": "풋옵션", "importance": 5}],
        }],
    )

    out = await _apply_and_commit(entry.id, None, iso_user, db_session)
    assert out.status == "graph_committing"

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    head = next(n for n in nodes if n.name == "Claude")
    assert head.type == "Identity"
    assert head.is_source is True

    # Source head도 다른 정체성과 마찬가지로 화자 피커에 나온다 — 다만
    # is_source=True로 남아, 동명의 Person과 절대 하나로 합쳐지지 않는다.
    picker = await crud.list_person_nodes(db_session, iso_user.id)
    picked = next(n for n in picker if n.name == "Claude")
    assert picked.is_source is True


@pytest.mark.asyncio
async def test_speaker_type_restored_when_client_drops_it(db_session, iso_user):
    """리뷰 화면이 speaker_type 없이 claims를 되돌려보내도 Source로 커밋된다."""
    entry = await _staged_source_entry(
        db_session,
        iso_user.id,
        claims=[{
            "speaker": "한국경제",
            "title": "메자닌 심사 지표",
            "statement": "상환재원과 신용보강이 핵심 평가 기준이다",
            "concepts": [{"name": "메자닌", "importance": 4}],
        }],
        attribution_name="한국경제",
    )
    # speaker_type이 빠진 클라이언트 편집본 (기존 GraphApplyRequest 형태 그대로).
    payload = GraphApplyRequest(
        claims=[{
            "speaker": "한국경제",
            "title": "메자닌 심사 지표 (수정)",
            "statement": "상환재원과 담보·신용보강이 핵심 평가 기준이다",
            "concepts": [{"name": "메자닌", "importance": 4}],
        }],
        context_type="뉴스",
    )

    out = await _apply_and_commit(entry.id, payload, iso_user, db_session)
    assert out.status == "graph_committing"

    nodes = await crud.get_all_nodes(db_session, iso_user.id)
    head = next(n for n in nodes if n.name == "한국경제")
    assert head.type == "Identity"
    assert head.is_source is True


@pytest.mark.asyncio
async def test_person_and_source_same_name_stay_distinct(db_session, iso_user):
    """동명 Person과 Source는 서로 다른 노드 — 이름만으로 병합되지 않는다."""
    person = await crud._get_or_create_node(
        db_session, name="제니", type_="Person", user_id=iso_user.id
    )
    # type_="Source" is a legacy input token — _get_or_create_node still
    # normalizes it onto is_source=True rather than storing "Source" as a type.
    source = await crud._get_or_create_node(
        db_session, name="제니", type_="Source", user_id=iso_user.id
    )
    assert person.id != source.id
    assert person.is_source is False
    assert source.is_source is True

    # 둘 다 피커에 노출되지만, 병합되지 않은 별개 노드로 남는다. person은 원래
    # type_="Person"으로 만들었으니 문자 그대로 저장돼 있다 — Person→Identity
    # 축약은 repair_identity_types만 하는 별개의 일괄 백필이다.
    picker = await crud.list_person_nodes(db_session, iso_user.id)
    picked = [n for n in picker if n.name == "제니"]
    assert {n.id for n in picked} == {person.id, source.id}
    assert person.type == "Person"
    assert {n.is_source for n in picked} == {False, True}
