import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/chat_message_format.dart';

void main() {
  test('splits display math blocks', () {
    const input = r'앞 \[ PV = \frac{FCF}{(1 + WACC)^n} \] 뒤';
    final parts = splitChatMessageParts(input);
    expect(parts.length, 3);
    expect(parts[0].kind, ChatMessagePartKind.text);
    expect(parts[1].kind, ChatMessagePartKind.displayMath);
    expect(parts[1].content, contains(r'\frac'));
    expect(parts[2].kind, ChatMessagePartKind.text);
  });

  test('parses inline math and bold', () {
    const input = r'**1. WACC** 는 \( g \) 와 \( FCF_{n} \) 를 씁니다.';
    final parts = parseChatInlineParts(input);
    expect(parts.map((p) => p.kind).toList(), [
      ChatInlinePartKind.bold,
      ChatInlinePartKind.text,
      ChatInlinePartKind.inlineMath,
      ChatInlinePartKind.text,
      ChatInlinePartKind.inlineMath,
      ChatInlinePartKind.text,
    ]);
    expect(parts[0].content, '1. WACC');
    expect(parts[2].content, 'g');
  });

  test('splits fenced code blocks with language and strips trailing newline', () {
    const input = 'before\n```dart\nvoid main() {}\n```\nafter';
    final parts = splitChatMessageParts(input);
    final code = parts.firstWhere((p) => p.kind == ChatMessagePartKind.code);
    expect(code.language, 'dart');
    expect(code.content, 'void main() {}');
  });

  test('does not re-parse math inside a code block', () {
    const input = r'```' '\n' r'x = \(y\) and $z$' '\n' r'```';
    final parts = splitChatMessageParts(input);
    expect(parts.length, 1);
    expect(parts.single.kind, ChatMessagePartKind.code);
    expect(parts.single.language, isNull);
    expect(parts.single.content, contains(r'\(y\)'));
  });

  test('parses inline code verbatim, before bold', () {
    const input = r'run `flutter **build**` now';
    final parts = parseChatInlineParts(input);
    final code =
        parts.firstWhere((p) => p.kind == ChatInlinePartKind.inlineCode);
    expect(code.content, 'flutter **build**');
    // The bold markers inside inline code are NOT interpreted.
    expect(parts.any((p) => p.kind == ChatInlinePartKind.bold), isFalse);
  });
}
