import '../l10n/app_strings.dart';
import 'journal_phase.dart';

enum JournalActivityStage {
  preparing,
  contentReview,
  graphReview,
  committing,
  complete,
  failed
}

enum JournalAttention { none, reviewRequired, error }

class JournalTaskSummary {
  const JournalTaskSummary({
    required this.entryId,
    required this.stage,
    required this.attention,
    required this.label,
    required this.step,
  });

  final String? entryId;
  final JournalActivityStage stage;
  final JournalAttention attention;
  final String label;
  final int step;

  bool get working =>
      stage == JournalActivityStage.preparing ||
      stage == JournalActivityStage.committing;
}

JournalTaskSummary journalTaskSummary({
  required String? entryId,
  required Map<String, dynamic>? entry,
  required ComposePhase phase,
  required String stageLabel,
  required bool awaitingSpeakerAck,
  required bool speakerReviewOverride,
}) {
  final status = entry?['status']?.toString() ?? '';
  final graphStatus = entry?['graph_status']?.toString() ?? '';
  final graphReview = isGraphReviewPending(entry) &&
      !speakerReviewOverride &&
      !awaitingSpeakerAck;

  if (phase == ComposePhase.error) {
    return JournalTaskSummary(
      entryId: entryId,
      stage: JournalActivityStage.failed,
      attention: JournalAttention.error,
      label: stageLabel.isEmpty ? tr('journalActivity.failed') : stageLabel,
      step: status == 'graph_failed' || graphStatus == 'graph_failed' ? 2 : 0,
    );
  }
  if (phase == ComposePhase.done) {
    return JournalTaskSummary(
      entryId: entryId,
      stage: JournalActivityStage.complete,
      attention: JournalAttention.none,
      label: tr('journalActivity.complete'),
      step: 3,
    );
  }
  if (phase == ComposePhase.needsInput) {
    return JournalTaskSummary(
      entryId: entryId,
      stage: graphReview
          ? JournalActivityStage.graphReview
          : JournalActivityStage.contentReview,
      attention: JournalAttention.reviewRequired,
      label: graphReview
          ? tr('journalActivity.graphReview')
          : tr('journalActivity.contentReview'),
      step: graphReview ? 2 : 1,
    );
  }
  final committing = isGraphCommitting(entry);
  return JournalTaskSummary(
    entryId: entryId,
    stage: committing
        ? JournalActivityStage.committing
        : JournalActivityStage.preparing,
    attention: JournalAttention.none,
    label: stageLabel.isEmpty ? tr('journalActivity.preparing') : stageLabel,
    step: committing ||
            status == 'graph_processing' ||
            graphStatus == 'graph_processing'
        ? 2
        : 0,
  );
}
