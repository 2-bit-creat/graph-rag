import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import 'journal_phase.dart' as jp;

export 'journal_phase.dart'
    show ComposePhase, deriveJournalPhase, speakersPending, isGraphReviewPending;

/// 작성 입력 방식 — 음성 녹음 vs 텍스트 붙여넣기. (구 JournalComposeScreen에서
/// compose 모듈로 이관 — 작성 창 본문이 이 두 모드를 토글한다.)
enum JournalInputMode { voice, text }

/// 작성 창의 표시 상태.
enum ComposeWindowState { hidden, expanded, minimized }

/// 일기 작성 세션의 앱 전역 컨트롤러.
///
/// 업로드·파이프라인 대기 상태가 화면 위젯 안에 갇혀 있으면 화면을 벗어나는
/// 순간 진행 상황을 잃는다. 세션(entry id·단계·폴링)을 여기로 승격해서
/// 사용자가 타임라인 등 다른 화면에 있어도 우하단 미니 창이 진행 상황을
/// 계속 보여줄 수 있게 한다. 실제 작업은 백엔드에서 돌고, 여기는 상태만 폴링.
class ComposeSessionController extends ChangeNotifier {
  ComposeWindowState _window = ComposeWindowState.hidden;
  jp.ComposePhase _phase = jp.ComposePhase.composing;
  String _stageLabel = '';
  String? _entryId;
  Map<String, dynamic>? _entry;
  bool _dirty = false;
  bool _recording = false;
  Timer? _pollTimer;
  String? _lastStatusKey;
  int _workSerial = 0;

  /// 일기 생성/상태 변화 시 증가 — 타임라인 등 목록 화면의 갱신 트리거.
  final ValueNotifier<int> entriesChanged = ValueNotifier<int>(0);

  ComposeWindowState get window => _window;
  jp.ComposePhase get phase => _phase;
  String get stageLabel => _stageLabel;
  String? get entryId => _entryId;
  Map<String, dynamic>? get entry => _entry;
  bool get dirty => _dirty;
  bool get recording => _recording;

  bool get isActive => _window != ComposeWindowState.hidden;

  // ── 창 상태 ─────────────────────────────────────────────────────────────

  /// 작성 창 열기. 이미 세션이 살아 있으면 그 세션을 복원(확대)한다 —
  /// 동시 세션은 1개로 제한.
  void open({bool startNew = false}) {
    if (_window == ComposeWindowState.hidden ||
        (startNew && _phase != jp.ComposePhase.working)) {
      _resetSession();
    }
    _window = ComposeWindowState.expanded;
    notifyListeners();
  }

  void minimize() {
    if (_window != ComposeWindowState.expanded) return;
    _window = ComposeWindowState.minimized;
    notifyListeners();
  }

  void expand() {
    if (_window != ComposeWindowState.minimized) return;
    if (_phase == jp.ComposePhase.working && _entryId != null) {
      unawaited(refreshEntry());
    }
    _window = ComposeWindowState.expanded;
    // 엔트리 없이 실패한 업로드 → 작성 화면으로 복귀해 재시도.
    if (_phase == jp.ComposePhase.error && _entryId == null) {
      _phase = jp.ComposePhase.composing;
      _stageLabel = '';
    }
    notifyListeners();
  }

  /// 세션 종료. 미저장 입력 확인은 UI 레이어 책임.
  void close() {
    _resetSession();
    _window = ComposeWindowState.hidden;
    notifyListeners();
  }

  void _resetSession() {
    _workSerial++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _phase = jp.ComposePhase.composing;
    _stageLabel = '';
    _entryId = null;
    _entry = null;
    _dirty = false;
    _recording = false;
    _lastStatusKey = null;
  }

  void setDirty(bool value) {
    if (_dirty == value) return;
    _dirty = value;
    notifyListeners();
  }

  void setRecording(bool value) {
    if (_recording == value) return;
    _recording = value;
    notifyListeners();
  }

  // ── AI 작업 (Fast Path는 동기 요청 — 요청이 살아 있는 동안 창만 최소화) ──

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

  Future<Map<String, dynamic>> submitText(
    String paragraphText, {
    String? attributionKind,
    String? attributionName,
  }) {
    return _runWork(
      '일기 정제하는 중',
      () => apiClient.createTextJournalEntry(
        paragraphText,
        attributionKind: attributionKind,
        attributionName: attributionName,
      ),
    );
  }

