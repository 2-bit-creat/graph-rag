// The @ popup ranks by relevance, not by alphabet.
//
// Sorting names alphabetically pushed the identities the learner actually uses
// below ones they never touch, which defeats the purpose: the popup exists to
// let you stop typing early. Order is now "speakers already in this draft,
// then the identities the graph knows best".
//
// These drive the field's real popup state through its public surface, so a
// regression in the ranking shows up here rather than on a phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

Future<MentionAutocompleteFieldState> _pump(
  WidgetTester tester, {
  required List<SpeakerOption> graphSpeakers,
}) async {
  final key = GlobalKey<MentionAutocompleteFieldState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MentionAutocompleteField(key: key, maxLines: null),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final state = key.currentState!;
  state.debugSetGraphSpeakers(graphSpeakers);
  await tester.pumpAndSettle();
  return state;
}

void main() {
  const graph = [
    SpeakerOption('하승목', weight: 12),
    SpeakerOption('하나은행', isSource: true, weight: 3),
    SpeakerOption('강민지', weight: 30),
    SpeakerOption('가나다', weight: 1),
  ];

  testWidgets('a bare @ offers the best-connected identities, three at most',
      (tester) async {
    final field = await _pump(tester, graphSpeakers: graph);

    final options = field.debugMentionOptions('');
    expect(options.length, 3);
    // '나' is a session badge and always leads; the rest come by weight.
    expect(options.map((o) => o.name).toList(), ['나', '강민지', '하승목']);
  });

  testWidgets('speakers already used in this draft outrank the graph',
      (tester) async {
    final field = await _pump(tester, graphSpeakers: graph);
    field.ensureSpeaker('가나다'); // weight 1, but used here
    await tester.pumpAndSettle();

    final options = field.debugMentionOptions('');
    expect(options.map((o) => o.name).take(2).toList(), ['나', '가나다']);
  });

  testWidgets('typing filters by prefix first, then by connections',
      (tester) async {
    final field = await _pump(tester, graphSpeakers: graph);

    final options = field.debugMentionOptions('하');
    // 하승목 (12) before 하나은행 (3); 가나다 contains no 하 at all.
    expect(options.map((o) => o.name).toList(), ['하승목', '하나은행']);
  });

  testWidgets('a prefix match beats a better-connected substring match',
      (tester) async {
    final field = await _pump(tester, graphSpeakers: const [
      SpeakerOption('민지', weight: 2),
      SpeakerOption('강민지', weight: 99),
    ]);

    final options = field.debugMentionOptions('민');
    expect(options.first.name, '민지',
        reason: 'prefix wins even against a far more connected substring hit');
  });

  testWidgets('the idle list never exceeds three even with many identities',
      (tester) async {
    final field = await _pump(tester, graphSpeakers: [
      for (var i = 0; i < 20; i++) SpeakerOption('사람$i', weight: 20 - i),
    ]);
    expect(field.debugMentionOptions('').length, 3);
  });
}
