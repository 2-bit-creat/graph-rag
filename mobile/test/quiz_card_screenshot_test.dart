@Tags(['screenshot'])
library;

/// Renders the real quiz cards at phone size and writes PNGs.
///
/// Browser automation cannot drive the Flutter canvas reliably, so this is how
/// the cards actually get looked at. Run with:
///
///   flutter test test/quiz_card_screenshot_test.dart --update-goldens
///
/// The payload below is a real card pulled from POST /quiz/session, not a
/// hand-written mock, so what renders is what a learner sees.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_mode_cards.dart';
import 'package:graphrag_mobile/widgets/quiz/quiz_viewport_scope.dart';

/// Korean renders as empty boxes under the test font, which makes a screenshot
/// useless for judging legibility. Load the app's real font.
///
/// FontLoader parses TTF/OTF only — handing it the bundled .woff2 fails
/// silently and you get the box font back, so point QUIZ_SHOT_FONT_DIR at a
/// directory of converted TTFs:
///
///   python -c "from fontTools.ttLib import TTFont; \
///     f=TTFont('fonts/Pretendard-Regular.woff2'); f.flavor=None; \
///     f.save('OUTDIR/Pretendard-Regular.ttf')"
final _fontDir = Platform.environment['QUIZ_SHOT_FONT_DIR'] ?? '';

/// Without the real font every glyph is a box, so the goldens would compare
/// against something nobody can read. Skip rather than fail when it is absent —
/// this is a deliberate, locally-run visual check, not a CI gate.
final _skipUnlessFont = _fontDir.isEmpty;

Future<void> _loadAppFont() async {
  final dir = _fontDir;
  if (dir.isEmpty) return;
  final loader = FontLoader('Pretendard');
  var loaded = 0;
  for (final name in ['Pretendard-Regular.ttf', 'Pretendard-Bold.ttf']) {
    final file = File('$dir${Platform.pathSeparator}$name');
    if (file.existsSync()) {
      loader.addFont(
        Future.value(ByteData.view(file.readAsBytesSync().buffer)),
      );
      loaded++;
    }
  }
  if (loaded == 0) return;
  await loader.load();
}

const _realClozeCard = {
  'quiz_type': 'cloze',
  'question_ko': '‘보장하는 척합니다’라는 뜻에 맞는 표현은 무엇일까요?',
  'quiz_data': {
    'prompt_en': 'They ___ quality to customers.',
    'context_ko':
        "그들은 고객에게 품질을 <span color='#FFA500'>보장하는 척합니다</span>.",
    'blank_display': '_ _ _ _ _ _ _   _ _   g _ _ _ _ _ _ _ _',
    'meaning': '보장하는 척합니다',
    'surface_form': 'pretend to guarantee',
    'sentence_en': 'They pretend to guarantee quality to customers.',
    'sentence_ko': '그들은 고객에게 품질을 보장하는 척합니다.',
    'meaning_parts': [
      {'native': '척하다', 'target': 'pretend'},
      {'native': '보장하다', 'target': 'guarantee'},
    ],
    'hint_ko': '',
    'canonical_form': 'pretend to guarantee',
    'accepted_answers': ['pretend to guarantee'],
    'language': 'english',
  },
};

const _realCompositionCard = {
  'id': 'e5f65d7f-b0b6-41c3-bfcb-5b0b8b9c4ae0',
  'quiz_type': 'composition',
  'question_ko': 'Carve-outs는 계약서상 풋옵션 권리를 보장하는 척한다.',
  'question_native': 'Carve-outs는 계약서상 풋옵션 권리를 보장하는 척한다.',
  'quiz_data': {
    'cefr': 'C2',
    'language': 'english',
    'source_label': '진술 노드',
    'model_answers': [
      {
        'text': 'Carve-outs pretend to guarantee put option rights in the contract.',
        'note': 'This captures the essence of the original statement.',
        'tone': 'neutral',
      },
    ],
    'key_expressions': [
      {
        'expression': 'pretend to guarantee',
        'meaning': '계약서상 풋옵션 권리를 보장해 주는 척하다',
        'example':
            'Carve-outs pretend to guarantee put option rights in the contract.',
      },
    ],
  },
};

