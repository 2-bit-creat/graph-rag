@Tags(['screenshot'])
library;

/// Renders the real quiz cards at phone size and writes PNGs.
///
/// Browser automation cannot drive the Flutter canvas reliably, so this is how
/// the cards actually get looked at. Run with:
///
///   flutter test test/quiz_card_screenshot_test.dart --update-goldens
///
///
/// The generated PNGs are NOT committed (see .gitignore): they render journal
/// content and this repository is public. There is therefore no baseline in a
/// fresh clone — run once with --update-goldens to create one locally, then
/// re-run without it to compare against your own baseline.
/// The payloads below are synthetic but shaped exactly like a real
/// POST /quiz/session card — same fields, same Korean/English mix, same
/// highlight markup. Fixtures never carry a real learner's journal content —
/// what renders here is what a learner sees, without being anyone's diary.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/chat/chat_mode_cards.dart';
import 'package:graphrag_mobile/theme/app_theme.dart';
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
  'question_ko': '‘산책하고 싶어지네요’라는 뜻에 맞는 표현은 무엇일까요?',
  'quiz_data': {
    'prompt_en': 'I ___ after dinner.',
    'context_ko':
        "저녁을 먹고 나면 <span color='#FFA500'>산책하고 싶어집니다</span>.",
    'blank_display': '_ _ _ _   _ _ _ _   _   w _ _ _',
    'meaning': '산책하고 싶어집니다',
    'surface_form': 'feel like taking a walk',
    'sentence_en': 'I feel like taking a walk after dinner.',
    'sentence_ko': '저녁을 먹고 나면 산책하고 싶어집니다.',
    'meaning_parts': [
      {'native': '~하고 싶다', 'target': 'feel like'},
      {'native': '산책하다', 'target': 'take a walk'},
    ],
    'hint_ko': '',
    'canonical_form': 'feel like taking a walk',
    'accepted_answers': ['feel like taking a walk'],
    'language': 'english',
  },
};

const _realCompositionCard = {
  'id': 'e5f65d7f-b0b6-41c3-bfcb-5b0b8b9c4ae0',
  'quiz_type': 'composition',
  'question_ko': '저녁을 먹고 나면 산책하고 싶어집니다.',
  'question_native': '저녁을 먹고 나면 산책하고 싶어집니다.',
  'quiz_data': {
    'cefr': 'C2',
    'language': 'english',
    'source_label': '진술 노드',
    'model_answers': [
      {
        'text': 'I feel like taking a walk after dinner.',
        'note': 'Natural and close to the original nuance.',
        'tone': 'neutral',
      },
    ],
    'key_expressions': [
      {
        'expression': 'feel like -ing',
        'meaning': '~하고 싶어지다',
        'example': 'I feel like taking a walk after dinner.',
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
    // The real app theme: several widgets read AppShellTheme off the
    // context, and a bare ThemeData leaves them with fallback colours
    // that render nothing.
    theme: buildAppTheme(brightness: brightness),
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
