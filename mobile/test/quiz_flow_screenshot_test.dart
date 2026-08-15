@Tags(['screenshot'])
library;

/// Walks the cloze quiz the way a learner does — read, answer, submit, read the
/// verdict, go on — against the live local backend, capturing each step.
///
/// Run with the same env vars as all_screens_screenshot_test.dart.
///
/// A per-screen capture only ever shows step one. Everything that makes the
/// loop pleasant or annoying (does the verdict push the answer off screen? is
/// the next action reachable without hunting? does the keyboard sit over it?)
/// only appears once the steps are actually taken.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/api/client.dart';
import 'package:graphrag_mobile/screens/quiz_deck_screen.dart';
import 'package:graphrag_mobile/screens/quiz_session_screen.dart';
import 'package:graphrag_mobile/theme/app_theme.dart';

final _fontDir = Platform.environment['QUIZ_SHOT_FONT_DIR'] ?? '';
final _handle = Platform.environment['SHOT_HANDLE'] ?? 'main';
final _skipUnlessFont = _fontDir.isEmpty;

Future<void> _loadFontFile(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer)));
  await loader.load();
}

Future<void> _loadFonts() async {
  if (_fontDir.isEmpty) return;
  await _loadFontFile(
      'Pretendard', '$_fontDir${Platform.pathSeparator}Pretendard-Regular.ttf');
  final icons = Platform.environment['SHOT_ICON_FONT'] ?? '';
  if (icons.isNotEmpty) await _loadFontFile('MaterialIcons', icons);
}

