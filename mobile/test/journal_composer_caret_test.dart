import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

/// The journal composer must stay a capped, scrollable box (like any chat
/// composer) while leaving exactly ONE scroll offset in play. A TextField with a
/// capped maxLines owns an internal viewport; on Flutter web that offset is not
/// the one the hidden DOM input uses to resolve a tap, so once the text is
/// scrolled a tap resolves against unscrolled text and the caret snaps back.
///
/// The fix is not "let it grow forever" — the box is still capped. It is that
/// the scrolling belongs to an ordinary ScrollView and the field grows freely
/// inside it, so there is nothing to diverge.
const _maxHeight = 132.0;

const _longDraft =
    '@나: 부부장님, 이번 투자 특화 영역 체크리스트 고도화 관련해서 말씀드리려고 합니다.\n'
    '@부부장님: 딜 영역의 평가항목을 산업마다 전부 다르게 설정하면 AHP 가중치 설정에서 문제가 생겨.\n'
    '@나: AHP 가중치 산출 쪽에서 구체적으로 어떤 문제가 발생하나요?\n'
    '@부부장님: 쌍대비교 문항이 200개를 넘어가면 일관성 비율 검증을 통과하지 못해.\n'
    '@나: 그러면 1안과 2안을 비교하는 방향으로 보고서를 작성하겠습니다.\n'
    '@부부장님: 그렇게 가면 방어 논리도 깔끔해지겠네.\n';

Widget _composer(
  GlobalKey<MentionAutocompleteFieldState> key,
  ScrollController outer, {
  FocusNode? focusNode,
  bool blockShowOnScreen = true,
}) {
  final field = MentionAutocompleteField(
    key: key,
    focusNode: focusNode,
    minLines: 1,
    maxLines: null,
    showCounter: false,
    initialText: _longDraft,
  );
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _maxHeight),
          child: SingleChildScrollView(
            controller: outer,
            child: blockShowOnScreen
                ? BlockShowOnScreen(child: field)
                : field,
          ),
        ),
      ),
    ),
  );
}

ScrollableState _innerScrollable(WidgetTester tester) {
  final editable = find.byType(EditableText);
  expect(editable, findsOneWidget);
  return tester.state<ScrollableState>(
    find.descendant(of: editable, matching: find.byType(Scrollable)).first,
  );
}

