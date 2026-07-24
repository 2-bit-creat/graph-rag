import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_session_controller.dart' show ChatMode;
import 'package:graphrag_mobile/chat/chat_suggestions.dart';
import 'package:graphrag_mobile/theme/app_theme.dart';
import 'package:graphrag_mobile/widgets/chat_suggestion_rail.dart';
import 'package:graphrag_mobile/widgets/graph_chat_panel.dart'
    show GraphChatMessage;

GraphChatMessage _msg(String role, String content) =>
    GraphChatMessage(role: role, content: content);

void main() {
  group('chatSuggestionsFor', () {
    test('empty chat offers starters including the journal action', () {
      final s = chatSuggestionsFor(
        mode: ChatMode.normal,
        messages: const [],
        busy: false,
      );
      expect(s, isNotEmpty);
      expect(s.where((e) => e.action == 'journal'), hasLength(1));
      expect(s.where((e) => e.isAction).length, lessThan(s.length),
          reason: 'starters should mix prompts with mode actions');
    });

    test('a busy turn suppresses the rail', () {
      expect(
        chatSuggestionsFor(
            mode: ChatMode.normal, messages: const [], busy: true),
        isEmpty,
      );
    });

    test('every non-normal mode suppresses the rail', () {
      for (final mode in [
        ChatMode.journal,
        ChatMode.quizWord,
        ChatMode.quizComposition,
        ChatMode.distill,
      ]) {
        expect(
          chatSuggestionsFor(mode: mode, messages: const [], busy: false),
          isEmpty,
          reason: '$mode has its own surface; the rail must not float over it',
        );
      }
    });

    test('the first message ends the starter state for good', () {
      // A single user turn is enough — the rail must not come back between
      // turns, which is what made it read as a permanent floating layer.
      expect(
        chatSuggestionsFor(
          mode: ChatMode.normal,
          messages: [_msg('user', '안녕')],
          busy: false,
        ),
        isEmpty,
      );
      expect(
        chatSuggestionsFor(
          mode: ChatMode.normal,
          messages: [_msg('user', '안녕'), _msg('assistant', '반가워요')],
          busy: false,
        ),
        isEmpty,
      );
    });

    test('a saved diary entry also counts as a started conversation', () {
      final journalSubmit = GraphChatMessage(
        role: 'user',
        kind: 'journal_submit',
        content: '오늘 있었던 일',
      );
      expect(
        chatSuggestionsFor(
          mode: ChatMode.normal,
          messages: [journalSubmit],
          busy: false,
        ),
        isEmpty,
      );
    });

    test('non-conversational events keep the starter state', () {
      // A mode banner is chrome, not a conversation — it must not silently
      // consume the starters on a room the user never typed in.
      final banner = GraphChatMessage(
        role: 'assistant',
        kind: 'journal_mode',
        content: '일기 쓰기 모드',
      );
      expect(
        chatSuggestionsFor(
          mode: ChatMode.normal,
          messages: [banner],
          busy: false,
        ),
        isNotEmpty,
      );
    });

    test('a busy journal hides the journal action but keeps the rest', () {
      final s = chatSuggestionsFor(
        mode: ChatMode.normal,
        messages: const [],
        busy: false,
        journalBusy: true,
      );
      expect(s, isNotEmpty);
      expect(s.any((e) => e.action == 'journal'), isFalse);
    });
  });

  group('ChatSuggestionRail', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<ChatSuggestion> suggestions,
      required void Function(String) onPrompt,
      required void Function(String) onAction,
    }) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: ChatSuggestionRail(
            suggestions: suggestions,
            onPrompt: onPrompt,
            onAction: onAction,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('renders every option and routes prompt taps', (tester) async {
      String? sent;
      await pump(
        tester,
        suggestions: const [
          ChatSuggestion.prompt('왜 그렇게 생각해?'),
          ChatSuggestion.action('일기 쓰기', 'journal',
              icon: Icons.auto_stories_rounded),
        ],
        onPrompt: (t) => sent = t,
        onAction: (_) {},
      );

      expect(find.text('왜 그렇게 생각해?'), findsOneWidget);
      expect(find.text('일기 쓰기'), findsOneWidget);

      await tester.tap(find.text('왜 그렇게 생각해?'));
      expect(sent, '왜 그렇게 생각해?');
    });

    testWidgets('action taps route to the mode handler, not send',
        (tester) async {
      String? action;
      String? sent;
      await pump(
        tester,
        suggestions: const [ChatSuggestion.action('단어 퀴즈', 'word')],
        onPrompt: (t) => sent = t,
        onAction: (a) => action = a,
      );

      await tester.tap(find.text('단어 퀴즈'));
      expect(action, 'word');
      expect(sent, isNull);
    });

    testWidgets('an empty option set collapses to nothing', (tester) async {
      await pump(
        tester,
        suggestions: const [],
        onPrompt: (_) {},
        onAction: (_) {},
      );
      expect(find.byType(InkWell), findsNothing);
      expect(tester.getSize(find.byType(ChatSuggestionRail)).height, 0);
    });
  });
}
