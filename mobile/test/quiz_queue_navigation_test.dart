/// Stepping back through a quiz queue.
///
/// The queue used to keep exactly one "current result", cleared on every
/// advance. That is fine while the only move is forward, but the moment a
/// learner can step back to question 1 the verdict has to still be there —
/// otherwise revisiting an answered card shows it blank and invites a second
/// submission of something already graded.
///
/// So: results are keyed by quiz id and survive navigation; only starting or
/// leaving a run clears them.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_session_controller.dart';

Map<String, dynamic> _scramble(String id) => {
      'id': id,
      'quiz_type': 'scramble',
      'quiz_data': {
        'chunks': [
          {'id': '${id}_a', 'text': 'a'},
          {'id': '${id}_b', 'text': 'b'},
        ],
      },
    };

Map<String, dynamic> _cloze(String id, String blank) => {
      'id': id,
      'quiz_type': 'cloze',
      'quiz_data': {'blank': blank},
    };

void main() {
  late ChatSessionController c;

  setUp(() {
    c = ChatSessionController();
    c.debugSeedQuizQueue([_scramble('q1'), _scramble('q2'), _scramble('q3')]);
  });

  tearDown(() => c.dispose());

  test('the first card has nowhere to go back to', () {
    expect(c.canGoPrevQuiz, isFalse);
    expect(c.quizPosition, 1);
    expect(c.quizTotal, 3);
  });

  test('a verdict survives moving forward and back', () {
    c.debugRecordResult({'correct': true, 'quality': 4}, order: ['q1_b', 'q1_a']);
    expect(c.quizFeedback?['correct'], isTrue);

    c.nextQuiz();
    expect(c.quizPosition, 2);
    expect(c.quizFeedback, isNull, reason: 'q2 has not been answered yet');
    expect(c.activeQuizOrder, isNull);
    expect(c.canGoPrevQuiz, isTrue);

    c.prevQuiz();
    expect(c.quizPosition, 1);
    expect(c.quizFeedback?['correct'], isTrue);
    expect(c.wordQuizSolved, isTrue);
    expect(c.activeQuizOrder, ['q1_b', 'q1_a'],
        reason: 'the board must come back the way the learner left it');
  });

  test('a wrong answer is remembered as wrong, not as unanswered', () {
    c.debugRecordResult({'correct': false, 'quality': 1}, order: ['q1_b', 'q1_a']);
    c.nextQuiz();
    c.prevQuiz();
    expect(c.quizFeedback, isNotNull);
    expect(c.quizFeedback?['correct'], isFalse);
    expect(c.wordQuizSolved, isFalse);
  });

  test('results stay attached to their own question', () {
    c.debugRecordResult({'correct': true}, order: ['q1_a', 'q1_b']);
    c.nextQuiz();
    c.debugRecordResult({'correct': false}, order: ['q2_b', 'q2_a']);
    c.nextQuiz();
    expect(c.quizFeedback, isNull);

    c.prevQuiz();
    expect(c.quizFeedback?['correct'], isFalse);
    expect(c.activeQuizOrder, ['q2_b', 'q2_a']);
    c.prevQuiz();
    expect(c.quizFeedback?['correct'], isTrue);
    expect(c.activeQuizOrder, ['q1_a', 'q1_b']);
  });

  test('stepping back past the first card does nothing', () {
    c.prevQuiz();
    expect(c.quizPosition, 1);
    c.nextQuiz();
    c.prevQuiz();
    c.prevQuiz();
    expect(c.quizPosition, 1);
  });

  test('the back control disappears once the run is reseeded', () {
    c.debugRecordResult({'correct': true});
    c.nextQuiz();
    expect(c.canGoPrevQuiz, isTrue);

    c.debugSeedQuizQueue([_scramble('n1'), _scramble('n2')]);
    expect(c.canGoPrevQuiz, isFalse);
    expect(c.quizFeedback, isNull, reason: 'a new run starts with no history');
    expect(c.activeQuizOrder, isNull);
  });

  test('leaving quiz mode forgets the run', () {
    c.debugRecordResult({'correct': true}, order: ['q1_a', 'q1_b']);
    c.setMode(ChatMode.normal);
    expect(c.quizPosition, isNull);
    expect(c.quizFeedback, isNull);

    c.debugSeedQuizQueue([_scramble('q1')]);
    expect(c.quizFeedback, isNull,
        reason: 'the old verdict must not reattach to a reused quiz id');
    expect(c.activeQuizOrder, isNull);
  });

  test('a solved cloze comes back with its words already filled in', () {
    c.debugSeedQuizQueue([_cloze('c1', 'gave him tissues'), _scramble('q2')]);
    c.debugRecordResult({'correct': true});
    expect(c.wordQuizSolved, isTrue);

    c.nextQuiz();
    expect(c.clozeCompletedWords, isEmpty);
    expect(c.clozeLiveDraft, '');

    c.prevQuiz();
    expect(c.clozeCompletedWords, ['gave', 'him', 'tissues']);
  });

  test('an unsolved cloze comes back empty rather than pre-filled', () {
    c.debugSeedQuizQueue([_cloze('c1', 'gave him tissues'), _scramble('q2')]);
    c.debugRecordResult({'correct': false});
    c.nextQuiz();
    c.prevQuiz();
    expect(c.clozeCompletedWords, isEmpty);
  });

  test('navigation notifies listeners so the card rebuilds', () {
    var notifications = 0;
    void listener() => notifications++;
    c.addListener(listener);
    addTearDown(() => c.removeListener(listener));

    c.nextQuiz();
    c.prevQuiz();
    expect(notifications, 2);

    // A refused move must not pretend something changed.
    c.prevQuiz();
    expect(notifications, 2);
  });
}
