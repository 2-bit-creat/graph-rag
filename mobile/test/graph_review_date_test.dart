import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/graph_review_panel.dart';

/// A staging payload shaped like the one /kg extraction returns, with the
/// server-resolved event date the review UI is supposed to surface.
Map<String, dynamic> _staging({
  required String resolvedDate,
  required String precision,
  String? secondClaimDate,
}) =>
    {
      'context_type': '일기',
      'recorded_date': '2026-07-30',
      'person_candidates': const [],
      'claims': [
        {
          'speaker': '나',
          'speaker_type': 'Person',
          'title': '친구 이직 소식',
          'statement': '친구가 이직한대.',
          'concepts': const [
            {'name': '이직', 'importance': 4, 'kind': 'concept'}
          ],
          'temporal_precision': 'unknown',
          'temporal_confidence': 0.0,
          'event_status': 'happened',
          'resolved_event_date': resolvedDate,
          'resolved_precision': precision,
          'resolved_confidence': precision == 'recorded_date' ? 0.6 : 1.0,
        },
        if (secondClaimDate != null)
          {
            'speaker': '나',
            'speaker_type': 'Person',
            'title': '두 번째 진술',
            'statement': '그리고 나는 이런 생각을 했다.',
            'concepts': const [
              {'name': '생각', 'importance': 3, 'kind': 'concept'}
            ],
            'temporal_precision': 'unknown',
            'temporal_confidence': 0.0,
            'event_status': 'happened',
            'resolved_event_date': secondClaimDate,
            'resolved_precision': 'recorded_date',
            'resolved_confidence': 0.6,
          },
      ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> staging) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: GraphReviewPanel(entryId: 'entry-1', staging: staging),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('review panel event date', () {
    testWidgets('shows the resolved date instead of leaving it implicit',
        (tester) async {
      await _pump(
        tester,
        _staging(resolvedDate: '2026-07-30', precision: 'recorded_date'),
      );
      // 2026-07-30 is a Thursday — "7월 30일 (목)".
      expect(find.textContaining('7월 30일'), findsWidgets);
    });

    testWidgets('asks for confirmation when the day was only inferred',
        (tester) async {
      await _pump(
        tester,
        _staging(resolvedDate: '2026-07-30', precision: 'recorded_date'),
      );
      expect(find.textContaining('기록한 날로 넣어뒀어요'), findsOneWidget);
    });

    testWidgets('states the day plainly when the text actually said when',
        (tester) async {
      await _pump(
        tester,
        _staging(resolvedDate: '2026-07-29', precision: 'relative'),
      );
      expect(find.text('언제 있었던 일인가요?'), findsOneWidget);
      expect(find.textContaining('기록한 날로 넣어뒀어요'), findsNothing);
    });

    testWidgets('bulk shortcut moves every claim to the previous day',
        (tester) async {
      await _pump(
        tester,
        _staging(
          resolvedDate: '2026-07-30',
          precision: 'recorded_date',
          secondClaimDate: '2026-07-30',
        ),
      );
      await tester.tap(find.text('그 전날'));
      await tester.pump();
      // 2026-07-29 is a Wednesday — the whole entry moved together, so the
      // header states one shared day rather than "날짜 여러 개".
      expect(find.textContaining('7월 29일'), findsWidgets);
      expect(find.text('날짜 여러 개'), findsNothing);
    });

    testWidgets('reports mixed days when claims disagree', (tester) async {
      await _pump(
        tester,
        _staging(
          resolvedDate: '2026-07-30',
          precision: 'recorded_date',
          secondClaimDate: '2026-07-28',
        ),
      );
      expect(find.text('날짜 여러 개'), findsOneWidget);
    });
  });
}
