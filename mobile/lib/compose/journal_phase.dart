// Shared journal-entry phase derivation for compose PiP and inline chat tasks.
//
// Status → phase mapping is identical whether the UI is a minimized window or
// an in-feed progress card — keep the rules in one place.

import '../l10n/app_strings.dart';

/// Session stage — mini-card badge/label and auto-minimize decisions.
///
/// [working] is pure wait (AI processing); [needsInput] needs user action
/// (speaker confirm / graph review). Mini cards use different colors/icons, so
/// these must not collapse into a single "loading" state.
enum ComposePhase { composing, working, needsInput, done, error }

/// Whether any speaker summary still needs confirmation.
bool speakersPending(Map<String, dynamic>? entry) {
  final summaries = entry?['speaker_summaries'] as List<dynamic>? ?? [];
  for (final raw in summaries) {
    if (raw is Map && raw['needs_confirmation'] == true) return true;
  }
  return false;
}

/// The reviewed draft is being committed into graph nodes on the server.
///
/// A separate state from `graph_processing` (draft extraction) because the two
/// mean different things to the user: one is "AI가 초안을 만드는 중", the other is
/// "확정 중". The commit runs as a background task, so this is what the client
/// polls on instead of holding a request open past its timeout.
bool isGraphCommitting(Map<String, dynamic>? entry) {
  final status = entry?['status']?.toString() ?? '';
  final graphStatus = entry?['graph_status']?.toString() ?? '';
  return status == 'graph_committing' || graphStatus == 'graph_committing';
}

/// Graph draft is ready and waiting for user review/commit.
bool isGraphReviewPending(Map<String, dynamic>? entry) {
  final status = entry?['status']?.toString() ?? '';
  final graphStatus = entry?['graph_status']?.toString() ?? '';
  return status == 'graph_staging_ready' || graphStatus == 'graph_staging_ready';
}

/// Derive UI phase + label from a journal entry payload.
({
  ComposePhase phase,
  String label,
  bool speakersPending,
  bool graphReviewPending,
}) deriveJournalPhase(Map<String, dynamic>? entry) {
  final status = entry?['status']?.toString() ?? '';
  final graphStatus = entry?['graph_status']?.toString() ?? '';
  final speakers = speakersPending(entry);
  final graphReview = isGraphReviewPending(entry);

  late final ComposePhase phase;
  late final String label;

  if (status == 'processing') {
    phase = ComposePhase.working;
    label = tr('journal.stageTranscribing');
  } else if (status == 'graph_committing' || graphStatus == 'graph_committing') {
    phase = ComposePhase.working;
    label = tr('journal.stageGraphCommitting');
  } else if (status == 'graph_processing' || graphStatus == 'graph_processing') {
    phase = ComposePhase.working;
    label = tr('journal.stageGraphDrafting');
  } else if (status == 'failed') {
    phase = ComposePhase.error;
    label = tr('journal.stageFailed');
  } else if (status == 'graph_failed' || graphStatus == 'graph_failed') {
    phase = ComposePhase.error;
    label = tr('journal.stageGraphFailed');
  } else if (status == 'graph_staging_ready' ||
      graphStatus == 'graph_staging_ready') {
    phase = ComposePhase.needsInput;
    label = tr('journal.stageGraphReviewNeeded');
  } else if (speakers) {
    phase = ComposePhase.needsInput;
    label = tr('journal.stageSpeakerConfirmNeeded');
  } else if (status == 'graph_ready' || graphStatus == 'graph_ready') {
    phase = ComposePhase.done;
    label = tr('journal.stageGraphComplete');
  } else {
    phase = ComposePhase.done;
    label = tr('journal.stageReady');
  }

  return (
    phase: phase,
    label: label,
    speakersPending: speakers,
    graphReviewPending: graphReview,
  );
}

/// The server's own reason for a failed step, recorded in `pipeline_trace`.
///
/// `_mark_graph_failed` persists `str(exc)` on the step that blew up, and the
/// entry payload carries the trace — so the cause of a `graph_failed` entry is
/// already on the client and only needed reading.
String? journalTraceError(Map<String, dynamic>? entry) {
  final trace = entry?['pipeline_trace'];
  if (trace is! Map) return null;
  final steps = trace['steps'];
  if (steps is! List) return null;
  for (final raw in steps.reversed) {
    if (raw is! Map) continue;
    final error = raw['error']?.toString().trim();
    if (error != null && error.isNotEmpty && error != 'null') return error;
  }
  return null;
}

bool hasSpeakerScript(Map<String, dynamic>? entry) {
  final segments = entry?['transcript_segments'] as List<dynamic>? ?? [];
  if (segments.isNotEmpty) return true;

  // Precision-text entries also have a speaker: their lines are owned by the
  // person chosen while the text was saved (normally "나").  The entry response
  // can briefly omit transcript_segments while the server refreshes it.  Treating
  // that short-lived response as speaker-less acknowledges the speaker step and
  // lets the automatic graph build skip both review gates.
  //
  // Keep the checkpoint for every text entry until the user explicitly advances
  // it, even when its derived segments have not arrived yet.
  final source = entry?['entry_source']?.toString();
  if (source == 'precision_text') {
    return (entry?['transcript_clean_ko']?.toString().trim().isNotEmpty ?? false) ||
        (entry?['transcript_ko']?.toString().trim().isNotEmpty ?? false);
  }
  return false;
}

