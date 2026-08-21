/// What the diary composer offers, and where the microphone is honest about
/// not working.
///
/// Two separate complaints, one root: audio controls were shown unconditionally
/// in journal mode. "글로 쓰기" is a typing surface, so a mic and a paperclip
/// parked in front of the caret are dead weight there — and on a plain-http
/// origin the mic is not merely unpermitted, the browser does not expose it at
/// all, so tapping it produced a raw
/// "type 'Null' is not a subtype of type 'JSObject'".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/browser_context.dart';
import 'package:graphrag_mobile/widgets/audio_record_core.dart';
import 'package:graphrag_mobile/widgets/graph_chat_panel.dart';

Widget _host({required bool journalMode, required bool journalAudioTools}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ChatInputBar(
          inputController: TextEditingController(),
          busy: false,
          onSend: (_) {},
          journalMode: journalMode,
          journalAudioTools: journalAudioTools,
          onModeSelected: (_) {},
        ),
      ),
    ),
  );
}

/// The journal composer owns a caret-follow timer. Unmount before the test
/// ends so it is cancelled, or the binding fails on pending timers.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('the typing diary shows no mic and no paperclip', (tester) async {
    await tester.pumpWidget(
        _host(journalMode: true, journalAudioTools: false));
    await tester.pump();

    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    expect(find.byIcon(Icons.attach_file_rounded), findsNothing);
    await _teardown(tester);
  });

  testWidgets('the voice diary keeps them — they are the point of it',
      (tester) async {
    await tester.pumpWidget(_host(journalMode: true, journalAudioTools: true));
    await tester.pump();

    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    expect(find.byIcon(Icons.attach_file_rounded), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('ordinary chat has neither', (tester) async {
    await tester.pumpWidget(
        _host(journalMode: false, journalAudioTools: false));
    await tester.pump();

    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    expect(find.byIcon(Icons.attach_file_rounded), findsNothing);
  });

  group('secure context', () {
    test('native is always allowed to record', () {
      // The test binding reports non-web, which is the native path.
      expect(isSecureBrowserContext, isTrue);
      expect(isMicrophoneBlockedByOrigin, isFalse);
      expect(AudioRecordController.available, isTrue);
    });

    test('the unsupported error carries its own explanation', () {
      const e = RecordingUnsupportedException('mic is blocked here');
      // Call sites print it verbatim instead of wrapping it in
      // "Failed to start recording: ...", so toString has to be the message.
      expect(e.toString(), 'mic is blocked here');
      expect(e.message, 'mic is blocked here');
      expect(e, isA<Exception>());
    });
  });
}
