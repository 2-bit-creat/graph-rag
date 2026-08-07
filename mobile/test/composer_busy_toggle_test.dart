import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/graph_chat_panel.dart';

/// A 작문 퀴즈 request flips `busy` true→false. While `TextField.enabled` was
/// derived from `busy`, that flip tore down and recreated the platform
/// text-input connection, and on iOS Safari the recreated field never reopened
/// the keyboard — tapping the composer under a freshly loaded quiz card did
/// nothing.
///
/// The invariant these tests protect: `enabled` depends only on the mode-level
/// gate (`inputEnabled`), never on the in-flight `busy` flag. Typing is blocked
/// during a request with `readOnly`, which leaves the connection intact.
TextField _composerField(WidgetTester tester) {
  final fields = tester
      .widgetList<TextField>(find.byType(TextField))
      .where((f) => f.maxLines == null)
      .toList();
  expect(fields, isNotEmpty, reason: 'chat composer TextField not found');
  return fields.first;
}

Widget _bar({required bool busy, bool inputEnabled = true}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatInputBar(
        inputController: TextEditingController(),
        busy: busy,
        onSend: (_) {},
        inputEnabled: inputEnabled,
        inputHint: 'write in English',
      ),
    ),
  );
}

void main() {
  testWidgets('busy does not disable the composer', (tester) async {
    await tester.pumpWidget(_bar(busy: true));
    await tester.pump();

    final field = _composerField(tester);
    expect(field.enabled, isTrue,
        reason: 'disabling on busy is what killed the IME connection');
    expect(field.readOnly, isTrue,
        reason: 'typing must still be blocked while a request is in flight');
  });

  testWidgets('enabled stays stable across a busy true->false transition',
      (tester) async {
    await tester.pumpWidget(_bar(busy: true));
    await tester.pump();
    final duringRequest = _composerField(tester).enabled;

    // The quiz card lands: busy clears.
    await tester.pumpWidget(_bar(busy: false));
    await tester.pump();
    final afterRequest = _composerField(tester);

    expect(duringRequest, afterRequest.enabled,
        reason: 'enabled must not flip false->true when the quiz arrives');
    expect(afterRequest.enabled, isTrue);
    expect(afterRequest.readOnly, isFalse,
        reason: 'the learner can type their answer once the card is shown');
  });

  testWidgets('mode-level gate still disables the field', (tester) async {
    await tester.pumpWidget(_bar(busy: false, inputEnabled: false));
    await tester.pump();

    expect(_composerField(tester).enabled, isFalse,
        reason: 'a solved word quiz has no valid text input');
  });
}
