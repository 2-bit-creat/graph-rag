import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/compose/journal_activity.dart';
import 'package:graphrag_mobile/compose/journal_phase.dart';

void main() {
  test('ready entry maps to mandatory content and speaker review', () {
    final summary = journalTaskSummary(
      entryId: 'entry-1',
      entry: {
        'status': 'ready',
        'graph_status': 'graph_pending',
        'transcript_segments': [
          {'speaker': '나', 'text': '오늘은 좋았다.'}
        ],
      },
      phase: ComposePhase.needsInput,
      stageLabel: '',
      awaitingSpeakerAck: true,
      speakerReviewOverride: false,
    );

    expect(summary.stage, JournalActivityStage.contentReview);
    expect(summary.attention, JournalAttention.reviewRequired);
    expect(summary.step, 1);
  });

  test('staged graph maps to the second mandatory review', () {
    final summary = journalTaskSummary(
      entryId: 'entry-1',
      entry: {
        'status': 'graph_staging_ready',
        'graph_status': 'graph_staging_ready',
      },
      phase: ComposePhase.needsInput,
      stageLabel: '',
      awaitingSpeakerAck: false,
      speakerReviewOverride: false,
    );

    expect(summary.stage, JournalActivityStage.graphReview);
    expect(summary.attention, JournalAttention.reviewRequired);
    expect(summary.step, 2);
  });

  test('commit stays non-blocking and graph ready is complete', () {
    final committing = journalTaskSummary(
      entryId: 'entry-1',
      entry: {
        'status': 'graph_committing',
        'graph_status': 'graph_committing',
      },
      phase: ComposePhase.working,
      stageLabel: 'committing',
      awaitingSpeakerAck: false,
      speakerReviewOverride: false,
    );
    final complete = journalTaskSummary(
      entryId: 'entry-1',
      entry: {'status': 'graph_ready', 'graph_status': 'graph_ready'},
      phase: ComposePhase.done,
      stageLabel: '',
      awaitingSpeakerAck: false,
      speakerReviewOverride: false,
    );

    expect(committing.stage, JournalActivityStage.committing);
    expect(committing.attention, JournalAttention.none);
    expect(complete.stage, JournalActivityStage.complete);
    expect(complete.step, 3);
  });
}
