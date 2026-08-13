import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/ocr_review_sheet.dart';

/// The sheet is the only place a photographed conversation gets corrected, and
/// correcting it means typing — so the keyboard is up for the whole task. It
/// used to size its field at 42% of the *full* screen regardless, which meant
/// the moment the keyboard appeared the content was taller than the space left:
/// Flutter painted the yellow overflow stripes across the transcript, the rows
/// below the fold were unreachable, and nothing scrolled. The only way to read
/// what you were fixing was to dismiss the keyboard, which is the opposite of
/// what a correction surface should ask.
Widget _host({required double height, required double inset}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(390, height),
        viewInsets: EdgeInsets.only(bottom: inset),
      ),
      // `resizeToAvoidBottomInset: false` matches how the sheet actually
      // appears: showModalBottomSheet puts it on the navigator overlay, where
      // it receives the full screen height and subtracts the keyboard itself.
      // A resizing Scaffold would take the inset off first and make the sheet
      // subtract it twice.
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: OcrReviewSheet(
            initialText: List.generate(
              40,
              (i) => '@Unist 박병준: 근데 워터파크도 좋음 $i',
            ).join('\n'),
            speakers: const [
              'Unist 박병준',
              'Unist 박의준',
              'Unist 이영호',
              'Unist 정승현',
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  // 213px was the measured overflow on the reporter's iPhone. Test the whole
  // band of phone heights rather than that one number, because the failure was
  // never about a specific device — it was about ignoring the inset at all.
  for (final height in const [640.0, 740.0, 844.0, 932.0]) {
    for (final inset in const [0.0, 291.0, 336.0, 420.0]) {
      testWidgets(
        'OCR sheet fits at ${height}h with a ${inset}px keyboard',
        (tester) async {
          tester.view.physicalSize = Size(390, height);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(_host(height: height, inset: inset));
          await tester.pump();

          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('the confirm button stays reachable under the keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(height: 844, inset: 336));
    await tester.pump();

    // The button is the exit from this sheet. An overflowing column pushed it
    // off the bottom, so the corrected text could not be handed on at all.
    final button = find.byType(FilledButton);
    expect(button, findsOneWidget);
    final rect = tester.getRect(button);
    expect(rect.bottom, lessThanOrEqualTo(844 - 336));
  });

  testWidgets('a long transcript scrolls without the field owning the scroll',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(height: 844, inset: 336));
    await tester.pump();

    // Both halves of the caret fix, asserted where they can actually regress.
    //
    // `maxLines: null` with the field growing inside CaretStableField's
    // SingleChildScrollView means EditableText has no viewport of its own to
    // yank to the caret — the field is TALLER than what is visible, and the
    // ScrollView (whose showOnScreen requests BlockShowOnScreen swallows) is
    // what shows the rest. Reintroducing a bounded field would make the field's
    // height shrink back to the viewport's, so compare the two.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, isNull);

    final viewport = tester.getRect(find.byType(SingleChildScrollView).last);
    expect(viewport.height, greaterThan(0));
    expect(viewport.height, lessThan(844 - 336));

    final box = tester.getRect(find.byType(TextField));
    expect(box.height, greaterThan(viewport.height));
  });

  testWidgets('EditableText gets no showOnScreen viewport of its own',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(height: 844, inset: 336));
    await tester.pump();

    // Tapping a line near the TOP of a long transcript is the reported
    // symptom: focus arrives first, the reveal runs on the old caret, and the
    // view scrolls somewhere else. Nothing may move on its own here.
    final scrollable = find.byType(SingleChildScrollView).last;
    // `.first` is the SingleChildScrollView's own Scrollable — EditableText
    // still builds one below it, it just has nothing to scroll now that its
    // height is unbounded.
    final before = tester.state<ScrollableState>(
      find.descendant(of: scrollable, matching: find.byType(Scrollable)).first,
    );
    // Not `tap(find.byType(TextField))` — the field's center is now far below
    // the fold, which is the whole point. Press a line that is actually visible.
    final visible = tester.getRect(scrollable);
    await tester.tapAt(Offset(visible.center.dx, visible.top + 12));
    await tester.pumpAndSettle();

    expect(before.position.pixels, 0.0);
  });
}
