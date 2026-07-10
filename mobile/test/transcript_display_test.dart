import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/transcript_display.dart';

void main() {
  test('formatTranscriptSentenceBoundaries joins multiple sentences', () {
    const text = '첫 문장입니다. 두 번째 문장입니다.';
    expect(
      formatTranscriptSentenceBoundaries(text),
      '첫 문장입니다. · 두 번째 문장입니다.',
    );
  });

  test('single sentence stays unchanged', () {
    const text = '하나뿐인 문장입니다.';
    expect(formatTranscriptSentenceBoundaries(text), text);
  });

  test('line breaks also split statements', () {
    const text = '첫 줄입니다.\n둘째 줄입니다.';
    expect(
      formatTranscriptSentenceBoundaries(text),
      '첫 줄입니다. · 둘째 줄입니다.',
    );
  });
}
