import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_mode_cards.dart';
import 'package:graphrag_mobile/widgets/graph_chat_panel.dart';
import 'package:graphrag_mobile/widgets/quiz/quiz_viewport_scope.dart';

void main() {
  const longPrompt =
      'Die Vorstellung, dass der Darm und das Gehirn sich gegenseitig beeinflussen, '
      'gibt es schon seit langer Zeit, aber durch die Forschung der letzten 20 Jahre '
      'wurde sie ____.';

  for (final textScale in [1.0, 1.3]) {
    for (final width in [375.0, 390.0, 430.0]) {
      for (final height in [220.0, 280.0, 340.0]) {
        for (final reportedInset in [0.0, 280.0]) {
          testWidgets(
              'word quiz stays scrollable at ${width}x$height '
              'scale $textScale inset $reportedInset', (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 760));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            await tester.pumpWidget(
              MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 760),
                    viewInsets: EdgeInsets.only(bottom: reportedInset),
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: Scaffold(
                    resizeToAvoidBottomInset: false,
                    body: QuizViewportScope(
                      availableHeight: height,
                      child: WordQuizCard(
                        quiz: const {
                          'quiz_type': 'cloze',
                          'quiz_data': {
                            'prompt_en': longPrompt,
                            'context_ko':
                                '장과 뇌가 서로 영향을 주고받는다는 생각은 오래전부터 존재했지만, 최근 20여 년의 연구로 이를 현대 생물학의 언어로 체계화하게 되었다.',
                            'target_expression': 'systematisiert',
                          },
                        },
                        onSubmit: ({answer, order, selectedIndex, hintLevel = 0}) async =>
                            {'is_correct': false},
                        onNext: () {},
                        onExit: () {},
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();

            expect(tester.takeException(), isNull);
            expect(find.byType(RichText), findsWidgets);
            expect(find.byType(SingleChildScrollView), findsWidgets);
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('quiz-card-shell')))
                  .height,
              lessThanOrEqualTo(height - 4),
            );
          });
        }
      }
    }
  }

  testWidgets('short word quiz keeps its natural height below the viewport cap',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(
          body: QuizViewportScope(
            availableHeight: 600,
            child: WordQuizCard(
              quiz: {
                'quiz_type': 'cloze',
                'quiz_data': {
                  'prompt_en': 'I ____.',
                  'context_ko': '나는 동의한다.',
                  'target_expression': 'agree',
                },
              },
              onSubmit: _unusedSubmit,
              onNext: _unusedCallback,
              onExit: _unusedCallback,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('quiz-card-shell'))).height,
      lessThan(400),
    );
  });

  testWidgets('long word quiz body scrolls within the available height',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuizViewportScope(
            availableHeight: 220,
            child: WordQuizCard(
              quiz: const {
                'quiz_type': 'cloze',
                'quiz_data': {
                  'prompt_en': longPrompt,
                  'context_ko':
                      '장과 뇌가 서로 영향을 주고받는다는 생각은 오래전부터 존재했지만, 최근 연구로 체계화되었다.',
                  'target_expression': 'systematisiert',
                },
              },
              onSubmit: _unusedSubmit,
              onNext: _unusedCallback,
              onExit: _unusedCallback,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final shell = find.byKey(const ValueKey('quiz-card-shell'));
    final scrollable = find.descendant(
      of: shell,
      matching: find.byType(Scrollable),
    );
    final scrollState = tester.state<ScrollableState>(scrollable.first);

    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    await tester.drag(scrollable.first, const Offset(0, -100));
    await tester.pump();
    expect(scrollState.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('word quiz composer receives focus from the real field tap',
      (tester) async {
    final focusNode = FocusNode();
    final inputController = TextEditingController();
    addTearDown(focusNode.dispose);
    addTearDown(inputController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            inputController: inputController,
            busy: false,
            onSend: (_) {},
            modeLabel: '단어 퀴즈',
            inputEnabled: true,
            inputHint: '빈칸에 들어갈 표현을 입력하세요',
            inputFocusNode: focusNode,
          ),
        ),
      ),
    );

    expect(focusNode.hasFocus, isFalse);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('tapping the visible cloze blank focuses the real composer',
      (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              WordQuizCard(
                quiz: const {
                  'quiz_type': 'cloze',
                  'quiz_data': {
                    'prompt_en': 'I ____.',
                    'target_expression': 'agree',
                    'accepted_answers': ['agree'],
                  },
                },
                onSubmit: _unusedSubmit,
                onNext: _unusedCallback,
                onExit: _unusedCallback,
                onClozeInputTap: focusNode.requestFocus,
              ),
              ChatInputBar(
                inputController: TextEditingController(),
                busy: false,
                onSend: (_) {},
                inputEnabled: true,
                inputHint: 'Type the missing expression',
                inputFocusNode: focusNode,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
    await tester.tap(find.byKey(const ValueKey('cloze-active-slot')));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('quiz hint preserves focus while an unrelated tap releases it',
      (tester) async {
    final focusNode = FocusNode();
    final inputController = TextEditingController();
    var hintTaps = 0;
    addTearDown(focusNode.dispose);
    addTearDown(inputController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              GestureDetector(
                key: const ValueKey('outside-control'),
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const SizedBox(width: 160, height: 48),
              ),
              const Spacer(),
              ChatInputBar(
                inputController: inputController,
                busy: false,
                onSend: (_) {},
                modeLabel: 'Word quiz',
                modeActions: GestureDetector(
                  key: const ValueKey('letter-hint'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => hintTaps += 1,
                  child: const SizedBox(
                    height: 36,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text('Letter hint'),
                    ),
                  ),
                ),
                inputEnabled: true,
                inputHint: 'Type the missing expression',
                inputFocusNode: focusNode,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(
      find.byKey(const ValueKey('letter-hint')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(hintTaps, 1);
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(
      find.byKey(const ValueKey('outside-control')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
  });
}

Future<Map<String, dynamic>> _unusedSubmit({
  String? answer,
  List<String>? order,
  int? selectedIndex,
  int hintLevel = 0,
}) async =>
    {'is_correct': false};

void _unusedCallback() {}
