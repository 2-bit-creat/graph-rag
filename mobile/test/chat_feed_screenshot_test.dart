@Tags(['screenshot'])
library;

/// Renders the chat feed and its cards at phone size and writes PNGs.
///
///   QUIZ_SHOT_FONT_DIR=TTF_DIR flutter test \
///       test/chat_feed_screenshot_test.dart --update-goldens
///
/// See quiz_card_screenshot_test.dart for why this exists and why the font has
/// to be supplied as TTF. Messages below are real rows from
/// GET /graph/chat/sessions/{id}/messages.
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

// A real grounded answer: 432 characters citing 13 graph nodes. Long answers
// over a phone-width sheet are where the feed is most likely to break.
const _assistantAnswer =
    '어제는 AHP 관련해서 여러 가지 이야기를 나눈 것 같아. 너가 "AHP 가중치 산출 쪽에서 구체적으로 어떤 '
    '문제가 발생하게 되나요?"라고 물어봤고, 부부장님은 "딜과 산업을 모두 반영하는 전수 개방안을 [1안: 비교안]'
    '으로 열어두고, AHP 유효성과 운영 효율성을 갖춘 모듈형을 [2안: 최종 제안안]으로 둬서 두 안의 장단점을 '
    '비교하는 방향으로 보고서를 작성하는 건 어때?"라고 제안했어. 또 딜 영역의 평가항목이나 기준값을 산업마다 '
    '다르게 설정하면 AHP 가중치 설정에 문제가 생길 수 있다고도 했고, 심사역들에게 산업별로 AHP 설문을 수백 번 '
    '따로 돌려야 한다고 언급했지. 너는 딜 영역의 산업성 리스크를 차단하는 데 집중하느라 AHP 산식의 수학적 '
    '유효성이나 심사역들의 현업 운영 피로도는 깊게 고려하지 못했다고 했어. 꽤 바쁘고 중요한 논의가 있었던 것 같네!';

const _nodeIds = [
  '230400b9-0b98-4277-babd-5aaac314013a',
  'b61ca2da-8389-4adb-ba55-0dd3ad55f8b9',
  'bdf14952-6e0d-4974-a9ac-299c7e974bd7',
];

final _nodeById = <String, Map<String, dynamic>>{
  _nodeIds[0]: {'id': _nodeIds[0], 'name': 'AHP 가중치', 'type': 'Concept'},
  _nodeIds[1]: {'id': _nodeIds[1], 'name': '부부장님의 모듈형 제안', 'type': 'Statement'},
  _nodeIds[2]: {'id': _nodeIds[2], 'name': '부부장', 'type': 'Identity'},
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
          GraphChatMessage(role: 'user', content: '어제 뭐했지?'),
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
        title: '어제 뭐했지?',
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
            ChatSuggestion.prompt('어제 뭐했지?'),
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
