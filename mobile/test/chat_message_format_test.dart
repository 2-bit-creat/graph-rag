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
}
