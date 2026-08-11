// OCR hands the composer text, not structure. These cover the seam.
//
// A chat screenshot comes back from /ocr/image as "@이름: 발화" lines; anything
// else comes back as plain prose. Dropping that into the journal field via
// setText has to register the speakers as badges — without badges, findMentions
// matches nothing and the "@이름:" prefixes survive into the saved entry as
// literal text attributed entirely to 나.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

Future<MentionAutocompleteFieldState> _pumpField(WidgetTester tester) async {
  final key = GlobalKey<MentionAutocompleteFieldState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MentionAutocompleteField(key: key, maxLines: null),
      ),
    ),
  );
  // The field fetches graph speakers on init; settle so that request's timer is
  // done before the test body runs.
  await tester.pumpAndSettle();
  return key.currentState!;
}

void main() {
  testWidgets('imported "@이름:" transcript registers its speakers as badges',
      (tester) async {
    final field = await _pumpField(tester);

    field.setText('@제니: 내일 몇 시에 만날까\n@나: 7시 이후면 아무 때나');
    await tester.pumpAndSettle();

    expect(field.badges, containsAll(<String>['나', '제니']));
    expect(field.findCurrentMentions().length, 2);
    expect(
      labeledTextFromMentionField(field),
      '[제니]: 내일 몇 시에 만날까\n[나]: 7시 이후면 아무 때나',
    );
  });

  // Why OCR must emit the colon even though a hand-typed mention does not need
  // one: typing registers the badge when the learner picks it from the popup,
  // but imported text has no popup to pick from, so the only thing that can
  // register a name is the "@이름:" line shape.
  //
  // Without the colon the import fails quietly, which is the worst shape of
  // failure — 제니 is never registered, her line falls to 나 as the text before
  // the first live mention, and "@제니" survives as literal characters inside
  // 나's own statement.
  testWidgets('a colonless import loses the speaker instead of erroring',
      (tester) async {
    final field = await _pumpField(tester);

    field.setText('@제니 내일 몇 시에 만날까\n@나 7시 이후면 아무 때나');
    await tester.pumpAndSettle();

    expect(field.badges, ['나'], reason: '제니 was never registered');
    final labeled = labeledTextFromMentionField(field);
    expect(labeled, isNot(contains('[제니]')));
    expect(labeled, contains('@제니'), reason: 'it survives as raw text');
  });

  testWidgets('imported plain text belongs to 나 and invents no speakers',
      (tester) async {
    final field = await _pumpField(tester);

    // What a photo of a page produces — colons and all.
    field.setText('오늘의 결심: 아침에 일찍 일어나기\n주의: 커피는 두 잔까지만');
    await tester.pumpAndSettle();

    expect(field.badges, ['나']);
    expect(field.findCurrentMentions(), isEmpty);
    expect(
      labeledTextFromMentionField(field),
      '[나]: 오늘의 결심: 아침에 일찍 일어나기\n주의: 커피는 두 잔까지만',
    );
  });

  testWidgets('a second import replaces the draft rather than appending',
      (tester) async {
    final field = await _pumpField(tester);

    field.setText('@제니: 첫 번째 사진');
    await tester.pumpAndSettle();
    field.setText('@민수: 두 번째 사진');
    await tester.pumpAndSettle();

    expect(field.text, '@민수: 두 번째 사진');
    // 제니 stays a badge — the learner may still want to mention her by hand,
    // and a name that was real a moment ago is not worth forgetting.
    expect(field.badges, containsAll(<String>['나', '제니', '민수']));
  });
}
