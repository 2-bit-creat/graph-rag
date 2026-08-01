import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../compose/compose_session_controller.dart';
import '../compose/journal_phase.dart';
import '../l10n/app_strings.dart';

/// Headless journal pipeline for inline chat compose.
///
/// PiP와 동일한 게이트: 정제 후 화자 스크립트 확인 → 그래프 초안 → 검토·확정.
/// (자동 그래프 빌드는 화자 확인 완료 후에만.)
class JournalTaskController extends ChangeNotifier {
  String? _entryId;
  Map<String, dynamic>? _entry;
  ComposePhase _phase = ComposePhase.composing;
  String _stageLabel = '';
  Timer? _pollTimer;
  int _workSerial = 0;
  bool _graphBuildStarted = false;
  bool _speakersAcknowledged = false;
  bool _speakerReviewOverride = false;
  String? _lastStatusKey;
  String? _sourceText;
  String? _errorDetail;

  String? get entryId => _entryId;

  /// What actually went wrong, straight from the server, for [ComposePhase.error].
  String? get errorDetail => _errorDetail;

  /// Text the user actually typed for the live entry, so abandoning it can put
  /// the draft back in the composer instead of losing it.
  String? get sourceText => _sourceText;
  Map<String, dynamic>? get entry => _entry;
  ComposePhase get phase => _phase;
  String get stageLabel => _stageLabel;
  bool get speakersAcknowledged => _speakersAcknowledged;

  /// True when user went back from graph review to re-check speakers.
  bool get speakerReviewOverride => _speakerReviewOverride;
  bool get awaitingSpeakerAck =>
      _entry != null &&
      !_speakersAcknowledged &&
      deriveChatJournalPhase(_entry, speakersAcknowledged: false)
          .awaitingSpeakerAck;

  /// True while pipeline needs user attention or AI is working — blocks new saves.
  bool get isBusy =>
      _phase == ComposePhase.working || _phase == ComposePhase.needsInput;

  /// True only while the backend/AI is actively processing (not user review).
  bool get systemProcessing => _phase == ComposePhase.working;

  /// True while the pipeline is waiting on the user (speaker/graph review).
  bool get needsInput => _phase == ComposePhase.needsInput;

  bool get isActive =>
      _entryId != null &&
      _phase != ComposePhase.composing &&
      !(_phase == ComposePhase.done || _phase == ComposePhase.error);

  bool _graphBuildEligible(Map<String, dynamic>? entry, {bool force = false}) {
    if (entry == null || !_speakersAcknowledged) return false;
    final status = entry['status']?.toString() ?? '';
    final graphStatus = entry['graph_status']?.toString() ?? '';
    final restaging = force &&
        (status == 'graph_staging_ready' || graphStatus == 'graph_staging_ready');
    if (status != 'ready' && !restaging) return false;
    if (speakersPending(entry)) return false;
    if (graphStatus == 'graph_pending' || graphStatus.isEmpty) return true;
    if (restaging) return true;
    return false;
  }

  Future<Map<String, dynamic>> submitText(
    String paragraphText, {
    String? attributionKind,
    String? attributionName,
    String? sourceText,
  }) {
    return _runWork(
      tr('journal.stageTranscribing'),
      () => apiClient.createTextJournalEntry(
        paragraphText,
        attributionKind: attributionKind,
        attributionName: attributionName,
      ),
      sourceText: sourceText ?? paragraphText,
    );
  }

  Future<Map<String, dynamic>> uploadAudio(
    String filePath, {
    String? filename,
    String? sourceType,
  }) {
    return _runWork(
      tr('journal.stageTranscribing'),
      () => apiClient.uploadAudio(filePath,
          filename: filename, sourceType: sourceType),
    );
  }

  Future<Map<String, dynamic>> uploadAudioBytes(
    List<int> bytes, {
    required String filename,
    String mimeType = 'audio/wav',
    String? sourceType,
  }) {
    return _runWork(
      tr('journal.stageTranscribing'),
      () => apiClient.uploadAudioBytes(
        bytes,
        filename: filename,
        mimeType: mimeType,
        sourceType: sourceType,
      ),
    );
  }

