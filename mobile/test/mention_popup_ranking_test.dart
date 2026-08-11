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

  // Only about three and a half rows are visible; the rest are a scroll away.
  // What matters is that the three the eye lands on are the right three.
  testWidgets('a bare @ leads with the best-connected identities',
      (tester) async {
    final field = await _pump(tester, graphSpeakers: graph);

    final options = field.debugMentionOptions('');
    // '나' is a session badge and always leads; the rest come by weight.
    expect(options.map((o) => o.name).take(3).toList(),
        ['나', '강민지', '하승목']);
    // The tail stays reachable rather than being dropped.
    expect(options.map((o) => o.name), contains('가나다'));
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

  testWidgets('a large graph is capped, and capped from the bottom of the rank',
      (tester) async {
    final field = await _pump(tester, graphSpeakers: [
      for (var i = 0; i < 60; i++) SpeakerOption('사람$i', weight: 60 - i),
    ]);

    final names = field.debugMentionOptions('').map((o) => o.name).toList();
    expect(names.length, lessThanOrEqualTo(20));
    // Truncation must drop the least connected, never the most.
    expect(names.take(3).toList(), ['나', '사람0', '사람1']);
    expect(names, isNot(contains('사람59')));
  });
}
