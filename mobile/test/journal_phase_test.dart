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

  test('acknowledged precision-text journal builds the graph (never phantom-done)', () {
    // A bare `ready` entry has been transcribed/cleaned but its graph has NOT
    // been built yet. Once speakers are acknowledged the pipeline moves into
    // graph generation — it must never report "완성" before a graph exists.
    final phase = deriveChatJournalPhase(
      {
        'entry_source': 'precision_text',
        'status': 'ready',
        'transcript_ko': '대화를 일기로 정리했다.',
      },
      speakersAcknowledged: true,
    );

    expect(phase.phase, ComposePhase.working);
    expect(phase.awaitingSpeakerAck, isFalse);
  });

  test('single-speaker "나" entry still requires an explicit speaker confirmation', () {
    // No speaker needs confirmation server-side, yet the gate must still show —
    // the user asked to always confirm the speaker before the graph is built.
    final phase = deriveChatJournalPhase(
      {
        'entry_source': 'precision_text',
        'status': 'ready',
        'transcript_clean_ko': '오늘은 조금 지쳤다.',
      },
      speakersAcknowledged: false,
    );

    expect(phase.phase, ComposePhase.needsInput);
    expect(phase.awaitingSpeakerAck, isTrue);
  });

  test('a committed graph is the only "done"', () {
    final phase = deriveChatJournalPhase(
      {
        'entry_source': 'precision_text',
        'status': 'graph_ready',
        'graph_status': 'graph_ready',
        'transcript_ko': '대화를 일기로 정리했다.',
      },
      speakersAcknowledged: true,
    );

    expect(phase.phase, ComposePhase.done);
    expect(phase.awaitingSpeakerAck, isFalse);
  });

  test('a staged draft waits for review, not completion', () {
    final phase = deriveChatJournalPhase(
      {
        'entry_source': 'precision_text',
        'status': 'graph_staging_ready',
        'graph_status': 'graph_staging_ready',
        'transcript_ko': '대화를 일기로 정리했다.',
      },
      speakersAcknowledged: true,
    );

    expect(phase.phase, ComposePhase.needsInput);
    expect(phase.graphReviewPending, isTrue);
  });
}
