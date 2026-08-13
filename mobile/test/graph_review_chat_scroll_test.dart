import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/graph_review_panel.dart';

/// The inline (chat) graph review must not carry a viewport of its own.
///
/// The regression: the panel put its claim list in a `ListView` capped at 420px,
/// nested inside the chat feed's own `ListView`. The inner viewport swallowed
/// every vertical drag over the draft, so the feed could not be scrolled from
/// there — the top of the draft stayed clipped just above the inner viewport with
/// no gesture able to reach it, and long drafts were unreachable from both ends.
Map<String, dynamic> _staging(int claimCount, {String speaker = '박병준'}) => {
      'context_type': '대화',
      'recorded_date': '2026-08-12',
      'person_candidates': const [],
      'claims': [
        for (var i = 1; i <= claimCount; i++)
          {
            'speaker': speaker,
            'speaker_type': 'Identity',
            'title': '진술 $i',
            'statement': '$i번째 발언입니다.',
            'concepts': [
              {'name': '개념$i', 'importance': 3, 'kind': 'concept'}
            ],
            'temporal_precision': 'unknown',
            'temporal_confidence': 0.0,
            'event_status': 'happened',
            'resolved_event_date': '2026-08-12',
            'resolved_precision': 'recorded_date',
            'resolved_confidence': 0.6,
          },
      ],
    };

Future<Finder> _pumpChat(
  WidgetTester tester, {
  int claims = 8,
  String speaker = '박병준',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        // Stands in for the chat feed: the one and only scrollable.
        body: ListView(
          children: [
            GraphReviewPanel(
              entryId: 'entry-1',
              staging: _staging(claims, speaker: speaker),
              presentation: GraphReviewPresentation.chat,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return find.byType(GraphReviewPanel);
}

void main() {
  testWidgets('chat review adds no nested list viewport', (tester) async {
    final panel = await _pumpChat(tester);
    expect(
      find.descendant(of: panel, matching: find.byType(ListView)),
      findsNothing,
      reason: 'a list nested in the chat feed steals the feed\'s drag gestures',
    );
  });

  testWidgets('chat review lays out every claim, uncapped', (tester) async {
    final panel = await _pumpChat(tester, claims: 8);
    // Laid out (not merely built lazily): the last claim exists in the tree even
    // though it sits far below the fold.
    expect(find.text('8번째 발언입니다.'), findsOneWidget);
    // Taller than the old 420px cap — nothing is being squeezed into a window.
    expect(tester.getSize(panel).height, greaterThan(420));
  });

  testWidgets('header states progress and offers bulk approve', (tester) async {
    await _pumpChat(tester, claims: 3);
    expect(find.text('그래프 초안'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget);

    await tester.tap(find.text('전체 승인'));
    await tester.pump();

    expect(find.text('3/3'), findsOneWidget);
    // Bulk approve is done — the shortcut retires instead of lingering.
    expect(find.text('전체 승인'), findsNothing);
    // Commit is now reachable.
    final commit = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(commit.onPressed, isNotNull);
  });

  testWidgets('commit stays locked until every claim is approved',
      (tester) async {
    await _pumpChat(tester, claims: 2);
    final commit = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(commit.onPressed, isNull);
  });

  testWidgets('claim meta row survives a long speaker name at phone width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpChat(
      tester,
      claims: 2,
      speaker: '하승목 책임연구원 겸 데이터플랫폼팀 리드',
    );
    // A RenderFlex overflow throws in tests; the row must ellipsize instead.
    expect(tester.takeException(), isNull);
  });
}
