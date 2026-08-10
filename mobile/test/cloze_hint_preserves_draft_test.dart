import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/quiz/cloze_quiz_card.dart';

/// Asking for a hint used to wipe the learner's half-typed word.
///
/// The blank rendered its live draft and its hint exclusively, so the screen
/// cleared the shared composer before showing a hint — otherwise the hint would
/// have been invisible behind the draft. From the learner's side, tapping
/// 글자 힌트 silently deleted what they had already typed into that blank.
///
/// The slot now draws both, so these tests pin the two halves of that fix:
/// the draft survives, and the hint is still legible next to it.
void main() {
  const quizData = {
    'prompt_en': 'This clause will ____.',
    'context_ko': '이 조항은 투자자의 권리 행사를 제한합니다.',
    'blank': 'limit investors',
    'target_expression': 'limit investors',
  };

  Widget host({
    required GlobalKey<ClozeQuizCardState> cardKey,
    required String draft,
    List<String> completed = const [],
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ClozeQuizCard(
            key: cardKey,
            quizData: quizData,
            onSubmit: (_) async => true,
            onSolved: () {},
            externalInput: true,
            externalCompletedWords: completed,
            externalLiveDraft: draft,
          ),
        ),
      ),
    );
  }

  testWidgets('a hint keeps the draft and ghosts only the missing tail',
      (tester) async {
    final cardKey = GlobalKey<ClozeQuizCardState>();
    await tester.pumpWidget(host(cardKey: cardKey, draft: 'li'));
    await tester.pump();

    expect(find.text('li'), findsOneWidget);

    // Level 1 (opening letter), then level 2 (the whole word).
    cardKey.currentState!.requestHint();
    await tester.pump();
    cardKey.currentState!.requestHint();
    await tester.pump();

    // The draft is still on screen — this is the regression that mattered.
    expect(find.text('li'), findsOneWidget,
        reason: 'requesting a hint must not discard the typed draft');
    // "li" is a prefix of "limit", so only "mit" is ghosted in.
    expect(find.text('mit'), findsOneWidget);
    expect(find.text('limit'), findsNothing,
        reason: 'the ghost must not repeat the letters already typed');
  });

  testWidgets('a hint on a wrong guess shows the full word beside it',
      (tester) async {
    final cardKey = GlobalKey<ClozeQuizCardState>();
    await tester.pumpWidget(host(cardKey: cardKey, draft: 'zz'));
    await tester.pump();

    cardKey.currentState!.requestHint();
    await tester.pump();
    cardKey.currentState!.requestHint();
    await tester.pump();

    expect(find.text('zz'), findsOneWidget);
    expect(find.text(' · limit'), findsOneWidget,
        reason: 'a non-prefix draft keeps both the guess and the whole hint');
  });

  testWidgets('an empty blank still shows the bare hint', (tester) async {
    final cardKey = GlobalKey<ClozeQuizCardState>();
    await tester.pumpWidget(host(cardKey: cardKey, draft: ''));
    await tester.pump();

    cardKey.currentState!.requestHint();
    await tester.pump();
    cardKey.currentState!.requestHint();
    await tester.pump();

    expect(find.text('limit'), findsOneWidget);
  });
}
