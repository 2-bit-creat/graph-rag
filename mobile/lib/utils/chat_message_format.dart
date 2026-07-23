/// Parses assistant chat text with LaTeX + lightweight markdown.
library;

enum ChatMessagePartKind { text, displayMath, code }

class ChatMessagePart {
  const ChatMessagePart.text(this.content)
      : kind = ChatMessagePartKind.text,
        language = null;

  const ChatMessagePart.displayMath(this.content)
      : kind = ChatMessagePartKind.displayMath,
        language = null;

  const ChatMessagePart.code(this.content, {this.language})
      : kind = ChatMessagePartKind.code;

  final ChatMessagePartKind kind;
  final String content;

  /// Fenced code-block language tag (e.g. `dart`, `python`), when present.
  final String? language;
}

enum ChatInlinePartKind { text, bold, inlineMath, inlineCode }

class ChatInlinePart {
  const ChatInlinePart(this.kind, this.content);

  final ChatInlinePartKind kind;
  final String content;
}

// Block-level scanner: fenced code fences take precedence over display math so
// math-like text inside a code block is never re-interpreted. Groups:
//   1 = code language, 2 = code body, 3/4 = display-math body.
final _blockPattern = RegExp(
  r'```[ \t]*([\w+#.-]*)[ \t]*\r?\n([\s\S]*?)```'
  r'|\\\[([\s\S]*?)\\\]'
  r'|\$\$([\s\S]*?)\$\$',
);

/// Split block-level code fences and display math from surrounding prose.
List<ChatMessagePart> splitChatMessageParts(String input) {
  if (input.isEmpty) return const [ChatMessagePart.text('')];

  final parts = <ChatMessagePart>[];
  var cursor = 0;
  for (final match in _blockPattern.allMatches(input)) {
    if (match.start > cursor) {
      parts.add(ChatMessagePart.text(input.substring(cursor, match.start)));
    }
    if (match.group(2) != null) {
      final lang = (match.group(1) ?? '').trim();
      final code = match.group(2)!.replaceAll(RegExp(r'\n$'), '');
      parts.add(ChatMessagePart.code(code, language: lang.isEmpty ? null : lang));
    } else {
      final latex = (match.group(3) ?? match.group(4) ?? '').trim();
      if (latex.isNotEmpty) {
        parts.add(ChatMessagePart.displayMath(latex));
      }
    }
    cursor = match.end;
  }
  if (cursor < input.length) {
    parts.add(ChatMessagePart.text(input.substring(cursor)));
  }
  return parts.isEmpty ? [ChatMessagePart.text(input)] : parts;
}

final _inlineCodePattern = RegExp(r'`([^`\n]+?)`');
final _inlineMathPattern = RegExp(r'\\\((.+?)\\\)|\$([^\$\n]+?)\$');
final _boldPattern = RegExp(r'\*\*(.+?)\*\*');

/// Inline code + bold + inline math within a prose block. Inline code binds
/// tightest — its contents are shown verbatim, never re-parsed for math/bold.
List<ChatInlinePart> parseChatInlineParts(String input) {
  if (input.isEmpty) return const [];

  final parts = <ChatInlinePart>[];
  var cursor = 0;
  for (final match in _inlineCodePattern.allMatches(input)) {
    if (match.start > cursor) {
      parts.addAll(_parseMathAndBold(input.substring(cursor, match.start)));
    }
    final code = match.group(1) ?? '';
    if (code.isNotEmpty) {
      parts.add(ChatInlinePart(ChatInlinePartKind.inlineCode, code));
    }
    cursor = match.end;
  }
  if (cursor < input.length) {
    parts.addAll(_parseMathAndBold(input.substring(cursor)));
  }
  return parts;
}

/// Inline math + bold within a code-free chunk.
List<ChatInlinePart> _parseMathAndBold(String input) {
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
