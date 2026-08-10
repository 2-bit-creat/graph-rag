// A pasted glossary is not a conversation.
//
// The journal composer parses "이름: 내용" lines into speakers BEFORE sending,
// so the server never sees the raw paste and its own guard cannot help. A user
// pasted GP/fund study notes here and got 24 turns from 23 different "speakers"
// — 약정액, 설정액, ROE, 수탁은행 and the rest, each committed as a person.
//
// Same discriminator as backend/app/precision_text.py: turns per speaker.

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

const _glossary = '''GP 운용사 평가 및 금융 핵심 개념 정리
1. 평가표 역외운용사 기준 작성법
 의미: 국내 공모운용사 분위별 절댓값(Cut-off AUM)에 150%를 적용하여 산출.
 표 수정 수식: (역외: 공모운용사 상위 X% 기준금액 × 150% 적용)
 표 작성 주의사항: 셀 병합 파손 방지를 위해 표 내부 줄바꿈 금지.
2. 펀드 자금 개념
 약정액: LP가 출자하기로 약속한 최대 금액 (신용카드 한도 개념).
 설정액: 실제로 LP가 납입 완료한 출자 원금 (카드 사용 금액 개념).
3. 공모 vs 사모 / 펀드의 부채
 공모: 50인 이상 일반 투자자 대상, 엄격한 규제 적용.
 사모: 소수 전문투자자/고액자산가 대상, 규제 완화.
 펀드 부채 발생 원인: 자산 매입용 대출, 파생상품 증거금 및 RP 매도 레버리지.
5. GP 평가 핵심 재무지표
 설정액: 실제 집행 트랙레코드 및 신뢰도.
 ROE: GP 본사 자본의 운용 효율성 및 자생력.
 자기자본비율: 부채 리스크 검증 및 펀드 연쇄 리스크 방지.
7. GP 인프라 및 평가 요소
 펀드회계: 펀드의 자금 흐름과 기준가격을 계산하는 장부 작성 업무.
 수탁은행: 펀드 자산을 보관하고 매매를 대행하는 금고 역할.
 사무수탁사: 독립적인 펀드회계 및 행정 처리를 대행하는 기관.
 컴플라이언스: 준법감시, 미공개 정보 이용 차단, 이해상충 관리.''';

void main() {
  test('pasted glossary is not parsed as a dialogue', () {
    expect(parseDialogueLines(_glossary), isNull);
  });

  test('glossary terms never become speakers', () {
    final parsed = parseDialogueLines(_glossary);
    final speakers = parsed?.lines.map((e) => e.key).toSet() ?? <String>{};
    for (final term in ['약정액', '설정액', 'ROE', '수탁은행', '컴플라이언스', '의미']) {
      expect(speakers, isNot(contains(term)), reason: '$term is a concept, not a person');
    }
  });

  test('a real chat paste still splits', () {
    final parsed = parseDialogueLines('''제니: 내일 몇 시에 만날까?
나: 나는 7시 이후면 아무 때나 괜찮아
제니: 그럼 7시 반에 강남역 어때
나: 좋아 그때 보자''');
    expect(parsed, isNotNull);
    expect(parsed!.lines.map((e) => e.key).toList(), ['제니', '나', '제니', '나']);
  });

  test('a lopsided interview still splits', () {
    final parsed = parseDialogueLines('''기자: 이번 분기 실적을 어떻게 보시나요
대표: 매출은 기대치를 넘었습니다
대표: 다만 마케팅비가 늘어난 점은 아쉽습니다
대표: 내년에는 효율을 더 끌어올릴 계획입니다''');
    expect(parsed, isNotNull);
    expect(parsed!.lines.map((e) => e.key).toList(),
        ['기자', '대표', '대표', '대표']);
  });

  test('explicit [화자]: labels bypass the heuristic entirely', () {
    final parsed = parseDialogueLines('[제니]: 안녕\n[나]: 반가워');
    expect(parsed, isNotNull);
    expect(parsed!.lines.map((e) => e.key).toList(), ['제니', '나']);
  });

  test('prose with colons is not a conversation', () {
    expect(
      parseDialogueLines('''오늘의 결심: 아침에 일찍 일어나기
주의: 커피는 두 잔까지만
참고: 내일은 비가 온다고 한다'''),
      isNull,
    );
  });
}
