// 화자는 명시적 표기로만 갈린다: `@이름` 멘션, 그리고 `[이름]:` 라벨.
//
// 콜론만 보고 화자를 만들던 휴리스틱은 제거됐다. 명분이던 카톡 붙여넣기는 실제
// 내보내기 포맷이 그 정규식에 애초에 걸리지 않았고, 대신 콜론을 쓰는 평범한
// 문서를 잘랐다 — 금융 용어 정리 한 장이 화자 23명짜리 대화가 되어 개념마다
// 인물 노드가 그래프에 박혔다. 아래 테스트는 그 규칙이 돌아오지 않게 막는다.
//
// 같은 규칙의 사본: mobile/lib/widgets/precision_text_labeling_panel.dart,
// backend/app/precision_text.py.

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
  group('콜론만으로는 화자가 되지 않는다', () {
    test('붙여넣은 용어사전은 대화가 아니다', () {
      expect(parseDialogueLines(_glossary), isNull);
    });

    test('용어가 화자로 승격되지 않는다', () {
      final parsed = parseDialogueLines(_glossary);
      final speakers = parsed?.lines.map((e) => e.key).toSet() ?? <String>{};
      for (final term in ['약정액', '설정액', 'ROE', '수탁은행', '컴플라이언스', '의미']) {
        expect(speakers, isNot(contains(term)),
            reason: '$term 은 개념이지 사람이 아니다');
      }
    });

    test('콜론이 섞인 산문은 대화가 아니다', () {
      expect(
        parseDialogueLines('''오늘의 결심: 아침에 일찍 일어나기
주의: 커피는 두 잔까지만
참고: 내일은 비가 온다고 한다'''),
        isNull,
      );
    });

    // 옛 턴 수 임계값(화자당 2턴)을 통과하던 모양. 임계값으로는 못 막던 케이스라
    // 규칙 자체를 없앤 이유이기도 하다.
    test('이름이 반복되는 Q&A 메모도 대화가 아니다', () {
      expect(
        parseDialogueLines('''질문: 왜 이렇게 설계했나
답변: 캐시 때문이다
질문: 대안은 없었나
답변: 있었지만 느렸다'''),
        isNull,
      );
    });

    // 맨살 "이름: 내용"을 노렸던 원래 명분. 정작 실제 카톡 내보내기는 두 포맷 다
    // 그 정규식에 걸리지 않았다 — 규칙을 되살릴 근거가 못 된다는 기록.
    test('카톡 내보내기 원본은 어느 포맷도 자동 분리되지 않는다', () {
      expect(
        parseDialogueLines('''2026년 8월 11일 오후 3:20, 홍길동 : 안녕
2026년 8월 11일 오후 3:21, 김영희 : 어 왔어'''),
        isNull,
      );
      expect(
        parseDialogueLines('''[홍길동] [오후 3:20] 안녕
[김영희] [오후 3:21] 어 왔어'''),
        isNull,
      );
    });
  });

  group('명시적 표기만 화자를 만든다', () {
    test('[화자]: 라벨은 그대로 분리된다', () {
      final parsed = parseDialogueLines('[제니]: 안녕\n[나]: 반가워');
      expect(parsed, isNotNull);
      expect(parsed!.lines.map((e) => e.key).toList(), ['제니', '나']);
    });

    test('라벨 없는 이어지는 줄은 직전 화자에게 붙는다', () {
      final parsed = parseDialogueLines('[제니]: 안녕\n오늘 날씨 좋다\n[나]: 그러게');
      expect(parsed, isNotNull);
      expect(parsed!.lines.map((e) => e.key).toList(), ['제니', '나']);
      expect(parsed.lines.first.value, '안녕\n오늘 날씨 좋다');
    });

    // OCR이 스크린샷 대화에서 만들어 오는 모양 — 이 함수가 아니라 멘션 경로가
    // 처리하므로, 여기서는 대화로 인정하지 않는 것이 맞다.
    test('@이름: 줄은 이 함수가 아니라 멘션 경로가 맡는다', () {
      const text = '@제니: 내일 몇 시에 만날까\n@나: 7시 이후면 아무 때나';
      expect(parseDialogueLines(text), isNull);
      expect(atMentionLineSpeakers(text), ['제니', '나']);
    });
  });
}
