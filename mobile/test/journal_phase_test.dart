import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/compose/journal_phase.dart';

void main() {
  test('graph_pending is working not done', () {
    final derived = deriveJournalPhase({
      'status': 'ready',
      'graph_status': 'graph_pending',
    });
    expect(derived.phase, ComposePhase.working);
    expect(derived.label, contains('그래프'));
  });

  test('graph_staging_ready needs graph review', () {
    final derived = deriveJournalPhase({
      'status': 'graph_staging_ready',
      'graph_status': 'graph_staging_ready',
    });
    expect(derived.phase, ComposePhase.needsInput);
    expect(derived.graphReviewPending, isTrue);
  });

  test('chat phase holds speaker ack before graph', () {
    final entry = {
      'status': 'ready',
      'graph_status': 'graph_pending',
      'transcript_segments': [
        {'speaker': '나', 'text': '안녕'},
        {'speaker': '엄마', 'text': '10시까지 와'},
      ],
      'speaker_summaries': [
        {'session_label': '나', 'needs_confirmation': false},
        {'session_label': '엄마', 'needs_confirmation': false},
      ],
    };
    final before = deriveChatJournalPhase(entry, speakersAcknowledged: false);
    expect(before.awaitingSpeakerAck, isTrue);
    expect(before.phase, ComposePhase.needsInput);

    final after = deriveChatJournalPhase(entry, speakersAcknowledged: true);
    expect(after.awaitingSpeakerAck, isFalse);
    expect(after.phase, ComposePhase.working);
  });
}
