@Tags(['screenshot'])
library;

/// Drives the journal-writing flow against the live local backend and captures
/// what the user is left looking at.
///
/// Run exactly like all_screens_screenshot_test.dart (same env vars).
///
/// This exists because the static per-screen captures cannot show flow
/// friction: what the composer does while the pipeline runs, and what it says
/// when a stage fails. The failure path is the one reproducible here whenever
/// the backend has no model credentials — which is also precisely what a user
/// on a flaky network sees.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/api/client.dart';
import 'package:graphrag_mobile/theme/app_theme.dart';
import 'package:graphrag_mobile/chat/chat_session_controller.dart';
import 'package:graphrag_mobile/chat/journal_task_controller.dart';
import 'package:graphrag_mobile/compose/journal_phase.dart';
import 'package:graphrag_mobile/screens/graph_review_screen.dart';
import 'package:graphrag_mobile/widgets/journal_progress_card.dart';

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

  testWidgets('journal save failure — what the composer reports', (t) async {
    _silenceMissingPlugin();
    HttpOverrides.global = null;

    // Perform the real save the user's tap performs, and keep the message the
    // app would put on screen.
    String message = '';
    await t.runAsync(() async {
      HttpOverrides.global = null;
      try {
        final token = await apiClient.simpleLogin(_handle, create: false);
        setApiAuthToken(token);
        await apiClient.createTextJournalEntry(
          '오늘 저녁에 팀 회식을 했다. 신입 두 명이 들어와서 다들 긴장했는데 생각보다 금방 '
          '풀렸다. 다음 주부터는 회의에서 의견을 먼저 꺼내보기로 했다.',
        );
        message = '(the save succeeded — no failure to capture)';
      } catch (e) {
        message = e.toString().replaceFirst('Exception: ', '');
      }
    });
    // ignore: avoid_print
    print('[flow] user-visible message: $message');

    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final theme = buildAppTheme(brightness: Brightness.dark);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: MediaQuery(
        data: const MediaQueryData(size: phone),
        child: Scaffold(
          // A scroll view, matching the chat feed: there the card is a list
          // item with unbounded height and shrink-wraps. Given a bounded
          // height instead, its Column (mainAxisSize.max) stretches to fill
          // the screen — a property of the harness, not of the app.
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: JournalSubmissionProgressCard(errorDetail: message),
            ),
          ),
        ),
      ),
    ));
    await t.pump(const Duration(seconds: 1));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/flow_journal_save_failed.png'),
    );
  }, skip: _skipUnlessFont);

  /// Writes a real journal and watches the pipeline the way the composer does.
  ///
  /// The point is the *wait*: the save is synchronous cleanup, then the graph
  /// draft, then a review gate. Each captured frame is what the learner is
  /// actually looking at while that runs.
  testWidgets('journal write — what the wait looks like', (t) async {
    _silenceMissingPlugin();
    HttpOverrides.global = null;

    await t.runAsync(() async {
      HttpOverrides.global = null;
      final token = await apiClient.simpleLogin(_handle, create: false);
      setApiAuthToken(token);
    });

    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final theme = buildAppTheme(brightness: Brightness.dark);
    // The feed shows two different cards across one save: the plain "sending"
    // card until the entry id exists, then the stepper card for that entry.
    Widget host() => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: MediaQuery(
            data: const MediaQueryData(size: phone),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: AnimatedBuilder(
                    animation: journalTask,
                    builder: (context, _) {
                      final id = journalTask.entry?['id']?.toString();
                      return id == null
                          ? const JournalSubmissionProgressCard()
                          : JournalProgressCard(entryId: id);
                    },
                  ),
                ),
              ),
            ),
          ),
        );

    await t.pumpWidget(host());

    // Kick off the real save, then sample the card while it runs.
    Future<void>? work;
    await t.runAsync(() async {
      work = journalTask.submitText(
        '[글쓴이] 오늘 저녁에 팀 회식을 했다. 신입 두 명이 들어와서 다들 긴장했는데 '
        '생각보다 금방 풀렸다. 나는 요즘 회의에서 말을 너무 아끼는 것 같아서 다음 '
        '주부터는 의견을 먼저 꺼내보기로 했다.',
        sourceText: '오늘 저녁에 팀 회식을 했다…',
      );
    });

    final shots = <String>['a', 'b', 'c', 'd', 'e', 'f'];
    for (var i = 0; i < shots.length; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 5)),
      );
      await t.pump(const Duration(milliseconds: 200));
      // ignore: avoid_print
      print('[flow] t=${(i + 1) * 5}s phase=${journalTask.phase} '
          'stage="${journalTask.stageLabel}"');
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('screenshots/flow_write_${i + 1}_${shots[i]}.png'),
      );
    }

    await t.runAsync(() async {
      try {
        await work;
      } catch (e) {
        // ignore: avoid_print
        print('[flow] submit threw: $e');
      }
    });
    // ignore: avoid_print
    print('[flow] final phase=${journalTask.phase} entry=${journalTask.entry?['id']} '
        'status=${journalTask.entry?['status']}');
  }, skip: _skipUnlessFont);

  /// The rest of the journey: speaker gate → graph draft → review ready.
  ///
  /// Continues past where the previous test stops. The graph draft is the long
  /// wait in this app, so this samples the card every five seconds to show what
  /// the learner is left looking at for the duration.
  testWidgets('journal journey — speaker gate to graph review', (t) async {
    _silenceMissingPlugin();
    HttpOverrides.global = null;

    await t.runAsync(() async {
      HttpOverrides.global = null;
      final token = await apiClient.simpleLogin(_handle, create: false);
      setApiAuthToken(token);
    });

    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final theme = buildAppTheme(brightness: Brightness.dark);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: MediaQuery(
        data: const MediaQueryData(size: phone),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: AnimatedBuilder(
                animation: journalTask,
                builder: (context, _) {
                  final id = journalTask.entry?['id']?.toString();
                  return id == null
                      ? const JournalSubmissionProgressCard()
                      : JournalProgressCard(entryId: id);
                },
              ),
            ),
          ),
        ),
      ),
    ));

    String? entryId;
    await t.runAsync(() async {
      final entry = await journalTask.submitText(
        '[글쓴이] 오늘 저녁에 팀 회식을 했다. 신입 두 명이 들어와서 다들 긴장했는데 '
        '생각보다 금방 풀렸다. 나는 요즘 회의에서 말을 너무 아끼는 것 같아서 다음 '
        '주부터는 의견을 먼저 꺼내보기로 했다.',
      );
      entryId = entry['id']?.toString();
    });
    await t.pump(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print('[journey] saved entry=$entryId phase=${journalTask.phase}');
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/journey_1_speaker_gate.png'));

    // Assign the single speaker to 나, the way the chip's sheet does.
    await t.runAsync(() async {
      final fresh = await apiClient.getEntry(entryId!);
      final summaries =
          (fresh['speaker_summaries'] as List?) ?? const <dynamic>[];
      for (final raw in summaries) {
        if (raw is! Map) continue;
        final profileId = raw['speaker_profile_id']?.toString();
        if (profileId == null || profileId.isEmpty) continue;
        await apiClient.speakerConfirm(
          journalEntryId: entryId!,
          speakerProfileId: profileId,
          sessionLabel: raw['session_label']?.toString(),
          asSelf: true,
        );
      }
      await journalTask.refresh(silent: true);
    });
    await t.pump(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print('[journey] after speaker assign phase=${journalTask.phase}');
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/journey_2_speaker_assigned.png'));

    // Acknowledge → this is what kicks off the graph draft.
    await t.runAsync(() async => journalTask.confirmSpeakers());
    await t.pump(const Duration(milliseconds: 300));

    // Sample the wait.
    for (var i = 1; i <= 12; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 5)),
      );
      await t.pump(const Duration(milliseconds: 200));
      final st = journalTask.entry?['status'];
      final gs = journalTask.entry?['graph_status'];
      // ignore: avoid_print
      print('[journey] t=${i * 5}s phase=${journalTask.phase} '
          'stage="${journalTask.stageLabel}" status=$st graph=$gs');
      if (i <= 3 || journalTask.phase == ComposePhase.needsInput) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('screenshots/journey_3_wait_${i}.png'),
        );
      }
      if (journalTask.phase == ComposePhase.needsInput &&
          isGraphReviewPending(journalTask.entry)) {
        // ignore: avoid_print
        print('[journey] graph draft ready at t=${i * 5}s');
        break;
      }
    }

    // ignore: avoid_print
    print('[journey] FINAL entry=$entryId phase=${journalTask.phase} '
        'status=${journalTask.entry?['status']} '
        'graph=${journalTask.entry?['graph_status']}');
    // ignore: avoid_print
    print('[journey] CLEANUP_ID=$entryId');
  }, skip: _skipUnlessFont);

  /// The tail of the journey: draft ready → review screen → commit.
  testWidgets('journal journey — review and commit', (t) async {
    _silenceMissingPlugin();
    HttpOverrides.global = null;

    await t.runAsync(() async {
      HttpOverrides.global = null;
      final token = await apiClient.simpleLogin(_handle, create: false);
      setApiAuthToken(token);
    });

    await t.binding.setSurfaceSize(phone);
    addTearDown(() => t.binding.setSurfaceSize(null));

    final theme = buildAppTheme(brightness: Brightness.dark);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: MediaQuery(
        data: const MediaQueryData(size: phone),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: AnimatedBuilder(
                animation: journalTask,
                builder: (context, _) {
                  final id = journalTask.entry?['id']?.toString();
                  return id == null
                      ? const JournalSubmissionProgressCard()
                      : JournalProgressCard(entryId: id);
                },
              ),
            ),
          ),
        ),
      ),
    ));

    String? entryId;
    await t.runAsync(() async {
      final entry = await journalTask.submitText(
        '오늘 저녁에 팀 회식을 했다. 신입 두 명이 들어와서 다들 긴장했는데 생각보다 '
        '금방 풀렸다. 나는 요즘 회의에서 말을 너무 아끼는 것 같아서 다음 주부터는 '
        '의견을 먼저 꺼내보기로 했다.',
      );
      entryId = entry['id']?.toString();
      final fresh = await apiClient.getEntry(entryId!);
      for (final raw in (fresh['speaker_summaries'] as List?) ?? const []) {
        if (raw is! Map) continue;
        final pid = raw['speaker_profile_id']?.toString();
        if (pid == null || pid.isEmpty) continue;
        await apiClient.speakerConfirm(
          journalEntryId: entryId!,
          speakerProfileId: pid,
          sessionLabel: raw['session_label']?.toString(),
          asSelf: true,
        );
      }
      await journalTask.refresh(silent: true);
    });
    await t.pump(const Duration(milliseconds: 300));
    await t.runAsync(() async => journalTask.confirmSpeakers());
    await t.pump(const Duration(milliseconds: 300));

    // The wait, now with a body and a way out.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
    await t.pump(const Duration(milliseconds: 200));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/journey_fixed_wait.png'));

    for (var i = 0; i < 20; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      await t.pump(const Duration(milliseconds: 200));
      if (isGraphReviewPending(journalTask.entry)) break;
    }
    // ignore: avoid_print
    print('[commit] draft status=${journalTask.entry?['status']}');
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/journey_4_review_ready.png'));

    // Open the review screen on the real staged draft.
    Map<String, dynamic>? staging;
    await t.runAsync(() async {
      final fresh = await apiClient.getEntry(entryId!);
      final raw = fresh['graph_staging'];
      if (raw is Map) staging = Map<String, dynamic>.from(raw);
    });
    // ignore: avoid_print
    print('[commit] claims=${(staging?['claims'] as List?)?.length}');

    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: MediaQuery(
        data: const MediaQueryData(size: phone),
        child: GraphReviewScreen(entryId: entryId!, staging: staging!),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await t.pump(const Duration(milliseconds: 400));
    }
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/journey_5_review_screen.png'));

    // Commit it for real.
    await t.runAsync(() async {
      final claims = ((staging!['claims'] as List?) ?? const [])
          .whereType<Map>()
          .map((c) => Map<String, dynamic>.from(c))
          .toList();
      await apiClient.applyEntryGraph(
        entryId!,
        claims: claims,
        contextType: staging!['context_type']?.toString() ?? '개인일기',
      );
    });
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 8)));

    await t.runAsync(() async {
      final fresh = await apiClient.getEntry(entryId!);
      // ignore: avoid_print
      print('[commit] after apply status=${fresh['status']} '
          'graph=${fresh['graph_status']}');
    });
    // ignore: avoid_print
    print('[commit] CLEANUP_ID=$entryId');
  }, skip: _skipUnlessFont);
}