({
  ComposePhase phase,
  String label,
  bool speakersPending,
  bool graphReviewPending,
  bool awaitingSpeakerAck,
}) deriveChatJournalPhase(
  Map<String, dynamic>? entry, {
  required bool speakersAcknowledged,
}) {
  final base = deriveJournalPhase(entry);
  if (entry == null) {
    return (
      phase: base.phase,
      label: base.label,
      speakersPending: base.speakersPending,
      graphReviewPending: base.graphReviewPending,
      awaitingSpeakerAck: false,
    );
  }

  final status = entry['status']?.toString() ?? '';
  final graphStatus = entry['graph_status']?.toString() ?? '';
  final graphBuilt = status == 'graph_ready' || graphStatus == 'graph_ready';
  final committing = isGraphCommitting(entry);
  final graphInFlight =
      status == 'graph_processing' || graphStatus == 'graph_processing';

  // 1) A committed graph is the ONLY "done". The inline pipeline used to treat a
  //    bare `ready` entry (transcribed/cleaned, no graph yet) as done via the
  //    deriveJournalPhase fallback — reporting "지식그래프 완성" for an entry whose
  //    graph was never built. The pipeline is complete only once the draft has
  //    actually been reviewed and applied.
  if (graphBuilt) {
    return (
      phase: ComposePhase.done,
      label: base.label,
      speakersPending: base.speakersPending,
      graphReviewPending: false,
      awaitingSpeakerAck: false,
    );
  }

  // 2) Hard failures surface as-is.
  if (base.phase == ComposePhase.error) {
    return (
      phase: base.phase,
      label: base.label,
      speakersPending: base.speakersPending,
      graphReviewPending: base.graphReviewPending,
      awaitingSpeakerAck: false,
    );
  }

  // 2.5) The user approved the draft and the server is committing it. The
  //      draft is still stored (so a failed commit can be retried), which is
  //      why this is checked before the review gate below.
  if (committing) {
    return (
      phase: ComposePhase.working,
      label: tr('journal.stageGraphCommitting'),
      speakersPending: base.speakersPending,
      graphReviewPending: false,
      awaitingSpeakerAck: false,
    );
  }

  // 3) A draft is staged and waiting for the user's review/commit.
  if (base.graphReviewPending) {
    return (
      phase: ComposePhase.needsInput,
      label: base.label,
      speakersPending: base.speakersPending,
      graphReviewPending: true,
      awaitingSpeakerAck: false,
    );
  }

  // 4) The graph draft is being generated.
  if (graphInFlight) {
    return (
      phase: ComposePhase.working,
      label: tr('journal.stageGraphDrafting'),
      speakersPending: base.speakersPending,
      graphReviewPending: false,
      awaitingSpeakerAck: false,
    );
  }

  // 5) Still transcribing / cleaning up (status == 'processing').
  if (base.phase == ComposePhase.working) {
    return (
      phase: ComposePhase.working,
      label: base.label,
      speakersPending: base.speakersPending,
      graphReviewPending: false,
      awaitingSpeakerAck: false,
    );
  }

  // 6/7) A transcribed `ready` entry that has text but no graph yet. (Other
  //    terminal-ish states like `ready_no_graph` — empty transcription with no
  //    buildable text — fall through to the base phase below.)
  if (status == 'ready') {
    // Require an EXPLICIT speaker confirmation before building — always, even
    // for single-speaker "나" entries the backend auto-confirms. Without this
    // gate the `ready`→done fallback silently skipped confirmation and the
    // graph was never built.
    if (!speakersAcknowledged && hasSpeakerScript(entry)) {
      final label = base.speakersPending
          ? tr('journal.stageSpeakerConfirmNeeded')
          : tr('journal.stageSpeakerMatchConfirm');
      return (
        phase: ComposePhase.needsInput,
        label: label,
        speakersPending: base.speakersPending,
        graphReviewPending: false,
        awaitingSpeakerAck: true,
      );
    }
    // Speakers acknowledged (or none to confirm) but the graph draft hasn't
    // started yet — the auto-build is about to run. Never report this
    // intermediate state as "완성"; keep it as work-in-progress.
    return (
      phase: ComposePhase.working,
      label: tr('journal.stageGraphDrafting'),
      speakersPending: base.speakersPending,
      graphReviewPending: false,
      awaitingSpeakerAck: false,
    );
  }

  // Anything else (e.g. `ready_no_graph`) — no graph to build; pass through.
  return (
    phase: base.phase,
    label: base.label,
    speakersPending: base.speakersPending,
    graphReviewPending: base.graphReviewPending,
    awaitingSpeakerAck: false,
  );
}
