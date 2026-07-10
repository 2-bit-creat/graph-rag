/// Parses assistant chat text with LaTeX + lightweight markdown.
library;

enum ChatMessagePartKind { text, displayMath }

class ChatMessagePart {
  const ChatMessagePart.text(this.content) : kind = ChatMessagePartKind.text;

  const ChatMessagePart.displayMath(this.content)
      : kind = ChatMessagePartKind.displayMath;

  final ChatMessagePartKind kind;
  final String content;
}

enum ChatInlinePartKind { text, bold, inlineMath }

class ChatInlinePart {
  const ChatInlinePart(this.kind, this.content);

  final ChatInlinePartKind kind;
  final String content;
}

final _displayMathPattern =
    RegExp(r'\\\[([\s\S]*?)\\\]|\$\$([\s\S]*?)\$\$');

/// Split block-level display math from surrounding prose.
List<ChatMessagePart> splitChatMessageParts(String input) {
  if (input.isEmpty) return const [ChatMessagePart.text('')];

  final parts = <ChatMessagePart>[];
  var cursor = 0;
  for (final match in _displayMathPattern.allMatches(input)) {
    if (match.start > cursor) {
      parts.add(ChatMessagePart.text(input.substring(cursor, match.start)));
    }
    final latex = (match.group(1) ?? match.group(2) ?? '').trim();
    if (latex.isNotEmpty) {
      parts.add(ChatMessagePart.displayMath(latex));
    }
    cursor = match.end;
  }
  if (cursor < input.length) {
    parts.add(ChatMessagePart.text(input.substring(cursor)));
  }
  return parts.isEmpty ? [ChatMessagePart.text(input)] : parts;
}

final _inlineMathPattern = RegExp(r'\\\((.+?)\\\)|\$([^\$\n]+?)\$');
final _boldPattern = RegExp(r'\*\*(.+?)\*\*');

/// Inline bold + inline math within a prose block.
List<ChatInlinePart> parseChatInlineParts(String input) {
  if (input.isEmpty) return const [];

  final parts = <ChatInlinePart>[];
  var cursor = 0;
  for (final match in _inlineMathPattern.allMatches(input)) {
    if (match.start > cursor) {
      parts.addAll(_parseBoldSegments(input.substring(cursor, match.start)));
    }
    final latex = (match.group(1) ?? match.group(2) ?? '').trim();
    if (latex.isNotEmpty) {
      parts.add(ChatInlinePart(ChatInlinePartKind.inlineMath, latex));
    }
    cursor = match.end;
  }
  if (cursor < input.length) {
    parts.addAll(_parseBoldSegments(input.substring(cursor)));
  }
  return parts;
}

List<ChatInlinePart> _parseBoldSegments(String chunk) {
  if (chunk.isEmpty) return const [];

  final parts = <ChatInlinePart>[];
  var cursor = 0;
  for (final match in _boldPattern.allMatches(chunk)) {
    if (match.start > cursor) {
      parts.add(ChatInlinePart(ChatInlinePartKind.text, chunk.substring(cursor, match.start)));
    }
    final bold = match.group(1) ?? '';
    if (bold.isNotEmpty) {
      parts.add(ChatInlinePart(ChatInlinePartKind.bold, bold));
    }
    cursor = match.end;
  }
  if (cursor < chunk.length) {
    parts.add(ChatInlinePart(ChatInlinePartKind.text, chunk.substring(cursor)));
  }
  return parts;
}

/// Trim and lightly normalize LLM LaTeX for flutter_math.
String normalizeChatLatex(String latex) {
  var s = latex.trim();
  // Some models double-escape backslashes in JSON payloads.
  if (s.contains(r'\\frac') || s.contains(r'\\text')) {
    s = s.replaceAll(r'\\', r'\');
  }
  return s;
}