  /// 상세 화면에서 '지식그래프 만들기'를 눌렀을 때 — 텍스트·음성 처리와 동일하게
  /// 이 작업을 세션이 인수해 창을 우하단 미니 카드로 접고 백그라운드에서 초안을
  /// 만든다. 전체화면 상세(타임라인 진입 등)에서 시작해도 여기로 위임하면 같은
  /// 미니 카드 흐름을 탄다. 초안이 준비되면 phase=needsInput → 미니 카드를 탭해
  /// 창을 펼치고 검토·확정으로 이어간다.
  Future<void> startGraphBuild(String entryId) async {
    // 새 작업이 이전(텍스트 등) 작업·폴링을 무효화한다.
    _workSerial++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _entryId = entryId;
    _entry = null;
    _phase = jp.ComposePhase.working;
    _stageLabel = '그래프 초안 생성 중';
    _lastStatusKey = null;
    // 세션이 꺼져 있으면(타임라인 등에서 진입) 미니 카드로 띄우고, 펼쳐져 있으면
    // (작성 창) 접는다 — 어느 경로든 "AI 대기 = 창이 접힌다" 규칙을 지킨다.
    if (_window != ComposeWindowState.minimized) {
      _window = ComposeWindowState.minimized;
    }
    notifyListeners();

    try {
      await apiClient.buildGraph(entryId);
    } catch (e) {
      if (_entryId != entryId) return; // 그 사이 다른 작업으로 교체됨
      _phase = jp.ComposePhase.error;
      _stageLabel = '그래프 생성 실패';
      notifyListeners();
      return;
    }
    // 엔트리를 채택하고 폴링을 시작한다 — status=graph_processing이면 4초 주기
    // 폴링이 돌다 graph_staging_ready(검토 필요)에서 phase=needsInput로 전환된다.
    await refreshEntry(silent: true);
  }

  /// 그래프 검토 화면에서 '확정'을 눌렀을 때 — startGraphBuild와 동일하게 창을
  /// 우하단 미니 카드로 접고 백그라운드에서 커밋한다. 확정 API는 동기(완료 시
  /// graph_ready 반환)라 표현 추출까지 오래 걸릴 수 있으므로, 큰 창에 사용자를
  /// 붙잡아 두지 않고 미니 카드 버퍼링으로 위임한다. 완료되면 phase=done.
  Future<void> applyGraph(
    String entryId, {
    required List<Map<String, dynamic>> claims,
    required String contextType,
  }) async {
    // 새 작업이 이전 작업·폴링을 무효화한다.
    _workSerial++;
    final serial = _workSerial;
    _pollTimer?.cancel();
    _pollTimer = null;
    _entryId = entryId;
    _phase = jp.ComposePhase.working;
    _stageLabel = '지식그래프 확정 중';
    _lastStatusKey = null;
    // "AI 대기 = 창이 접힌다" 규칙 — 확정 커밋도 예외가 아니다.
    if (_window != ComposeWindowState.minimized) {
      _window = ComposeWindowState.minimized;
    }
    notifyListeners();

    try {
      await apiClient.applyEntryGraph(
        entryId,
        claims: claims,
        contextType: contextType,
      );
    } catch (e) {
      if (serial != _workSerial) return; // 그 사이 다른 작업으로 교체됨
      _phase = jp.ComposePhase.error;
      _stageLabel = '지식그래프 확정 실패';
      notifyListeners();
      return;
    }
    if (serial != _workSerial) return;
    // 커밋된 엔트리를 채택 → phase=done(그래프 완성). 타임라인 등 목록도 갱신.
    await refreshEntry(silent: true);
    if (serial != _workSerial) return;
    entriesChanged.value++;
  }