void _silenceMissingPlugin() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception is MissingPluginException) return;
    previous?.call(details);
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const phone = Size(375, 812);

  setUpAll(_loadFonts);

  /// Real time, which a fake-async test body otherwise never lets pass.
  Future<void> settle(WidgetTester t, {int steps = 24}) async {
    for (var i = 0; i < steps; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await t.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('cloze quiz — answer, submit, verdict', (t) async {
    _silenceMissingPlugin();
    HttpOverrides.global = null;

    await t.runAsync(() async {
      HttpOverrides.global = null;
      final token = await apiClient.simpleLogin(_handle, create: false);
      setApiAuthToken(token);
    });

    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.dark),
      home: const MediaQuery(
        data: MediaQueryData(size: phone),
        child: QuizSessionScreen(quizType: 'cloze'),
      ),
    ));
    await settle(t);

    // Step 1 — the card as the learner first meets it.
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/flow_quiz_1_prompt.png'));

    // Step 2 — type an answer. A deliberately wrong one: the wrong path is the
    // one with something to say, and the one a learner sees most.
    final field = find.byType(TextField);
    // ignore: avoid_print
    print('[flow] text fields on the card: ${field.evaluate().length}');
    if (field.evaluate().isNotEmpty) {
      await t.enterText(field.first, 'give back');
      await t.pump(const Duration(milliseconds: 300));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('screenshots/flow_quiz_2_typed.png'));

      // Step 3 — submit and read the verdict.
      final submit = find.byType(FilledButton);
      // ignore: avoid_print
      print('[flow] filled buttons: ${submit.evaluate().length}');
      if (submit.evaluate().isNotEmpty) {
        await t.tap(submit.first, warnIfMissed: false);
        await settle(t, steps: 20);
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('screenshots/flow_quiz_3_verdict.png'));
      }
    }

    // Step 4 — the same verdict with the keyboard up, which is where it is
    // actually read: the learner has just typed, so the inset is still there.
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.dark),
      home: const MediaQuery(
        data: MediaQueryData(
          size: phone,
          viewInsets: EdgeInsets.only(bottom: 336),
        ),
        child: QuizSessionScreen(quizType: 'cloze'),
      ),
    ));
    await settle(t, steps: 20);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/flow_quiz_4_keyboard.png'));
  }, skip: _skipUnlessFont);

  /// Plays a whole 10-question cloze session the way a learner does, and
  /// captures the parts a single-screen shot never reaches: the middle of the
  /// run, and whatever the app says when it is over.
  testWidgets('cloze session — all the way through', (t) async {
    _silenceMissingPlugin();
    HttpOverrides.global = null;

    // Own the item set, so the answers are known before the UI asks for them.
    List<Map<String, dynamic>> items = const [];
    await t.runAsync(() async {
      HttpOverrides.global = null;
      final token = await apiClient.simpleLogin(_handle, create: false);
      setApiAuthToken(token);
      final session =
          await apiClient.startQuizSession(quizType: 'cloze', size: 10);
      items = ((session['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    });
    // ignore: avoid_print
    print('[quiz] session items=${items.length}');
    if (items.isEmpty) return;

    final answers = <String>[
      for (final it in items)
        ((it['quiz_data'] as Map?)?['blank']?.toString() ?? ''),
    ];
    final quizIds = [for (final it in items) it['id'].toString()];

    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.dark),
      home: MediaQuery(
        data: const MediaQueryData(size: phone),
        child: QuizSessionScreen(quizType: 'cloze', quizIds: quizIds),
      ),
    ));
    await settle(t, steps: 24);

    Future<void> waitABit([int steps = 8]) => settle(t, steps: steps);

    for (var i = 0; i < answers.length; i++) {
      final field = find.byType(TextField);
      if (field.evaluate().isEmpty) {
        // ignore: avoid_print
        print('[quiz] q${i + 1}: no field — stopping');
        break;
      }
      await t.enterText(field.first, answers[i]);
      await t.pump(const Duration(milliseconds: 200));

      final submit = find.byType(FilledButton);
      if (submit.evaluate().isEmpty) break;
      await t.tap(submit.first, warnIfMissed: false);
      await waitABit();

      if (i == 4) {
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('screenshots/quiz_run_mid.png'));
      }

      // Advance. The next control is whatever FilledButton is offered once the
      // answer has been graded.
      final next = find.byType(FilledButton);
      if (next.evaluate().isNotEmpty) {
        await t.tap(next.last, warnIfMissed: false);
        await waitABit(6);
      }
      // ignore: avoid_print
      print('[quiz] answered ${i + 1}/${answers.length}');
    }

    await waitABit(10);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/quiz_run_end.png'));
    // ignore: avoid_print
    print('[quiz] finished run');
  }, skip: _skipUnlessFont);

  /// The self-graded deck: flip a card, judge it, reach the end.
  testWidgets('review deck — flip, judge, finish', (t) async {
    _silenceMissingPlugin();
    HttpOverrides.global = null;

    await t.runAsync(() async {
      HttpOverrides.global = null;
      final token = await apiClient.simpleLogin(_handle, create: false);
      setApiAuthToken(token);
    });

    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.dark),
      home: const MediaQuery(
        data: MediaQueryData(size: phone),
        child: QuizDeckScreen(quizType: 'cloze'),
      ),
    ));
    await settle(t, steps: 24);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/deck_1_front.png'));

    // Tap the card to flip it.
    await t.tapAt(const Offset(187, 380));
    await settle(t, steps: 6);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/deck_2_flipped.png'));

    // Judge several cards, alternating the two verdicts.
    for (var i = 0; i < 6; i++) {
      final known = find.text('알아요');
      final again = find.text('다시 볼래요');
      final target = i.isEven ? known : again;
      if (target.evaluate().isEmpty) {
        // ignore: avoid_print
        print('[deck] no verdict buttons at card ${i + 1} — stopping');
        break;
      }
      await t.tap(target.first, warnIfMissed: false);
      await settle(t, steps: 6);
      // ignore: avoid_print
      print('[deck] judged card ${i + 1}');
    }
    await settle(t, steps: 10);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/deck_3_after_judgements.png'));
  }, skip: _skipUnlessFont);
}
