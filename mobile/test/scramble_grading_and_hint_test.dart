/// The scramble card graded server-side: what the learner is told, and what a
/// hint does to the board.
///
/// The regression that motivated this: a perfectly ordered sentence rendered
/// as "Incorrect" because the card looked for `is_correct` while the submit
/// endpoint answers with `correct`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_mode_cards.dart';
import 'package:graphrag_mobile/l10n/app_strings.dart';
import 'package:graphrag_mobile/widgets/quiz/quiz_viewport_scope.dart';

const _chunks = [
  {'id': 'c0', 'text': '오늘'},
  {'id': 'c1', 'text': '휴지를'},
  {'id': 'c2', 'text': '주었어요.'},
];

Map<String, dynamic> _scrambleQuiz() => {
      'id': 'quiz-1',
      'quiz_type': 'scramble',
      'question_native': 'Today I gave him tissues.',
      'quiz_data': {'chunks': _chunks, 'language': 'korean'},
    };

Widget _harness(Widget child) => MaterialApp(
      home: Scaffold(
        body: QuizViewportScope(
          availableHeight: 4000,
          child: SingleChildScrollView(child: child),
        ),
      ),
    );

Future<void> _tapChunk(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last);
  await tester.pump();
}

void main() {
  testWidgets('a server-graded correct order reads as correct', (tester) async {
    await tester.pumpWidget(_harness(WordQuizCard(
      quiz: _scrambleQuiz(),
      // Exactly what POST /quiz/{id}/submit answers with.
      onSubmit: ({answer, order, selectedIndex, hintLevel = 0}) async =>
          {'correct': true, 'quality': 4},
      onNext: () {},
      onExit: () {},
    )));

    for (final chunk in _chunks) {
      await _tapChunk(tester, chunk['text']!);
    }
    await tester.tap(find.text(tr('common.confirm')));
    await tester.pumpAndSettle();

    expect(find.text(tr('chat.correctAnswer')), findsOneWidget);
    expect(find.text(tr('chat.incorrectAnswer')), findsNothing);
  });

  testWidgets('a wrong order still reads as incorrect', (tester) async {
    await tester.pumpWidget(_harness(WordQuizCard(
      quiz: _scrambleQuiz(),
      onSubmit: ({answer, order, selectedIndex, hintLevel = 0}) async =>
          {'correct': false, 'quality': 1},
      onNext: () {},
      onExit: () {},
    )));

    for (final chunk in _chunks.reversed) {
      await _tapChunk(tester, chunk['text']!);
    }
    await tester.tap(find.text(tr('common.confirm')));
    await tester.pumpAndSettle();

    expect(find.text(tr('chat.incorrectAnswer')), findsOneWidget);
  });

  testWidgets('a hint places the prefix, locks it, and travels with the attempt',
      (tester) async {
    int? submittedHintLevel;
    List<String>? submittedOrder;

    await tester.pumpWidget(_harness(WordQuizCard(
      quiz: _scrambleQuiz(),
      onHint: (level) async => {
        'hint_level': level,
        'ordered_prefix': ['c0'],
        'max_hint_level': 1,
      },
      onSubmit: ({answer, order, selectedIndex, hintLevel = 0}) async {
        submittedHintLevel = hintLevel;
        submittedOrder = order;
        return {'correct': true, 'quality': 4};
      },
      onNext: () {},
      onExit: () {},
    )));

    // A guess made before the hint is rolled back so the board agrees with it.
    await _tapChunk(tester, '주었어요.');
    await tester.tap(find.text(tr('scrambleCard.hint')));
    await tester.pumpAndSettle();

    // The locked chunk cannot be taken back out of the answer row.
    await _tapChunk(tester, '오늘');
    await tester.pump();

    await _tapChunk(tester, '휴지를');
    await _tapChunk(tester, '주었어요.');
    await tester.tap(find.text(tr('common.confirm')));
    await tester.pumpAndSettle();

    expect(submittedOrder, ['c0', 'c1', 'c2']);
    expect(submittedHintLevel, 1);
  });

  testWidgets('the hint button stops at the backend ceiling', (tester) async {
    await tester.pumpWidget(_harness(WordQuizCard(
      quiz: _scrambleQuiz(),
      onHint: (level) async => {
        'hint_level': level,
        'ordered_prefix': ['c0'],
        'max_hint_level': 1,
      },
      onSubmit: ({answer, order, selectedIndex, hintLevel = 0}) async =>
          {'correct': true},
      onNext: () {},
      onExit: () {},
    )));

    await tester.tap(find.text(tr('scrambleCard.hint')));
    await tester.pumpAndSettle();

    final button = tester.widget<TextButton>(
      find.ancestor(
        of: find.text(tr('scrambleCard.hint')),
        matching: find.byType(TextButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