  Future<Map<String, dynamic>> _runWork(
    String label,
    Future<Map<String, dynamic>> Function() work,
  ) async {
    // 레거시 경로(창 밖에서 패널 단독 사용) 안전장치: 세션 상태를 건드리지 않고
    // API 호출만 수행한다.
    if (!isActive) {
      final result = await work();
      entriesChanged.value++;
      return result;
    }

    final serial = ++_workSerial;
    _phase = jp.ComposePhase.working;
    _stageLabel = label;
    // 새 엔트리를 만드는 중 — 이전에 채택된 엔트리 참조를 즉시 비운다. 이게 없으면
    // 버퍼링 중 최소화 탭을 눌렀을 때 창이 방금 만든 게 아니라 '다른(이전) 일기'를
    // 보여주는 버그가 난다. entryId=null 동안엔 창이 처리 중 화면을 보여준다.
    _entryId = null;
    _entry = null;
    _lastStatusKey = null;
    // 이전 엔트리를 추적하던 폴링 타이머도 함께 끊는다 — 안 끊으면 그 타이머가
    // 마침 이 시점에 이미 요청을 보내둔 상태라 나중에 응답이 도착했을 때
    // (refreshEntry의 stale-id 가드로 막히긴 하지만) 불필요하게 계속 돈다.
    _pollTimer?.cancel();
    _pollTimer = null;
    // AI 대기 시작 → 자동 최소화. 사용자는 기다리는 동안 다른 화면을 쓴다.
    if (_window == ComposeWindowState.expanded) {
      _window = ComposeWindowState.minimized;
    }
    notifyListeners();

    try {
      final result = await work();
      if (serial != _workSerial) return result;
      final entry = await _freshEntryFor(result);
      if (serial != _workSerial) return result;
      _dirty = false;
      _adoptEntry(entry, bumpEntries: true);
      return entry;
    } catch (e) {
      if (serial != _workSerial) rethrow;
      _phase = jp.ComposePhase.error;
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

  // ── 엔트리 상태 추적 ─────────────────────────────────────────────────────

  Future<void> refreshEntry({bool silent = true}) async {
    final id = _entryId;
    if (id == null) return;
    try {
      final fresh = await apiClient.getEntry(id);
      // await 도중 세션이 다른 엔트리로 넘어갔거나(새 작업 시작) 리셋됐으면
      // 이 응답은 더 이상 유효하지 않다 — 그대로 채택하면 지금 막 시작한
      // 새 작업의 상태를 예전 엔트리 데이터로 덮어써 미니 카드가 "처리 중"
      // 라벨에 멈춘 채 실제로는 다른 엔트리를 가리키는 버그가 난다.
      if (_entryId != id) return;
      _adoptEntry(fresh);
    } catch (_) {
      // 일시적 네트워크 오류 — 다음 폴링에서 재시도.
    }
  }

  void _adoptEntry(Map<String, dynamic> entry, {bool bumpEntries = false}) {
    final prevPhase = _phase;
    _entryId = entry['id']?.toString() ?? _entryId;
    _entry = entry;
    _derivePhase();

    // 상세 화면에서 그래프 생성 등 새 AI 대기가 시작되면 여기서도 자동 최소화 —
    // "AI를 기다릴 땐 반드시 창이 접힌다" 규칙을 세션 전 구간에 적용.
    if (_phase == jp.ComposePhase.working &&
        prevPhase != jp.ComposePhase.working &&
        _window == ComposeWindowState.expanded) {
      _window = ComposeWindowState.minimized;
    }

    final statusKey =
        '${entry['status']}/${entry['graph_status']}/${_phase.name}';
    if (bumpEntries ||
        (_lastStatusKey != null && _lastStatusKey != statusKey)) {
      entriesChanged.value++;
    }
    _lastStatusKey = statusKey;

    _syncPolling();
    notifyListeners();
  }

  /// 그래프 초안이 준비되어 사용자의 검토·확정을 기다리는 상태.
  /// 미니 카드 탭이 확정 버튼 패널이 아니라 검토 화면으로 바로 가야 하는지 판단.
  bool get isGraphReviewPending => jp.isGraphReviewPending(_entry);

  void _derivePhase() {
    final derived = jp.deriveJournalPhase(_entry);
    _phase = derived.phase;
    _stageLabel = derived.label;
  }

  void _syncPolling() {
    final status = _entry?['status']?.toString() ?? '';
    final graphStatus = _entry?['graph_status']?.toString() ?? '';
    final busy = status == 'processing' ||
        status == 'graph_processing' ||
        graphStatus == 'graph_processing';
    if (busy && isActive) {
      _pollTimer ??= Timer.periodic(
        const Duration(seconds: 4),
        (_) => refreshEntry(),
      );
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    entriesChanged.dispose();
    super.dispose();
  }
}

/// 앱 전역 단일 세션.
final composeSession = ComposeSessionController();
