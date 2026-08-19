@Tags(['screenshot'])
library;

/// Renders every screen at phone size against the *live* local backend and
/// writes one PNG per screen. This is the UI/UX audit harness: driving the real
/// app through a browser preview proved unusable (the graph's physics loop
/// never lets the page go idle, so every synthetic click times out), while a
/// widget test renders each screen deterministically at an exact 375x812.
///
/// ```
/// set QUIZ_SHOT_FONT_DIR=...directory holding Pretendard-Regular.ttf
/// set SHOT_ICON_FONT=...path to MaterialIcons-Regular.otf
/// set SHOT_HANDLE=main
/// set SHOT_STAGING_ENTRY=...entry id whose graph_staging is populated
/// set SHOT_LOCALE=en
/// set SHOT_WIDTH=320
/// set SHOT_TEXT_SCALE=1.2
/// flutter test test/all_screens_screenshot_test.dart --update-goldens ^
///     --dart-define=API_BASE_URL=http://localhost:8000
/// ```
///
/// The dart-define is required: `flutter_test` reports `defaultTargetPlatform`
/// as android, so without it the client resolves to the emulator's 10.0.2.2.
///
/// Requires the backend to be up; screens that fail to load are captured in
/// whatever state they reach, because an error/empty state is part of the audit.
/// PNGs are gitignored (mobile/test/screenshots/) — they render real journal
/// content and this repository is public. Run this for Korean and English at
/// compact phone widths to catch localization overflow before a release.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/api/client.dart';
import 'package:graphrag_mobile/chat/chat_sidebar.dart';
import 'package:graphrag_mobile/l10n/app_strings.dart';
import 'package:graphrag_mobile/screens/account_entry_screen.dart';
import 'package:graphrag_mobile/screens/consent_screen.dart';
import 'package:graphrag_mobile/screens/debug_hub_screen.dart';
import 'package:graphrag_mobile/screens/graph_review_screen.dart';
import 'package:graphrag_mobile/screens/quiz_deck_screen.dart';
import 'package:graphrag_mobile/screens/quiz_exploration_screen.dart';
import 'package:graphrag_mobile/screens/quiz_session_screen.dart';
import 'package:graphrag_mobile/screens/quiz_pipeline_hub_screen.dart';
import 'package:graphrag_mobile/screens/accounts_overview_screen.dart';
import 'package:graphrag_mobile/screens/graph_trash_screen.dart';
import 'package:graphrag_mobile/screens/journal_hub_screen.dart';
import 'package:graphrag_mobile/screens/kg_insight_screen.dart';
import 'package:graphrag_mobile/screens/kg_timeline_screen.dart';
import 'package:graphrag_mobile/screens/learning_progress_screen.dart';
import 'package:graphrag_mobile/screens/menu_screen.dart';
import 'package:graphrag_mobile/screens/privacy_policy_screen.dart';
import 'package:graphrag_mobile/screens/quiz_queue_screen.dart';
import 'package:graphrag_mobile/screens/settings_screen.dart';
import 'package:graphrag_mobile/screens/statement_bank_screen.dart';
import 'package:graphrag_mobile/screens/storage_manager_screen.dart';
import 'package:graphrag_mobile/screens/tutor_vocab_screen.dart';
import 'package:graphrag_mobile/screens/vocabulary_hub_screen.dart';
import 'package:graphrag_mobile/theme/app_theme.dart';

final _fontDir = Platform.environment['QUIZ_SHOT_FONT_DIR'] ?? '';
final _handle = Platform.environment['SHOT_HANDLE'] ?? 'main';
final _skipUnlessFont = _fontDir.isEmpty;
final _shotLocale = Platform.environment['SHOT_LOCALE'] == 'en' ? 'en' : 'ko';
final _shotWidth =
    double.tryParse(Platform.environment['SHOT_WIDTH'] ?? '') ?? 375.0;
final _shotHeight =
    double.tryParse(Platform.environment['SHOT_HEIGHT'] ?? '') ?? 812.0;
final _shotTextScale =
    double.tryParse(Platform.environment['SHOT_TEXT_SCALE'] ?? '') ?? 1.0;

Future<void> _loadFontFile(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    // ignore: avoid_print
    print('[shot] missing font: $path');
    return;
  }
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer)));
  await loader.load();
}

Future<void> _loadAppFont() async {
  if (_fontDir.isEmpty) return;
  // Only the regular face is registered. FontLoader has no way to tell the
  // engine which weight a file is, so registering Regular and Bold under one
  // family made the engine pick between them arbitrarily — w600 text (every
  // AppBar title) resolved to a face with no Korean glyphs and rendered as
  // tofu, which looked exactly like a real UI bug. One face plus synthetic
  // bold is unambiguous.
  await _loadFontFile(
      'Pretendard', '$_fontDir${Platform.pathSeparator}Pretendard-Regular.ttf');

  // Without this every Icon() is a tofu box, and a screenshot audit cannot
  // tell a missing glyph from a missing icon.
  final iconsPath = Platform.environment['SHOT_ICON_FONT'] ?? '';
  if (iconsPath.isNotEmpty) await _loadFontFile('MaterialIcons', iconsPath);
}

