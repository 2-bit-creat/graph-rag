import 'package:flutter/material.dart';

/// Splits transcript text into likely statement-sized sentences.
///
/// Mirrors backend ``_SENT_SPLIT_RE`` but also splits at line breaks so typed
/// multi-line blocks show clear node boundaries in the speaker review UI.
List<String> splitTranscriptSentences(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  final sentences = <String>[];
  for (final line in trimmed.split('\n')) {
    final chunk = line.trim();
    if (chunk.isEmpty) continue;
    final parts = chunk.split(RegExp(r'(?<=[.!?。?！])(?:\s+|$)'));
    for (final part in parts) {
      final s = part.trim();
      if (s.isNotEmpty) sentences.add(s);
    }
  }
  return sentences;
}

/// Joins multiple sentences with a visible middle-dot separator.
String formatTranscriptSentenceBoundaries(String text) {
  final sentences = splitTranscriptSentences(text);
  if (sentences.length <= 1) return text.trim();
  return sentences.join(' · ');
}

/// Rich text with muted middle-dot separators between likely node sentences.
Widget transcriptSentenceText(
  String text, {
  TextStyle? style,
  Color separatorColor = const Color(0x99000000),
}) {
  final sentences = splitTranscriptSentences(text);
  if (sentences.length <= 1) {
    return Text(text, style: style);
  }

  final base = style ?? const TextStyle(fontSize: 14);
  final sepStyle = base.copyWith(
    color: separatorColor,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
  );
  final spans = <InlineSpan>[];
  for (var i = 0; i < sentences.length; i++) {
    if (i > 0) spans.add(TextSpan(text: ' · ', style: sepStyle));
    spans.add(TextSpan(text: sentences[i], style: base));
  }
  return Text.rich(TextSpan(children: spans));
}
