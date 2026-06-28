/// Formats labeled speaker spans into paragraph_text for backend ingest.

class LabeledSpanInput {
  const LabeledSpanInput({
    required this.start,
    required this.end,
    required this.speaker,
  });

  final int start;
  final int end;
  final String speaker;
}

const ignoreSpeaker = '무시';

/// Build `[speaker]: text` lines; excludes ignore spans and unlabeled regions.
String buildParagraphText(String fullText, List<LabeledSpanInput> spans) {
  final usable = spans
      .where((s) => s.speaker != ignoreSpeaker)
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  final lines = <String>[];
  for (final span in usable) {
    final chunk = fullText.substring(span.start, span.end).trim();
    if (chunk.isEmpty) continue;
    lines.add('[${span.speaker}]: $chunk');
  }
  return lines.join('\n');
}

/// Legacy dialogue list (for backward-compatible API fallback).
List<Map<String, String>> buildDialogueFromSpans(
  String fullText,
  List<LabeledSpanInput> spans,
) {
  final usable = spans
      .where((s) => s.speaker != ignoreSpeaker)
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  final lines = <Map<String, String>>[];
  for (final span in usable) {
    final chunk = fullText.substring(span.start, span.end).trim();
    if (chunk.isEmpty) continue;
    if (lines.isNotEmpty && lines.last['speaker'] == span.speaker) {
      lines.last['text'] = '${lines.last['text']} $chunk'.trim();
    } else {
      lines.add({'speaker': span.speaker, 'text': chunk});
    }
  }
  return lines;
}
