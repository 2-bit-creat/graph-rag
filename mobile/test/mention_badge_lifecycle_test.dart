// Two bugs that only showed up while EDITING an imported transcript, both of
// them about the gap between "what the text says right now" and "what the field
// remembers".
//
//  * Badges were append-only. Every keystroke registered the `@이름:` labels it
//    could see, and nothing ever removed one — so deleting a prefix character
//    by character left every intermediate spelling behind as a permanent
//    speaker, and the picker offered them forever.
//  * The picker reopened over a mention that had already been chosen, because
//    the context only looked at the text BEFORE the caret and therefore could
//    not see the name it was standing on.
//
// Both are pure text/caret logic, which is why they are testable here at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

Future<MentionAutocompleteFieldState> _pump(
  WidgetTester tester, {
  String initialText = '',
}) async {
  final key = GlobalKey<MentionAutocompleteFieldState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MentionAutocompleteField(
          key: key,
          maxLines: null,
          initialText: initialText,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

/// Replace the text and put the caret at [caret] (default: end).
Future<void> _type(
  WidgetTester tester,
  MentionAutocompleteFieldState field,
  String text, {
  int? caret,
}) async {
  field.setText(text);
  await tester.pumpAndSettle();
  if (caret != null) {
    await _caretTo(tester, field, caret);
  }
}

Future<void> _caretTo(
  WidgetTester tester,
  MentionAutocompleteFieldState field,
  int offset,
) async {
  final editable = tester.state<EditableTextState>(find.byType(EditableText));
  editable.userUpdateTextEditingValue(
    editable.textEditingValue.copyWith(
      selection: TextSelection.collapsed(offset: offset),
    ),
    SelectionChangedCause.tap,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('badges follow the text', () {
    testWidgets('a half-deleted name does not survive as a speaker',
        (tester) async {
      // The reported sequence: strip "Unist" off an OCR-imported label one
      // character at a time. Every one of these used to stick.
      final field = await _pump(
        tester,
        initialText: '@Unist이영호: 오늘 자정퇴근',
      );
      expect(field.badges, contains('Unist이영호'));

      for (final step in const [
        '@Unis이영호: 오늘 자정퇴근',
        '@Uni이영호: 오늘 자정퇴근',
        '@Un이영호: 오늘 자정퇴근',
        '@U이영호: 오늘 자정퇴근',
        '@이영호: 오늘 자정퇴근',
      ]) {
        await _type(tester, field, step);
      }

      expect(field.badges, ['나', '이영호'],
          reason: 'only what the text currently says is a speaker');
      expect(
        field.debugMentionOptions('').map((o) => o.name),
        isNot(anyElement(startsWith('U'))),
        reason: 'the picker must not offer the intermediate spellings',
      );
    });

    testWidgets('a picked speaker survives until its token leaves the text',
        (tester) async {
      // _applyMention writes "@이름 " with no colon yet, which the line parser
      // cannot see. Without the picked-name carve-out the badge would vanish on
      // the very next keystroke.
      final field = await _pump(tester);
      field.ensureSpeaker('박의준');
      await _type(tester, field, '@박의준 ');
      expect(field.badges, contains('박의준'));

      await _type(tester, field, '아무 말이나');
      expect(field.badges, ['나'],
          reason: 'the token is gone, so the speaker is gone');
    });

    testWidgets('order follows position in the text, not registration order',
        (tester) async {
      // Color is assigned by index into this list, so the order has to be a
      // property of the DRAFT, not of the sequence the names happened to be
      // registered in. Registering a speaker last and then writing it first
      // must still place it first.
      final field = await _pump(
        tester,
        initialText: '@박의준: 안녕\n@이영호: 반가워',
      );
      expect(field.badges, ['나', '박의준', '이영호']);

      field.ensureSpeaker('정승헌'); // registered LAST …
      await _type(
        tester,
        field,
        '@정승헌: 처음이야\n@박의준: 안녕\n@이영호: 반가워', // … but written FIRST
      );

      expect(field.badges, ['나', '정승헌', '박의준', '이영호']);
      expect(field.colorFor('정승헌'), isNot(field.colorFor('박의준')));
      expect(field.colorFor('박의준'), isNot(field.colorFor('이영호')));
    });
  });

  group('the picker does not fight a settled mention', () {
    const text = '@이영호: 오늘 자정퇴근';

    testWidgets('caret immediately right of the @ opens nothing',
        (tester) async {
      final field = await _pump(tester, initialText: text);
      // Offset 1 is the reported tap: just past the "@", with the confirmed
      // name sitting entirely to the RIGHT of the caret.
      await _caretTo(tester, field, 1);

      expect(field.debugMentionContext, isNull,
          reason: 'the whole speaker list used to appear here');
    });

    testWidgets('caret inside the name opens nothing', (tester) async {
      final field = await _pump(tester, initialText: text);

      // 1..3 are inside "@이영호"; 4 is its end, which is the extend position
      // and deliberately still offers the picker (see the next test).
      for (final offset in const [1, 2, 3]) {
        await _caretTo(tester, field, offset);
        expect(field.debugMentionContext, isNull, reason: 'offset $offset');
      }
    });

    testWidgets('the end of the name is the extend position', (tester) async {
      // The other half of the request: typing past a confirmed name must be
      // able to become a DIFFERENT speaker — and reach the picker while doing
      // it, so an existing identity can be completed instead of only invented.
      final field = await _pump(tester, initialText: text);
      await _caretTo(tester, field, 4); // right after "@이영호"

      expect(field.debugMentionContext?.partial, '이영호');

      await _type(tester, field, '@이영호s: 오늘 자정퇴근', caret: 5);
      expect(field.debugMentionContext?.partial, '이영호s');
    });

    testWidgets('a fresh @ still opens the full list', (tester) async {
      final field = await _pump(tester, initialText: '$text\n@');
      await _caretTo(tester, field, '$text\n@'.length);

      final ctx = field.debugMentionContext;
      expect(ctx, isNotNull);
      expect(ctx!.partial, '');
      expect(field.debugMentionOptions('').map((o) => o.name),
          containsAll(<String>['나', '이영호']));
    });
  });
}
