// Mentions must render in their speaker's color, not one shared link blue.
//
// The composer is the surface where the learner decides who said what, so two
// speakers rendering identically there defeats the point. The controller took a
// colorOf callback from the start and painted kMentionLinkColor anyway.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

/// The colors actually painted on each "@이름" run, in order.
List<Color?> _mentionColors(BuildContext context, String text, List<String> badges) {
  final controller = MentionStyledController(
    mentionsOf: (t) => findMentions(t, badges),
    colorOf: (name) => colorForSpeaker(name, badges),
  )..text = text;
  final span = controller.buildTextSpan(
    context: context,
    style: const TextStyle(fontSize: 14),
    withComposing: false,
  );
  final hits = findMentions(text, badges);
  final names = hits.map((h) => h.name).toSet();
  final out = <Color?>[];
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is! TextSpan) continue;
    if (names.any((n) => child.text == '@$n')) out.add(child.style?.color);
  }
  controller.dispose();
  return out;
}

void main() {
  testWidgets('two speakers render in two colors', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));

    const badges = ['나', '하승목'];
    final colors = _mentionColors(
      ctx,
      '@하승목 오늘 횟집에서 점심 먹는다고 하더라고요.\n@나 아 오늘 점심 싸왔는데..',
      badges,
    );

    expect(colors.length, 2);
    expect(colors[0], isNot(colors[1]),
        reason: '@하승목 and @나 must not share a color');
    // 나 keeps its fixed self color; the other speaker comes from the palette.
    expect(colors[1], kSelfMentionColor);
    expect(kSpeakerPalette, contains(colors[0]));
  });

  testWidgets('a third speaker gets a third color', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));

    const badges = ['나', '하승목', '제니'];
    final colors = _mentionColors(ctx, '@나 a\n@하승목 b\n@제니 c', badges);
    expect(colors.length, 3);
    expect(colors.toSet().length, 3);
  });
}