  Future<Map<String, dynamic>> _runWork(
    String label,
    Future<Map<String, dynamic>> Function() work, {
    String? sourceText,
  }) async {
    final serial = ++_workSerial;
    _pollTimer?.cancel();
    _pollTimer = null;
    _entryId = null;
    _entry = null;
    _sourceText = sourceText;
    _errorDetail = null;
    _graphBuildStarted = false;
    _speakersAcknowledged = false;
    _speakerReviewOverride = false;
    _lastStatusKey = null;
    _phase = ComposePhase.working;
    _stageLabel = label;
    notifyListeners();

    try {
      final result = await work();
      if (serial != _workSerial) return result;
      final entry = await _freshEntryFor(result);
      if (serial != _workSerial) return result;
      _adoptEntry(entry, bumpEntries: true);
      return entry;
    } catch (e) {
      if (serial != _workSerial) rethrow;
      _phase = ComposePhase.error;
      _stageLabel = tr('journal.stageFailed');
      _errorDetail = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _freshEntryFor(
      Map<String, dynamic> result) async {
    final id = result['id']?.toString();
    if (id == null || id.isEmpty) return result;
    try {
      return await apiClient.getEntry(id);
    } catch (_) {
      return result;
    }
  }

  Future<void> refresh({bool silent = true}) async {
    final id = _entryId;
    if (id == null) return;
    try {
      final fresh = await apiClient.getEntry(id);
      if (_entryId != id) return;
      _adoptEntry(fresh);
    } catch (_) {
      // Transient — next poll retries.
    }
  }

  void _recomputePhase() {
    if (_speakerReviewOverride && _entry != null) {
      _phase = ComposePhase.needsInput;
      _stageLabel = speakersPending(_entry)
          ? tr('journal.stageSpeakerConfirmNeeded')
          : tr('journal.stageSpeakerMatchConfirm');
      return;
    }
    final derived = deriveChatJournalPhase(
      _entry,
      speakersAcknowledged: _speakersAcknowledged,
    );
    _phase = derived.phase;
    _stageLabel = derived.label;
  }

  /// 그래프 검토 중 화자가 틀렸을 때 — 화자 확인 단계로 되돌린다.
  void reopenSpeakerConfirm() {
    if (_entryId == null || _entry == null) return;
    _speakerReviewOverride = true;
    _speakersAcknowledged = false;
    _graphBuildStarted = false;
    _recomputePhase();
    notifyListeners();
  }

  void _adoptEntry(Map<String, dynamic> entry, {bool bumpEntries = false}) {
    _entryId = entry['id']?.toString() ?? _entryId;
    _entry = entry;
    if (!hasSpeakerScript(entry)) {
      _speakersAcknowledged = true;
    }
    _recomputePhase();
    if (_phase == ComposePhase.error) {
      // A server-side failure records its reason on the entry's trace; a
      // client-side one was captured at the call site. Either way, show it.
      _errorDetail ??= journalTraceError(entry);
    } else {
      _errorDetail = null;
    }

    final statusKey =
        '${entry['status']}/${entry['graph_status']}/${_phase.name}/$_speakersAcknowledged';
    if (bumpEntries ||
        (_lastStatusKey != null && _lastStatusKey != statusKey)) {
      composeSession.entriesChanged.value++;
    }
    _lastStatusKey = statusKey;

    _maybeAutoBuildGraph();
    _syncPolling();
    notifyListeners();
  }

  /// 화자 스크립트 확인 완료 → PiP의 '지식그래프 만들기' 직전 단계.
  Future<void> confirmSpeakers() async {
    if (_entryId == null || _entry == null) return;
    if (speakersPending(_entry)) return;
    final rebuild = _speakerReviewOverride;
    _speakerReviewOverride = false;
    _speakersAcknowledged = true;
    _recomputePhase();
    _graphBuildStarted = false;
    _maybeAutoBuildGraph(force: rebuild);
    notifyListeners();
  }

  void _maybeAutoBuildGraph({bool force = false}) {
    if (_graphBuildStarted) return;
    if (_entryId == null || !_graphBuildEligible(_entry, force: force)) return;

    _graphBuildStarted = true;
    unawaited(_startGraphBuild(force: force));
  }

  Future<void> _startGraphBuild({bool force = false}) async {
    final id = _entryId;
    if (id == null) return;
    final serial = _workSerial;
    _phase = ComposePhase.working;
    _stageLabel = tr('journal.stageGraphDrafting');
    notifyListeners();

    try {
      await apiClient.buildGraph(id, force: force);
    } catch (e) {
      if (serial != _workSerial || _entryId != id) return;
      _graphBuildStarted = false;
      _phase = ComposePhase.error;
      _stageLabel = tr('journal.stageGraphFailed');
      // Keep what the server actually said. Discarding it left every cause —
      // an unconfirmed speaker, an already-committed graph, a timeout, an
      // extraction error — looking like the same unexplained "그래프 생성 실패".
      _errorDetail = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return;
    }
    if (serial != _workSerial || _entryId != id) return;
    await refresh();
  }

  Future<void> retryGraphBuild() async {
    if (_entryId == null || !_graphBuildEligible(_entry, force: true)) return;
    _graphBuildStarted = false;
    _maybeAutoBuildGraph();
  }

  /// 그래프 검토 화면에서 확정 — PiP [ComposeSessionController.applyGraph]와 동일.
  Future<void> applyGraph(
    String entryId, {
    required List<Map<String, dynamic>> claims,
    required String contextType,
  }) async {
    if (_entryId != entryId) return;
    final serial = ++_workSerial;
    _pollTimer?.cancel();
    _pollTimer = null;
    _phase = ComposePhase.working;
    _stageLabel = tr('journal.stageGraphCommitting');
    notifyListeners();

    try {
      await apiClient.applyEntryGraph(
        entryId,
        claims: claims,
        contextType: contextType,
      );
    } catch (_) {
      if (serial != _workSerial || _entryId != entryId) return;
      _phase = ComposePhase.error;
      _stageLabel = tr('journal.stageGraphCommitFailed');
      notifyListeners();
      return;
    }
    if (serial != _workSerial || _entryId != entryId) return;
    await refresh();
    composeSession.entriesChanged.value++;
  }

  void _syncPolling() {
    final status = _entry?['status']?.toString() ?? '';
    final graphStatus = _entry?['graph_status']?.toString() ?? '';
    final busy = status == 'processing' ||
        status == 'graph_processing' ||
        graphStatus == 'graph_processing' ||
        (_phase == ComposePhase.working && _entryId != null);
    if (busy) {
      _pollTimer ??= Timer.periodic(
        const Duration(seconds: 4),
        (_) => refresh(),
      );
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  /// Stop tracking the current entry and free the pipeline for new work.
  ///
  /// Nothing is deleted server-side: the entry stays in 일기함 with whatever it
  /// had reached, and its chat card falls back to the static (resumable)
  /// rendering. Without [force] this only applies to terminal phases; with it,
  /// a pipeline parked on a user gate (화자 확인 / 그래프 검토) can be set aside
  /// too — otherwise a half-finished entry deadlocks every later save.
  void release({bool force = false}) {
    if (!force &&
        _phase != ComposePhase.done &&
        _phase != ComposePhase.error) {
      return;
    }
    _workSerial++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _entryId = null;
    _entry = null;
    _sourceText = null;
    _errorDetail = null;
    _phase = ComposePhase.composing;
    _stageLabel = '';
    _graphBuildStarted = false;
    _speakersAcknowledged = false;
    _speakerReviewOverride = false;
    _lastStatusKey = null;
    notifyListeners();
  }

  void dismiss() => release();

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

/// App-wide singleton for inline chat journal tasks.
final journalTask = JournalTaskController();