void main() {
  // Flutter syncs ONE flat style to the hidden DOM input the browser uses to
  // turn a tap into a caret position (EditableText._getTextInputStyle sends
  // fontFamily/fontSize/fontWeight/letterSpacing/wordSpacing/lineHeight from the
  // field's base style). Per-run styling cannot be represented there, so any run
  // whose glyphs advance differently from the base style shifts every character
  // after it out of sync with the DOM — and the caret lands on the wrong one.
  testWidgets('mention runs differ from the base style in color only',
      (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    const base = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      wordSpacing: 0,
      fontFamily: 'Roboto',
    );
    final controller = MentionStyledController(
      mentionsOf: (t) => findMentions(t, const ['나', '부부장님']),
      colorOf: (_) => const Color(0xFF1264A3),
    )..text = _longDraft;

    final span = controller.buildTextSpan(
      context: tester.element(find.byType(SizedBox)),
      style: base,
      withComposing: false,
    );

    final runs = <TextSpan>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.text != null) runs.add(s);
        for (final child in s.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    walk(span);
    expect(runs, isNotEmpty);
    for (final run in runs) {
      final style = run.style;
      if (style == null) continue;
      expect(style.fontSize, base.fontSize, reason: 'run "${run.text}"');
      expect(style.fontWeight, base.fontWeight, reason: 'run "${run.text}"');
      expect(style.letterSpacing, base.letterSpacing,
          reason: 'run "${run.text}"');
      expect(style.wordSpacing, base.wordSpacing, reason: 'run "${run.text}"');
      expect(style.fontFamily, base.fontFamily, reason: 'run "${run.text}"');
    }
    // The whole point of the controller still has to work.
    expect(runs.any((r) => r.style?.color == const Color(0xFF1264A3)), isTrue,
        reason: 'mentions must still be colored');
    expect(runs.map((r) => r.text).join(), _longDraft,
        reason: 'the runs must reconstruct the text exactly, or every offset '
            'after a gap would be wrong');
  });

  testWidgets('the field itself never scrolls; the box around it does',
      (tester) async {
    final key = GlobalKey<MentionAutocompleteFieldState>();
    final outer = ScrollController();
    addTearDown(outer.dispose);

    await tester.pumpWidget(_composer(key, outer));
    await tester.pumpAndSettle();

    // The box is still capped — this is not "grow forever".
    final box = tester.getSize(find.byType(SingleChildScrollView));
    expect(box.height, _maxHeight);

    // ...and it is what scrolls.
    expect(outer.position.maxScrollExtent, greaterThan(0),
        reason: 'the capped box must be scrollable for a long draft');

    // The TextField owns no scrollable range of its own: exactly one offset.
    expect(_innerScrollable(tester).position.maxScrollExtent, 0,
        reason: 'a capped maxLines would give the field its own viewport, '
            'which is the offset that diverges from the DOM input on web');
  });

  testWidgets('tapping high up in a scrolled draft moves the caret there',
      (tester) async {
    final key = GlobalKey<MentionAutocompleteFieldState>();
    final outer = ScrollController();
    addTearDown(outer.dispose);

    await tester.pumpWidget(_composer(key, outer));
    await tester.pumpAndSettle();

    // Put the caret at the very end, then scroll back up — the situation the
    // user described: looking at earlier text while the caret is far below.
    final state = key.currentState!;
    state.setText(_longDraft);
    await tester.pumpAndSettle();
    expect(state.caretAtEnd, isTrue);

    outer.jumpTo(0);
    await tester.pumpAndSettle();
    expect(outer.offset, 0);

    // Tap near the top of the visible box.
    final box = tester.getRect(find.byType(SingleChildScrollView));
    await tester.tapAt(Offset(box.left + 40, box.top + 12));
    await tester.pumpAndSettle();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    final caret = editable.controller.selection.baseOffset;

    expect(caret, isNot(_longDraft.length),
        reason: 'the caret must leave the end of the text');
    expect(caret, lessThan(80),
        reason: 'the caret must land in the first line that was tapped');
    expect(outer.offset, 0,
        reason: 'the view must not snap back to where the caret used to be');
  });

  // The actual reported failure. EditableText schedules a caret reveal every
  // time the field gains focus (editable_text.dart `_handleFocusChanged`), and
  // that reveal walks up the render tree until some ancestor scrolls. Focus is
  // granted a frame before the tap's new selection arrives from the DOM on web,
  // so the reveal sees the OLD caret and scrolls back to it — the tap looks
  // ignored no matter where the scrolling lives.
  group('focus gain does not drag the view back to the old caret', () {
    Future<double> offsetAfterFocusGain(
      WidgetTester tester, {
      required bool blockShowOnScreen,
    }) async {
      final key = GlobalKey<MentionAutocompleteFieldState>();
      final outer = ScrollController();
      final focus = FocusNode();
      addTearDown(outer.dispose);
      addTearDown(focus.dispose);

      await tester.pumpWidget(_composer(key, outer,
          focusNode: focus, blockShowOnScreen: blockShowOnScreen));
      await tester.pumpAndSettle();

      // Caret parked at the end of a long draft, field not focused.
      key.currentState!.setText(_longDraft);
      await tester.pumpAndSettle();

      // The user scrolls up to look at earlier text.
      outer.jumpTo(0);
      await tester.pumpAndSettle();
      expect(outer.offset, 0);

      // The field takes focus while the selection is still the old one.
      focus.requestFocus();
      await tester.pumpAndSettle();
      return outer.offset;
    }

    testWidgets('unblocked, the reveal scrolls the ancestor (the bug)',
        (tester) async {
      final offset =
          await offsetAfterFocusGain(tester, blockShowOnScreen: false);
      expect(offset, greaterThan(0),
          reason: 'this documents the failure the fix removes; if this ever '
              'reads 0, EditableText changed and the fix may be unnecessary');
    });

    testWidgets('blocked, the view stays where the user left it',
        (tester) async {
      final offset =
          await offsetAfterFocusGain(tester, blockShowOnScreen: true);
      expect(offset, 0);
    });
  });
}