Widget _harness({
  required Widget child,
  required Size size,
  required Brightness brightness,
  double textScale = 1.0,
  double quizHeight = 340,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: brightness, fontFamily: 'Pretendard'),
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: QuizViewportScope(availableHeight: quizHeight, child: child),
        ),
      ),
    ),
  );
}

/// The card builds an AudioPlayer for its pronunciation button, and the plugin
/// has no implementation under `flutter test`.
///
/// Its method channels can be answered by name, but each player also opens an
/// EventChannel whose name carries a per-player UUID, so those cannot be stubbed
/// up front. Drop MissingPluginException on the floor instead — this suite
/// renders pixels and never exercises playback.
void _stubAudioPlayers() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (call) async => null,
    );
  }

}

/// Must run INSIDE the test body: testWidgets installs its own
/// FlutterError.onError when the test starts, which would replace anything set
/// in setUpAll.
void _silenceMissingPlugin() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception is MissingPluginException) return;
    previous?.call(details);
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    _stubAudioPlayers();
    await _loadAppFont();
  });

  // iPhone SE / small-Android width is the tightest case the app must survive.
  const phone = Size(375, 812);

  for (final theme in [Brightness.dark, Brightness.light]) {
    final name = theme == Brightness.dark ? 'dark' : 'light';

    testWidgets('cloze card — $name', (tester) async {
      _silenceMissingPlugin();
      await tester.binding.setSurfaceSize(phone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_harness(
        size: phone,
        brightness: theme,
        child: WordQuizCard(
          quiz: _realClozeCard,
          onSubmit: ({answer, order, selectedIndex}) async =>
              {'is_correct': false},
          onNext: () {},
          onExit: () {},
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('screenshots/cloze_card_$name.png'),
      );
    }, skip: _skipUnlessFont);
  }

  // Accessibility text scaling is where fixed-height cards usually break.
  testWidgets('cloze card — dark, text scale 1.3', (tester) async {
    _silenceMissingPlugin();
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(
      size: phone,
      brightness: Brightness.dark,
      textScale: 1.3,
      child: WordQuizCard(
        quiz: _realClozeCard,
        onSubmit: ({answer, order, selectedIndex}) async =>
            {'is_correct': false},
        onNext: () {},
        onExit: () {},
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/cloze_card_scale130.png'),
    );
  }, skip: _skipUnlessFont);

  // 320px is the narrowest phone still in use (iPhone SE 1st gen). The cloze
  // blanks are WidgetSpans sized off the answer's letter count, which cannot
  // shrink after RichText has laid out a line — the width most likely to
  // overflow.
  testWidgets('cloze card — 320px wide', (tester) async {
    _silenceMissingPlugin();
    const narrow = Size(320, 568);
    await tester.binding.setSurfaceSize(narrow);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(
      size: narrow,
      brightness: Brightness.dark,
      child: WordQuizCard(
        quiz: _realClozeCard,
        onSubmit: ({answer, order, selectedIndex}) async =>
            {'is_correct': false},
        onNext: () {},
        onExit: () {},
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/cloze_card_320.png'),
    );
  }, skip: _skipUnlessFont);

  // The solved state carries the parts nobody had looked at: the answer panel,
  // the morpheme breakdown, and the audio controls.
  testWidgets('cloze card — solved', (tester) async {
    _silenceMissingPlugin();
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(
      size: phone,
      brightness: Brightness.dark,
      child: WordQuizCard(
        quiz: _realClozeCard,
        onSubmit: ({answer, order, selectedIndex}) async =>
            {'is_correct': true},
        onNext: () {},
        onExit: () {},
        clozeSolved: true,
        externalResult: const {'is_correct': true},
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/cloze_card_solved.png'),
    );
  }, skip: _skipUnlessFont);

  testWidgets('composition card — unanswered', (tester) async {
    _silenceMissingPlugin();
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(
      size: phone,
      brightness: Brightness.dark,
      child: CompositionDrillCard(
        quiz: _realCompositionCard,
        feedback: null,
        busy: false,
        onNext: () {},
        onExit: () {},
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/composition_card.png'),
    );
  }, skip: _skipUnlessFont);
}