/// flutter_test installs an HttpOverrides that fails every request. These
/// screens are worth capturing with their real data, so hand the VM back its
/// normal client.
void _allowRealNetwork() => HttpOverrides.global = null;

/// Plugin channels (secure storage, shared_preferences, path_provider) have no
/// implementation in a widget test. Screens call them on the way up; the
/// exception is not what we are auditing.
void _silenceMissingPlugin() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception is MissingPluginException) return;
    previous?.call(details);
  };
}

Widget _harness({
  required Widget child,
  required Size size,
  Brightness brightness = Brightness.dark,
}) {
  final theme = buildAppTheme(brightness: brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(_shotTextScale),
      ),
      // Some of these are tab bodies, not routes (KgInsightScreen lives inside
      // LearningProgressScreen), so they carry no Scaffold and rendered on a
      // bare grey ground here — which reads as a contrast bug that does not
      // exist in the app. Paint the scaffold colour behind every capture.
      child: Material(color: theme.scaffoldBackgroundColor, child: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final phone = Size(_shotWidth, _shotHeight);
  var loggedIn = false;

  setUpAll(() async {
    appLocaleController.setLocaleForTesting(_shotLocale);
    await _loadAppFont();
  });

  /// Signs in once, from inside the real async zone.
  ///
  /// `setUpAll` runs under the test binding's mock `HttpOverrides`, where every
  /// socket is refused no matter what `HttpOverrides.global` is set to — the
  /// login there failed with "서버에 연결할 수 없어요" while curl to the same URL
  /// succeeded. `runAsync` escapes to the real zone, so this is the only place
  /// the request can actually leave the process.
  Future<void> ensureLogin(WidgetTester tester) async {
    if (loggedIn) return;
    await tester.runAsync(() async {
      _allowRealNetwork();
      try {
        final token = await apiClient.simpleLogin(_handle, create: false);
        setApiAuthToken(token);
        loggedIn = true;
        // ignore: avoid_print
        print('[shot] signed in as $_handle');
      } catch (e) {
        // ignore: avoid_print
        print('[shot] LOGIN FAILED: $e');
      }
    });
  }

  /// Pumps [screen] and captures it. Uses timed pumps rather than
  /// pumpAndSettle: these screens keep a progress indicator (or the graph's
  /// physics ticker) running, so settling never completes.
  Future<void> shot(
    WidgetTester tester,
    String name,
    Widget screen, {
    Brightness brightness = Brightness.dark,
    Duration wait = const Duration(seconds: 9),
  }) async {
    _silenceMissingPlugin();
    _allowRealNetwork();
    await ensureLogin(tester);
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _harness(size: phone, brightness: brightness, child: screen),
    );
    // Let the screen's initState futures resolve against the live backend.
    // The test body runs in a fake-async zone, so a bare `Future.delayed` here
    // would never fire — real time only passes inside `runAsync`.
    final steps = (wait.inMilliseconds / 250).ceil();
    for (var i = 0; i < steps; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump(const Duration(milliseconds: 300));

    // Flutter reports RenderFlex overflow as a framework exception. Capturing
    // the screenshot alone made those yellow-striped layouts look like a
    // successful audit, so fail immediately in every locale/viewport run.
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        'screenshots/screen_${_shotLocale}_${_shotWidth.toInt()}x${_shotHeight.toInt()}_${_shotTextScale}_$name.png',
      ),
    );
  }

  group('screens', () {
    testWidgets('account entry', (t) async {
      await shot(t, 'account_entry', const AccountEntryScreen());
    }, skip: _skipUnlessFont);

    testWidgets('menu', (t) async {
      await shot(t, 'menu', const MenuScreen());
    }, skip: _skipUnlessFont);

    testWidgets('menu light', (t) async {
      await shot(t, 'menu_light', const MenuScreen(),
          brightness: Brightness.light);
    }, skip: _skipUnlessFont);

    testWidgets('settings', (t) async {
      await shot(t, 'settings', const SettingsScreen());
    }, skip: _skipUnlessFont);

    testWidgets('vocabulary hub', (t) async {
      await shot(t, 'vocabulary_hub', const VocabularyHubScreen());
    }, skip: _skipUnlessFont);

    testWidgets('tutor vocab', (t) async {
      await shot(t, 'tutor_vocab', const TutorVocabScreen());
    }, skip: _skipUnlessFont);

    testWidgets('learning progress', (t) async {
      await shot(t, 'learning_progress', const LearningProgressScreen());
    }, skip: _skipUnlessFont);

    testWidgets('kg timeline', (t) async {
      await shot(t, 'kg_timeline', const KgTimelineScreen());
    }, skip: _skipUnlessFont);

    testWidgets('kg insight', (t) async {
      await shot(t, 'kg_insight', const KgInsightScreen());
    }, skip: _skipUnlessFont);

    testWidgets('statement bank', (t) async {
      await shot(
          t, 'statement_bank', const StatementBankScreen(language: 'en'));
    }, skip: _skipUnlessFont);

    testWidgets('quiz queue', (t) async {
      await shot(t, 'quiz_queue', const QuizQueueScreen());
    }, skip: _skipUnlessFont);

    testWidgets('storage manager', (t) async {
      await shot(t, 'storage_manager', const StorageManagerScreen());
    }, skip: _skipUnlessFont);

    testWidgets('graph trash', (t) async {
      await shot(t, 'graph_trash', const GraphTrashScreen());
    }, skip: _skipUnlessFont);

    testWidgets('accounts overview', (t) async {
      await shot(t, 'accounts_overview', const AccountsOverviewScreen());
    }, skip: _skipUnlessFont);

    testWidgets('privacy policy', (t) async {
      await shot(t, 'privacy_policy', const PrivacyPolicyScreen());
    }, skip: _skipUnlessFont);

    testWidgets('journal entry detail', (t) async {
      final entryId = Platform.environment['SHOT_STAGING_ENTRY'] ?? '';
      if (entryId.isEmpty) return;
      await shot(t, 'journal_entry_detail',
          JournalEntryDetailScreen(entryId: entryId));
    }, skip: _skipUnlessFont);

    testWidgets('consent', (t) async {
      await shot(t, 'consent', const ConsentScreen());
    }, skip: _skipUnlessFont);

    testWidgets('quiz exploration', (t) async {
      await shot(t, 'quiz_exploration', const QuizExplorationScreen());
    }, skip: _skipUnlessFont);

    testWidgets('quiz pipeline hub', (t) async {
      await shot(t, 'quiz_pipeline_hub', const QuizPipelineHubScreen());
    }, skip: _skipUnlessFont);

    testWidgets('debug hub', (t) async {
      await shot(t, 'debug_hub', const DebugHubScreen());
    }, skip: _skipUnlessFont);

    testWidgets('chat sidebar', (t) async {
      await shot(t, 'chat_sidebar', const ChatSidebar());
    }, skip: _skipUnlessFont);

    // Both of these need arguments a real caller supplies, so they are fetched
    // from the same backend the rest of the screens read.
    testWidgets('graph review', (t) async {
      final entryId = Platform.environment['SHOT_STAGING_ENTRY'] ?? '';
      if (entryId.isEmpty) {
        // ignore: avoid_print
        print('[shot] SHOT_STAGING_ENTRY unset — skipping graph review');
        return;
      }
      Map<String, dynamic>? staging;
      await t.runAsync(() async {
        _allowRealNetwork();
        final entry = await apiClient.getEntry(entryId);
        final raw = entry['graph_staging'];
        if (raw is Map) staging = Map<String, dynamic>.from(raw);
      });
      if (staging == null) {
        // ignore: avoid_print
        print('[shot] entry $entryId has no graph_staging — skipping');
        return;
      }
      await shot(
        t,
        'graph_review',
        GraphReviewScreen(entryId: entryId, staging: staging!),
      );
    }, skip: _skipUnlessFont);

    // Valid types are cloze / composition / scramble / mcq_nuance; anything
    // else falls to a debug string, so the type list is worth keeping in sync.
    testWidgets('quiz deck', (t) async {
      await shot(t, 'quiz_deck', const QuizDeckScreen(quizType: 'cloze'));
    }, skip: _skipUnlessFont);

    testWidgets('quiz session cloze', (t) async {
      await shot(
          t, 'quiz_session_cloze', const QuizSessionScreen(quizType: 'cloze'));
    }, skip: _skipUnlessFont);

    testWidgets('quiz session scramble', (t) async {
      await shot(t, 'quiz_session_scramble',
          const QuizSessionScreen(quizType: 'scramble'));
    }, skip: _skipUnlessFont);

    testWidgets('quiz session composition', (t) async {
      await shot(t, 'quiz_session_composition',
          const QuizSessionScreen(quizType: 'composition'));
    }, skip: _skipUnlessFont);

    testWidgets('learning progress light', (t) async {
      await shot(t, 'learning_progress_light', const LearningProgressScreen(),
          brightness: Brightness.light);
    }, skip: _skipUnlessFont);
  });

  tearDownAll(() {
    // ignore: avoid_print
    print('[shot] logged in: $loggedIn');
  });
}
