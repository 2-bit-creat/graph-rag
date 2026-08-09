@Tags(['screenshot'])
library;

/// Renders the chat feed and its cards at phone size and writes PNGs.
///
///   QUIZ_SHOT_FONT_DIR=TTF_DIR flutter test \
///       test/chat_feed_screenshot_test.dart --update-goldens
///
///
/// The generated PNGs are NOT committed (see .gitignore): they render journal
/// content and this repository is public. There is therefore no baseline in a
/// fresh clone — run once with --update-goldens to create one locally, then
/// re-run without it to compare against your own baseline.
/// See quiz_card_screenshot_test.dart for why this exists and why the font has
/// to be supplied as TTF. Messages below are real rows from
/// GET /graph/chat/sessions/{id}/messages, with synthetic content.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_suggestions.dart';
import 'package:graphrag_mobile/theme/app_theme.dart';
import 'package:graphrag_mobile/widgets/chat_suggestion_rail.dart';
import 'package:graphrag_mobile/widgets/graph_chat_panel.dart';

final _fontDir = Platform.environment['QUIZ_SHOT_FONT_DIR'] ?? '';
final _skipUnlessFont = _fontDir.isEmpty;

Future<void> _loadAppFont() async {
  if (_fontDir.isEmpty) return;
  final loader = FontLoader('Pretendard');
  var loaded = 0;
  for (final name in ['Pretendard-Regular.ttf', 'Pretendard-Bold.ttf']) {
    final file = File('$_fontDir${Platform.pathSeparator}$name');
    if (file.existsSync()) {
      loader.addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer)));
      loaded++;
    }
  }
  if (loaded == 0) return;
  await loader.load();
}

void _silenceMissingPlugin() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception is MissingPluginException) return;
    previous?.call(details);
  };
}

// Synthetic, but shaped like a real grounded answer: long enough (400+ chars)
// to exercise wrapping over a phone-width sheet, with cited nodes. Fixtures
// never carry a real learner's journal content.
const _assistantAnswer =
    '어제는 아침 산책 이야기를 많이 나눴어. 너가 "요즘 아침에 일어나는 게 왜 이렇게 힘들까?"라고 '
    '물어봤고, 우리는 잠드는 시간이 조금씩 밀린 게 원인일 수 있다는 이야기를 했어. 그래서 저녁 '
    '먹고 나면 30분 정도 동네를 걷기로 했지. 걷고 나면 잠이 더 잘 온다고 느꼈다고도 했고, 주말에는 '
    '조금 더 멀리 걸어보고 싶다고 했어. 커피는 오후 세 시 이후로는 마시지 않기로 한 것도 같이 '
    '정했지. 작은 습관이지만 며칠만 지켜봐도 차이가 보일 것 같네!';

const _nodeIds = [
  '230400b9-0b98-4277-babd-5aaac314013a',
  'b61ca2da-8389-4adb-ba55-0dd3ad55f8b9',
  'bdf14952-6e0d-4974-a9ac-299c7e974bd7',
];

final _nodeById = <String, Map<String, dynamic>>{
  _nodeIds[0]: {'id': _nodeIds[0], 'name': '아침 산책', 'type': 'Concept'},
  _nodeIds[1]: {'id': _nodeIds[1], 'name': '저녁 산책 30분 하기로 함', 'type': 'Statement'},
  _nodeIds[2]: {'id': _nodeIds[2], 'name': '나', 'type': 'Identity'},
};

const _typeColors = <String, Color>{
  'Concept': Color(0xFF9CA3AF),
  'Statement': Color(0xFFA78BFA),
  'Identity': Color(0xFFF59E0B),
  'Person': Color(0xFF3B82F6),
};

Widget _harness({
  required Widget child,
  required Size size,
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    // The real app theme: several widgets read AppShellTheme off the
    // context, and a bare ThemeData leaves them with fallback colours
    // that render nothing.
    theme: buildAppTheme(brightness: brightness),
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(resizeToAvoidBottomInset: false, body: SafeArea(child: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadAppFont);

  const phone = Size(375, 812);

  Widget panel({bool busy = false}) => GraphChatPanel(
        messages: [
          GraphChatMessage(role: 'user', content: '어제 무슨 얘기 했지?'),
          GraphChatMessage(
            role: 'assistant',
            content: _assistantAnswer,
            referencedNodeIds: _nodeIds,
          ),
        ],
        busy: busy,
        typeColors: _typeColors,
        nodeById: _nodeById,
        scrollController: ScrollController(),
        onNodeHighlight: (_) {},
        onNodeSelect: (_) {},
        onClearHistory: () {},
        title: '어제 무슨 얘기 했지?',
      );

  testWidgets('chat feed — grounded answer', (tester) async {
    _silenceMissingPlugin();
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(size: phone, child: panel()));
    // Each row is wrapped in _MessageEntrance, which fades/slides in — a single
    // pump captures it at opacity 0 and the feed renders empty.
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/chat_feed_answer.png'),
    );
  }, skip: _skipUnlessFont);

  testWidgets('chat feed — light', (tester) async {
    _silenceMissingPlugin();
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _harness(size: phone, brightness: Brightness.light, child: panel()),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/chat_feed_light.png'),
    );
  }, skip: _skipUnlessFont);

  testWidgets('chat feed — thinking', (tester) async {
    _silenceMissingPlugin();
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(size: phone, child: panel(busy: true)));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/chat_feed_thinking.png'),
    );
  }, skip: _skipUnlessFont);

  // The rail sits directly above the keyboard, so it is the most thumb-reachable
  // surface in the app — and the one most likely to overflow horizontally.
  testWidgets('suggestion rail', (tester) async {
    _silenceMissingPlugin();
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(
      size: phone,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ChatSuggestionRail(
          suggestions: const [
            ChatSuggestion.action('일기 쓰기', 'journal'),
            ChatSuggestion.prompt('어제 무슨 얘기 했지?'),
            ChatSuggestion.action('단어 퀴즈', 'word'),
            ChatSuggestion.action('작문 퀴즈', 'composition'),
            ChatSuggestion.prompt('이번 주에 배운 표현 정리해줘'),
          ],
          onPrompt: (_) {},
          onAction: (_) {},
        ),
      ),
    ));
    // Each chip starts on a Future.delayed stagger (40ms * index) and then runs
    // a 260ms fade. One pump fires the timers; the next renders the result.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/suggestion_rail.png'),
    );
  }, skip: _skipUnlessFont);
}
