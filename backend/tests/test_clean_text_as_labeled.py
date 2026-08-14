"""다화자 추출이 정제본을 라벨 원본으로 승격하는 조건 — 화자 날조 방지가 핵심."""

from app.routers.kg_build import _clean_text_as_labeled

CLEAN = "[박병준] 출근 완료.\n[박의준] 운동 완료."


def test_promotes_labeled_clean_text_and_normalizes_colon():
    assert _clean_text_as_labeled(CLEAN, ["박병준", "박의준"]) == (
        "[박병준]: 출근 완료.\n[박의준]: 운동 완료."
    )


def test_rejects_speaker_not_in_segments():
    # 정제 LLM이 라벨을 바꿔치기하면 없는 인물 노드가 생긴다 — 승격하지 않는다.
    assert _clean_text_as_labeled(CLEAN, ["박병준"]) is None


def test_rejects_unlabeled_text():
    assert _clean_text_as_labeled("출근 완료.\n운동 완료.", ["박병준"]) is None


def test_line_count_need_not_match_segments():
    # 필요한 건 1:1 매핑이 아니라 화자가 붙은 정제 본문이다.
    text = "[박병준] 출근 완료.\n[박병준] 운동 완료.\n[박의준] 가보자고."
    assert _clean_text_as_labeled(text, ["박병준", "박의준"]) is not None
