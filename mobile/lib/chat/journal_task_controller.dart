import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../compose/journal_phase.dart';

/// Headless journal pipeline for inline chat compose.
///
/// Unlike [ComposeSessionController], this has no window state — it only
/// creates/uploads an entry, polls [getEntry], derives phase, and auto-triggers
/// [buildGraph] once when text entries reach "ready" without a graph yet.
class JournalTaskController extends ChangeNotifier {
  String? _entryId;
  Map<String, dynamic>? _entry;
  ComposePhase _phase = ComposePhase.composing;
  String _stageLabel = '';
  Timer? _pollTimer;
  int _workSerial = 0;
  bool _graphBuildStarted = false;
  String? _lastStatusKey;

  /// 일기 생성/상태 변화 시 증가 — 타임라인·목록 화면의 갱신 트리거.
  final ValueNotifier<int> entriesChanged = ValueNotifier<int>(0);

  bool _recording = false;
  bool get recording => _recording;

  void setRecording(bool value) {
    if (_recording == value) return;
    _recording = value;
    notifyListeners();
  }

  String? get entryId => _entryId;
  Map<String, dynamic>? get entry => _entry;
  ComposePhase get phase => _phase;
  String get stageLabel => _stageLabel;

  /// True while pipeline needs user attention or AI is working — blocks new saves.
  bool get isBusy =>
      _phase == ComposePhase.working || _phase == ComposePhase.needsInput;

  /// True only while the backend/AI is actively processing (not user review).
  bool get systemProcessing => _phase == ComposePhase.working;

  /// True while the chat composer should stay locked to this journal task.
  bool get blocksChat => isBusy;

  bool get isActive =>
      _entryId != null &&
      _phase != ComposePhase.composing &&
      !(_phase == ComposePhase.done || _phase == ComposePhase.error);

  bool _graphBuildEligible(Map<String, dynamic>? entry, {bool force = false}) {
    if (entry == null) return false;
    final status = entry['status']?.toString() ?? '';
    final graphStatus = entry['graph_status']?.toString() ?? '';
    if (force &&
        (status == 'graph_staging_ready' || graphStatus == 'graph_staging_ready')) {
      return true;
    }
    if (status != 'ready') return false;
    if (speakersPending(entry)) return false;
    if (graphStatus == 'graph_pending' || graphStatus.isEmpty) return true;
    return false;
  }

  Future<Map<String, dynamic>> submitText(
    String paragraphText, {
    String? attributionKind,
    String? attributionName,
  }) {
    return _runWork(
      '받아쓰기 · 정제 중',
      () => apiClient.createTextJournalEntry(
        paragraphText,
        attributionKind: attributionKind,
        attributionName: attributionName,
      ),
    );
  }

  Future<Map<String, dynamic>> uploadAudio(
    String filePath, {
    String? filename,
    String? sourceType,
  }) {
    return _runWork(
      '받아쓰기 · 정제 중',
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
      '받아쓰기 · 정제 중',
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
    Future<Map<String, dynamic>> Function() work,
  ) async {
    final serial = ++_workSerial;
    _pollTimer?.cancel();
    _pollTimer = null;
    _entryId = null;
    _entry = null;
    _graphBuildStarted = false;
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
      _stageLabel = '처리 실패';
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

  void _adoptEntry(Map<String, dynamic> entry, {bool bumpEntries = false}) {
    _entryId = entry['id']?.toString() ?? _entryId;
    _entry = entry;
    final derived = deriveJournalPhase(entry);
    _phase = derived.phase;
    _stageLabel = derived.label;

    final statusKey =
        '${entry['status']}/${entry['graph_status']}/${_phase.name}';
    if (bumpEntries ||
        (_lastStatusKey != null && _lastStatusKey != statusKey)) {
      entriesChanged.value++;
    }
    _lastStatusKey = statusKey;

    _maybeAutoBuildGraph();
    _syncPolling();
    notifyListeners();
  }

  /// Text/audio ready → kick off graph draft once (graph_pending 포함).
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
    _stageLabel = '그래프 초안 생성 중';
    notifyListeners();

    try {
      await apiClient.buildGraph(id, force: force);
    } catch (_) {
      if (serial != _workSerial || _entryId != id) return;
      _phase = ComposePhase.error;
      _stageLabel = '그래프 생성 실패';
      notifyListeners();
      return;
    }
    if (serial != _workSerial || _entryId != id) return;
    await refresh();
  }

  /// Progress card fallback when auto-build did not run.
  Future<void> retryGraphBuild() async {
    if (_entryId == null || !_graphBuildEligible(_entry, force: true)) return;
    _graphBuildStarted = false;
    _maybeAutoBuildGraph(force: true);
  }

  Future<void> applyGraph(
    String entryId, {
    required List<Map<String, dynamic>> claims,
    required String contextType,
  }) async {
    final serial = _workSerial;
    _phase = ComposePhase.working;
    _stageLabel = '지식그래프 확정 중';
    notifyListeners();
    try {
      await apiClient.applyEntryGraph(
        entryId,
        claims: claims,
        contextType: contextType,
      );
      if (serial != _workSerial || _entryId != entryId) return;
      await refresh();
    } catch (e) {
      if (serial != _workSerial || _entryId != entryId) rethrow;
      _phase = ComposePhase.error;
      _stageLabel = '지식그래프 확정 실패';
      notifyListeners();
      rethrow;
    }
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

  /// Clear done/error so a new save is allowed.
  void dismiss() {
    if (_phase != ComposePhase.done && _phase != ComposePhase.error) return;
    _workSerial++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _entryId = null;
    _entry = null;
    _phase = ComposePhase.composing;
    _stageLabel = '';
    _graphBuildStarted = false;
    _lastStatusKey = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    entriesChanged.dispose();
    super.dispose();
  }
}

/// App-wide singleton for inline chat journal tasks.
final journalTask = JournalTaskController();
