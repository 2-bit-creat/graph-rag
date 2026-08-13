import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_mode_cards.dart';
import 'package:graphrag_mobile/widgets/graph_chat_panel.dart';
import 'package:graphrag_mobile/widgets/scale_to_fit.dart';

/// The word quiz measured where it actually lives: a chat sheet pinned to the
/// bottom of the screen with the composer docked *over* it.
///
/// The existing viewport test hands `QuizViewportScope` an `availableHeight`
/// directly, so it only ever proved the card obeys a number it was given. It
/// could not see whether that number is the right one — and the number is
/// computed here, from the sheet's height minus the docked composer. That seam
/// is where a long question ends up under the keyboard.
const _longPrompt =
    'Die Vorstellung, dass der Darm und das Gehirn sich gegenseitig '
    'beeinflussen, gibt es schon seit langer Zeit, aber durch die Forschung '
    'der letzten zwanzig Jahre wurde sie in der Sprache der modernen Biologie '
    'endlich ____.';

const _longContext =
    '장과 뇌가 서로 영향을 주고받는다는 생각은 오래전부터 존재했지만, 최근 20여 년의 연구로 '
    '이를 현대 생물학의 언어로 체계화하게 되었다. 이 문장은 화면을 넘길 만큼 길어야 '
    '키보드가 올라온 상태에서 무슨 일이 벌어지는지 드러난다.';

const double _barHeight = 96;

/// Screen height above the keyboard, the way the real Scaffold hands it over.
Widget _host({
  required double screenHeight,
  required double inset,
  Map<String, dynamic>? externalResult,
}) {
  final visible = screenHeight - inset;
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(390, screenHeight),
        viewInsets: EdgeInsets.only(bottom: inset),
      ),
      // The real screen's Scaffold resizes, so its LayoutBuilder reports the
      // area above the keyboard. Model that directly: a box of `visible`
      // height holding the sheet and the composer docked at its bottom.
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SizedBox(
          height: visible,
          child: Stack(
            children: [
              // The sheet fills the visible area while the composer has focus
              // — `_chatExpandedForInput` in knowledge_graph_screen.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: visible,
                child: GraphChatPanel(
                  messages: const [],
                  busy: false,
                  typeColors: const {},
                  nodeById: const {},
                  onNodeHighlight: (_) {},
                  onNodeFocus: (_) {},
                  onNodeSelect: (_) {},
                  onClearHistory: () {},
                  scrollController: ScrollController(),
                  quizMode: true,
                  listBottomInset: _barHeight,
                  listFooter: WordQuizCard(
                    quiz: const {
                      'quiz_type': 'cloze',
                      'quiz_data': {
                        'prompt_en': _longPrompt,
                        'context_ko': _longContext,
                        'target_expression': 'systematisiert',
                      },
                    },
                    onSubmit: ({answer, order, selectedIndex}) async =>
                        {'is_correct': false},
                    onNext: () {},
                    onExit: () {},
                    externalResult: externalResult,
                  ),
                ),
              ),
              // The docked composer, over the sheet's bottom edge.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _barHeight,
                child: const ColoredBox(color: Color(0xFF202020)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final screenHeight in const [740.0, 844.0]) {
    for (final inset in const [0.0, 291.0, 336.0]) {
      testWidgets(
        'word quiz clears the composer at ${screenHeight}h / ${inset}px keyboard',
        (tester) async {
          tester.view.physicalSize = Size(390, screenHeight);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            _host(screenHeight: screenHeight, inset: inset),
          );
          await tester.pump();

          expect(tester.takeException(), isNull);

          final card = tester.getRect(
            find.byKey(const ValueKey('quiz-card-shell')),
          );
          final composerTop = (screenHeight - inset) - _barHeight;

          // The whole point: nothing the learner has to read or type into may
          // sit under the composer, and the composer sits on the keyboard.
          expect(
            card.bottom,
            lessThanOrEqualTo(composerTop),
            reason: 'quiz card runs ${card.bottom - composerTop}px past the '
                'composer at inset $inset',
          );
          expect(card.top, greaterThanOrEqualTo(0));
        },
      );
    }
  }

  // Clearing the composer was never the whole problem. With the keyboard up the
  // card holds ~340px of a ~500px question and scrolls the rest, and a graded
  // attempt appends its verdict *below* the question — outside that 340px. The
  // word quiz types into the docked composer, so there is no tap inside the
  // card to bring the verdict up: the learner answered, was told nothing they
  // could see, and answered again. The card has to steer its own scroll.
  testWidgets('a wrong answer scrolls its feedback into view', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(screenHeight: 844, inset: 336));
    await tester.pump();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('quiz-card-shell')),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsWidgets);
    expect(
      tester.state<ScrollableState>(scrollable.first).position.pixels,
      0.0,
      reason: 'the cloze sentence is the right thing to show while answering',
    );

    // The grade arrives from the session controller, not from a tap in here.
    await tester.pumpWidget(
      _host(
        screenHeight: 844,
        inset: 336,
        externalResult: const {'is_correct': false},
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(find.byKey(const ValueKey('quiz-card-shell')));
    final feedback = tester.getRect(find.textContaining('다시', findRichText: true).first);
    expect(
      feedback.bottom,
      lessThanOrEqualTo(card.bottom + 1),
      reason: 'the verdict is below the fold and nothing brought it up',
    );
    expect(feedback.top, greaterThanOrEqualTo(card.top - 1));
  });

  // Shrinking beats scrolling: the learner would rather read all of a smaller
  // card than part of a bigger one. On the reported phone size the whole
  // question — sentence, gloss, and verdict — has to survive the keyboard with
  // nothing left below a fold.
  for (final inset in const [291.0, 336.0]) {
    for (final wrong in const [false, true]) {
      testWidgets(
        'nothing is left below the fold at ${inset}px keyboard (wrong=$wrong)',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(_host(
            screenHeight: 844,
            inset: inset,
            externalResult: wrong ? const {'is_correct': false} : null,
          ));
          await tester.pumpAndSettle();

          final scrollable = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('quiz-card-shell')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            scrollable.position.maxScrollExtent,
            0.0,
            reason: 'the card should have shrunk to fit rather than scroll',
          );

          // The trade has to stay worth taking. Below ~0.7 the text stops being
          // comfortably readable, and scrolling is the better answer.
          final render =
              tester.renderObject<RenderScaleToFit>(find.byType(ScaleToFit));
          expect(render.scale, lessThanOrEqualTo(1.0));
          expect(render.scale, greaterThanOrEqualTo(0.70));
        },
      );
    }
  }

  testWidgets('a question that fits is left at full size', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // No keyboard, so there is nothing to trade away — shrinking here would be
    // a regression, not a fix.
    await tester.pumpWidget(_host(screenHeight: 844, inset: 0));
    await tester.pumpAndSettle();

    final render = tester.renderObject<RenderScaleToFit>(find.byType(ScaleToFit));
    expect(render.scale, 1.0);
  });
}
