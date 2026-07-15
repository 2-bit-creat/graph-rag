import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/compose/journal_phase.dart';

void main() {
  test('precision-text journal waits for speaker acknowledgement without segments', () {
    final phase = deriveChatJournalPhase(
      {
        'entry_source': 'precision_text',
        'status': 'ready',
        'transcript_clean_ko': '연말쯤 다시 도전해 보기로 했다.',
        // The first response can omit this while the server refreshes it.
        'transcript_segments': <dynamic>[],
      },
      speakersAcknowledged: false,
    );

    expect(phase.phase, ComposePhase.needsInput);
    expect(phase.awaitingSpeakerAck, isTrue);
  });

  test('speaker acknowledgement still advances a precision-text journal', () {
    final phase = deriveChatJournalPhase(
      {
        'entry_source': 'precision_text',
        'status': 'ready',
        'transcript_ko': '대화를 일기로 정리했다.',
      },
      speakersAcknowledged: true,
    );

    expect(phase.phase, ComposePhase.done);
    expect(phase.awaitingSpeakerAck, isFalse);
  });
}
