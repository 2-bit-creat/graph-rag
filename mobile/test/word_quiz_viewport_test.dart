import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_mode_cards.dart';
import 'package:graphrag_mobile/widgets/quiz/quiz_viewport_scope.dart';

void main() {
  const longPrompt =
      'Die Vorstellung, dass der Darm und das Gehirn sich gegenseitig beeinflussen, '
      'gibt es schon seit langer Zeit, aber durch die Forschung der letzten 20 Jahre '
      'wurde sie ____.';

  for (final textScale in [1.0, 1.3]) {
    for (final width in [375.0, 390.0, 430.0]) {
      for (final height in [220.0, 280.0, 340.0]) {
        testWidgets(
            'word quiz stays scrollable at ${width}x$height scale $textScale',
            (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 760));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 760),
                  viewInsets: const EdgeInsets.only(bottom: 280),
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
                      onSubmit: ({answer, order, selectedIndex}) async =>
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
        });
      }
    }
  }
}
