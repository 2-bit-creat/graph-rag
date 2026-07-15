/// Shared journal-entry phase derivation for compose PiP and inline chat tasks.
///
/// Status → phase mapping is identical whether the UI is a minimized window or
/// an in-feed progress card — keep the rules in one place.

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
    label = '받아쓰기 · 정제 중';
  } else if (status == 'graph_processing' || graphStatus == 'graph_processing') {
    phase = ComposePhase.working;
    label = '그래프 초안 생성 중';
  } else if (status == 'failed') {
    phase = ComposePhase.error;
    label = '처리 실패';
  } else if (status == 'graph_failed' || graphStatus == 'graph_failed') {
    phase = ComposePhase.error;
    label = '그래프 생성 실패';
  } else if (status == 'graph_staging_ready' ||
      graphStatus == 'graph_staging_ready') {
    phase = ComposePhase.needsInput;
    label = '그래프 검토 필요';
  } else if (speakers) {
    phase = ComposePhase.needsInput;
    label = '화자 확인 필요';
  } else if (status == 'graph_ready' || graphStatus == 'graph_ready') {
    phase = ComposePhase.done;
    label = '지식그래프 완성';
  } else {
    phase = ComposePhase.done;
    label = '일기 준비 완료';
  }

  return (
    phase: phase,
    label: label,
    speakersPending: speakers,
    graphReviewPending: graphReview,
  );
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

  if (base.phase == ComposePhase.needsInput && base.graphReviewPending) {
    return (
      phase: base.phase,
      label: base.label,
      speakersPending: base.speakersPending,
      graphReviewPending: true,
      awaitingSpeakerAck: false,
    );
  }
  if (status == 'graph_processing' ||
      graphStatus == 'graph_processing' ||
      base.phase == ComposePhase.done ||
      base.phase == ComposePhase.error) {
    return (
      phase: base.phase,
      label: base.label,
      speakersPending: base.speakersPending,
      graphReviewPending: base.graphReviewPending,
      awaitingSpeakerAck: false,
    );
  }

  if (!speakersAcknowledged &&
      status == 'ready' &&
      hasSpeakerScript(entry)) {
    final label = base.speakersPending
        ? '화자 확인 필요'
        : '화자 매칭 확인';
    return (
      phase: ComposePhase.needsInput,
      label: label,
      speakersPending: base.speakersPending,
      graphReviewPending: false,
      awaitingSpeakerAck: true,
    );
  }

  return (
    phase: base.phase,
    label: base.label,
    speakersPending: base.speakersPending,
    graphReviewPending: base.graphReviewPending,
    awaitingSpeakerAck: false,
  );
}
