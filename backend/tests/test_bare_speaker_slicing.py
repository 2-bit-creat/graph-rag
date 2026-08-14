"""A pasted glossary is not a conversation.

Regression: a user pasted their GP/fund study notes into 일기쓰기. Nearly every
line is "용어: 정의", which the un-bracketed speaker heuristic read as
"화자: 발화" — so 24 lines became 24 dialogue turns spoken by 23 different
"people", and every financial term (약정액, ROE, 수탁은행, 컴플라이언스 …) was
offered as a speaker and committed to the graph as an identity node.

The heuristic is gone entirely — see ``pre_slice_by_speaker_lines``'s docstring.
The turns-per-speaker discriminator that once tried to save it still let
``질문:/답변:`` memos through, and the KakaoTalk exports it was written for never
matched the regex anyway. Speakers now come only from explicit ``@이름`` mentions
and their normalized ``[이름]:`` labels; screenshots arrive through OCR, which
attaches the mentions itself.

So these tests pin the *absence* of the heuristic: bare "이름: 내용" lines are
prose, whatever they look like.
"""

from __future__ import annotations

from app.precision_text import pre_slice_by_speaker_lines

GLOSSARY = """GP 운용사 평가 및 금융 핵심 개념 정리
1. 평가표 역외운용사 기준 작성법
 의미: 국내 공모운용사 분위별 절댓값(Cut-off AUM)에 150%(1.5배)를 적용하여 역외운용사의 허들 금액을 산출.
 표 수정 수식: (역외: 공모운용사 상위 X% 기준금액 × 150% 적용)
 표 작성 주의사항: 셀 병합 파손 방지를 위해 표 내부 줄바꿈 금지.
2. 펀드 자금 개념
 약정액: LP가 출자하기로 약속한 최대 금액 (신용카드 한도 개념).
 설정액: 실제로 LP가 납입 완료한 출자 원금 (카드 사용 금액 개념).
3. 공모 vs 사모 / 펀드의 부채
 공모: 50인 이상 일반 투자자 대상, 엄격한 규제 적용.
 사모: 소수 전문투자자/고액자산가 대상, 규제 완화 및 다양한 전략 구사.
 펀드 부채 발생 원인: 자산 매입용 대출, 파생상품 증거금 및 RP 매도 레버리지.
5. GP 평가 핵심 재무지표
 설정액: 실제 집행 트랙레코드 및 신뢰도.
 ROE: GP 본사 자본의 운용 효율성 및 자생력.
 자기자본비율: 부채 리스크 검증 및 펀드 연쇄 리스크 방지.
7. GP 인프라 및 평가 요소
 펀드회계: 펀드의 자금 흐름과 기준가격(NAV)을 계산하는 장부 작성 업무.
 수탁은행: 펀드 자산을 보관하고 매매를 대행하는 금고 역할.
 사무수탁사: 독립적인 펀드회계 및 행정 처리를 대행하는 기관.
 컴플라이언스: 준법감시, 미공개 정보 이용 차단, 이해상충 관리."""


def test_glossary_is_not_sliced_into_speakers() -> None:
    """The whole point. Empty means the caller falls back to prose handling:
    one entry, one speaker, terms left for the LLM to extract as concepts."""
    assert pre_slice_by_speaker_lines(GLOSSARY) == []


def test_glossary_terms_never_become_speakers() -> None:
    speakers = {line["speaker"] for line in pre_slice_by_speaker_lines(GLOSSARY)}
    for term in ("약정액", "설정액", "ROE", "수탁은행", "컴플라이언스", "의미"):
        assert term not in speakers


def test_bare_name_chat_is_not_sliced() -> None:
    """Even the shape the heuristic existed for stays prose now.

    This looks like the clearest possible conversation, and it is still not
    split: a chat capture reaches the composer through OCR, which labels it
    "@제니: …", so nothing is lost by refusing to guess here — while guessing
    costs a person node for every colon in a glossary.
    """
    chat = """제니: 내일 몇 시에 만날까?
나: 나는 7시 이후면 아무 때나 괜찮아
제니: 그럼 7시 반에 강남역 어때"""
    assert pre_slice_by_speaker_lines(chat) == []


def test_repeated_speaker_names_do_not_revive_the_heuristic() -> None:
    """Turns-per-speaker was the last rescue attempt — it must stay dead."""
    interview = """기자: 이번 분기 실적을 어떻게 보시나요
대표: 매출은 기대치를 넘었습니다
대표: 다만 마케팅비가 늘어난 점은 아쉽습니다
대표: 내년에는 효율을 더 끌어올릴 계획입니다"""
    assert pre_slice_by_speaker_lines(interview) == []


def test_bracketed_form_is_unaffected() -> None:
    """Explicit [화자]: labels bypass the heuristic entirely."""
    lines = pre_slice_by_speaker_lines("[제니]: 안녕\n[나]: 반가워")
    assert [line["speaker"] for line in lines] == ["제니", "나"]


def test_prose_with_colons_is_not_a_conversation() -> None:
    """The case the original guard was written for, still guarded."""
    prose = """오늘의 결심: 아침에 일찍 일어나기
주의: 커피는 두 잔까지만
참고: 내일은 비가 온다고 한다"""
    assert pre_slice_by_speaker_lines(prose) == []
