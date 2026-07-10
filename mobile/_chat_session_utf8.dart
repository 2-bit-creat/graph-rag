import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../auth/device_auth.dart';
import '../compose/journal_phase.dart';
import '../widgets/graph_chat_panel.dart' show GraphChatMessage;
import 'journal_task_controller.dart';

/// Input mode of the chat composer ??the "+" button switches between them.
///
/// In [normal] the input is a chat message. In [distill] it becomes a refine
/// instruction for the diary draft. Quiz modes host inline quiz cards whose
/// answers are typed into the same input (composition/cloze) or tapped on-card.
/// [journal] replaces the input bar with an inline diary composer.
enum ChatMode { normal, quizWord, quizComposition, distill, journal }

/// App-wide controller for the Claude-style chat home.
///
/// Same "promote state above the widget tree" pattern as [ComposeSessionController]:
/// the chat rooms, the active room's messages, the input mode, and the canvas
/// glow hook all live here as a top-level [chatSession] singleton, so switching
/// rooms in the sidebar (or launching the compose PiP) never loses the feed.
/// The knowledge-graph screen subscribes to this and paints the same data.
class ChatSessionController extends ChangeNotifier {
  List<Map<String, dynamic>> _sessions = [];
  String? _activeId;
  final List<GraphChatMessage> _messages = [];
  bool _busy = false;
  bool _loadingMessages = false;
  ChatMode _mode = ChatMode.normal;
  bool _initialized = false;
  bool _journalListenerAttached = false;
  final Set<String> _journalCompleteNotified = {};

  // Inline quiz state (active card lives at the bottom of the feed).
  final List<Map<String, dynamic>> _quizItems = [];
  int _quizIndex = 0;
  String _quizType = 'composition';
  Map<String, dynamic>? _quizFeedback; // composition tutor feedback for current item

  // Distill (chat ??journal) draft state.
  final List<Map<String, dynamic>> _distillSentences = [];
  bool _distillLoading = false;

  /// Set by the graph screen so referenced nodes glow + the camera flies to them.
  ValueChanged<Set<String>>? onReferencedNodes;

  /// Transient errors for the UI to surface as a SnackBar (screen owns context).
  final ValueNotifier<String?> errors = ValueNotifier<String?>(null);

  List<Map<String, dynamic>> get sessions => List.unmodifiable(_sessions);
  String? get activeId => _activeId;
  List<GraphChatMessage> get messages => List.unmodifiable(_messages);
  bool get busy => _busy;
  bool get loadingMessages => _loadingMessages;
  ChatMode get mode => _mode;

  // Quiz getters
  String get quizType => _quizType;
  Map<String, dynamic>? get activeQuiz =>
      _quizIndex < _quizItems.length ? _quizItems[_quizIndex] : null;
  Map<String, dynamic>? get quizFeedback => _quizFeedback;
  bool get quizExhausted => _quizItems.isNotEmpty && _quizIndex >= _quizItems.length;

  // Distill getters
  List<Map<String, dynamic>> get distillSentences =>
      List.unmodifiable(_distillSentences);
  bool get distillLoading => _distillLoading;

  Map<String, dynamic>? get activeSession {
    for (final s in _sessions) {
      if (s['id']?.toString() == _activeId) return s;
    }
    return null;
  }

  // ?�?� Session lifecycle ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

  /// Load rooms once and open the most recent (or create one if none exist).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _attachJournalListener();
    if (!deviceAuthReady) {
      await ensureDeviceAuth();
    }
    await loadSessions();
    if (_sessions.isNotEmpty) {
      await selectSession(_sessions.first['id'].toString());
    }
  }

  void _attachJournalListener() {
    if (_journalListenerAttached) return;
    _journalListenerAttached = true;
    journalTask.addListener(_onJournalTaskChanged);
  }

  void _onJournalTaskChanged() {
    final entryId = journalTask.entryId;
    if (entryId == null) return;
    if (journalTask.phase == ComposePhase.done) {
      unawaited(_recordJournalComplete(entryId));
    } else if (journalTask.phase == ComposePhase.error) {
      unawaited(_recordJournalFailure(entryId));
    }
    // NOTE: no loadSessions() while busy ??the sidebar preview for the active
    // room is derived client-side from journalTask (see _resolvedPreview), which
    // the sidebar already listens to. Refetching the room list on every 4s poll
    // tick was a pure network round-trip with no visible effect.
  }

  Future<void> _recordJournalComplete(String entryId) async {
    final key = 'done:$entryId';
    if (_journalCompleteNotified.contains(key)) return;
    _journalCompleteNotified.add(key);
    await _ensureSession();
    if (_activeId == null) return;
    final content = '?�� 지?�그?�프 ?�성';
    _messages.add(GraphChatMessage(
      role: 'assistant',
      kind: 'journal_complete',
      content: content,
      meta: {'entry_id': entryId},
    ));
    notifyListeners();
    try {
      await apiClient.appendChatEvent(
        _activeId!,
        role: 'assistant',
        kind: 'journal_complete',
        content: content,
        meta: {'entry_id': entryId},
      );
      await loadSessions();
    } catch (e) {
      _journalCompleteNotified.remove(key);
      errors.value = _clean(e);
    }
  }

  Future<void> _recordJournalFailure(String entryId) async {
    final key = 'fail:$entryId';
    if (_journalCompleteNotified.contains(key)) return;
    _journalCompleteNotified.add(key);
    errors.value = '?�기 처리???�패?�어?? ?�시 ?�도??주세??';
    await _ensureSession();
    if (_activeId == null) return;
    const content = '?�� ?�기 처리 ?�패';
    try {
      await apiClient.appendChatEvent(
        _activeId!,
        role: 'assistant',
        kind: 'journal_complete',
        content: content,
        meta: {'entry_id': entryId, 'failed': true},
      );
      await loadSessions();
    } catch (e) {
      _journalCompleteNotified.remove(key);
      errors.value = _clean(e);
    }
  }

  Future<void> loadSessions() async {
    try {
      _sessions = await apiClient.listChatSessions();
      notifyListeners();
    } catch (e) {
      errors.value = _clean(e);
    }
  }

  Future<void> selectSession(String id) async {
    if (_activeId == id) return;
    _activeId = id;
    _mode = ChatMode.normal;
    _messages.clear();
    _loadingMessages = true;
    notifyListeners();
    await _loadMessages();
  }

  Future<void> _loadMessages() async {
    if (_activeId == null) return;
    try {
      final data = await apiClient.getChatMessages(_activeId!);
      final items = ((data['items'] as List?) ?? [])
          .map((m) =>
              GraphChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList();
      _messages
        ..clear()
        ..addAll(items);
    } catch (e) {
      errors.value = _clean(e);
    } finally {
      _loadingMessages = false;
      notifyListeners();
    }
  }

  /// Create a fresh room and make it active.
  Future<void> newSession() async {
    try {
      final s = await apiClient.createChatSession();
      _sessions.insert(0, s);
      _activeId = s['id'].toString();
      _mode = ChatMode.normal;
      _messages.clear();
      notifyListeners();
    } catch (e) {
      errors.value = _clean(e);
    }
  }

  Future<void> renameSession(String id, String title) async {
    try {
      final updated = await apiClient.renameChatSession(id, title);
      final i = _sessions.indexWhere((s) => s['id']?.toString() == id);
      if (i >= 0) _sessions[i] = updated;
      notifyListeners();
    } catch (e) {
      errors.value = _clean(e);
    }
  }

  Future<void> deleteSession(String id) async {
    try {
      await apiClient.deleteChatSession(id);
      _sessions.removeWhere((s) => s['id']?.toString() == id);
      if (_activeId == id) {
        _activeId = null;
        _messages.clear();
        if (_sessions.isNotEmpty) {
          await selectSession(_sessions.first['id'].toString());
        } else {
          notifyListeners();
        }
      } else {
        notifyListeners();
      }
    } catch (e) {
      errors.value = _clean(e);
    }
  }

  Future<void> _ensureSession() async {
    if (_activeId == null) await newSession();
  }

  void setMode(ChatMode m) {
    if (_mode == m) return;
    _mode = m;
    if (m == ChatMode.normal) {
      _quizItems.clear();
      _quizIndex = 0;
      _quizFeedback = null;
      _distillSentences.clear();
    }
    notifyListeners();
  }

  /// ?�기 ?�기 모드 진입 ???�?�창??모드 경계 ?�시.
  void enterJournalMode() {
    if (journalTask.isBusy) {
      errors.value = '진행 중인 ?�기 처리�?먼�? 마쳐 주세??';
      return;
    }
    if (_mode == ChatMode.journal) return;
    _mode = ChatMode.journal;
    _appendJournalModeMarker();
    notifyListeners();
  }

  void _appendJournalModeMarker() {
    final msg = GraphChatMessage(
      role: 'assistant',
      kind: 'journal_mode',
      content:
          '?�� ?�기 ?�기 모드\n'
          '@?�자�??�성?????�?�하�? 받아?�기 ???�자 ?�인 ??그래??검???�으�?'
          '?�래?�서 진행 ?�황???�인?????�어??',
    );
    _messages.add(msg);
    if (_activeId != null) {
      unawaited(apiClient.appendChatEvent(
        _activeId!,
        role: 'assistant',
        kind: 'journal_mode',
        content: msg.content,
      ));
    }
  }

  /// Return to plain conversation, discarding any active quiz/distill card.
  void exitMode() => setMode(ChatMode.normal);

  // ?�?� Sending ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

  /// Handle input from the composer according to the current [mode].
  /// - normal / quizWord: a chat message (word-quiz answers come from the card).
  /// - quizComposition: the typed translation answer for the active drill.
  /// - distill: a refine instruction for the current draft.
  Future<void> submitInput(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _busy) return;
    switch (_mode) {
      case ChatMode.distill:
        await refineDistill(text);
        break;
      case ChatMode.quizComposition:
        await answerComposition(text);
        break;
      case ChatMode.journal:
        // Save is a dedicated button on ChatJournalComposeBar; Enter = newline.
        break;
      case ChatMode.normal:
      case ChatMode.quizWord:
        await sendMessage(text);
        break;
    }
  }

  /// Persist user echo + journal_progress card and hand work to [journalTask].
  Future<void> saveJournalText(String labeledText, {String? displayText}) async {
    if (journalTask.isBusy) {
      errors.value = '?��? ?�기 처리가 진행 중이?�요. ?�료?????�시 ?�?�해 주세??';
      return;
    }
    await _ensureSession();
    try {
      _appendJournalSubmit(displayText ?? labeledText);
      final entry = await journalTask.submitText(labeledText);
      final id = entry['id']?.toString();
      if (id == null || id.isEmpty) {
        errors.value = '?�기 ?�?�에 ?�패?�어??';
        return;
      }
      _appendJournalProgress(id);
      exitMode();
    } catch (e) {
      errors.value = _clean(e);
    }
  }

  Future<void> saveJournalAudio({
    String? path,
    List<int>? bytes,
    required String filename,
    String mimeType = 'audio/wav',
  }) async {
    if (journalTask.isBusy) {
      errors.value = '?��? ?�기 처리가 진행 중이?�요. ?�료?????�시 ?�?�해 주세??';
      return;
    }
    await _ensureSession();
    try {
      _appendJournalSubmit('?���?$filename');
      late Map<String, dynamic> entry;
      if (bytes != null) {
        entry = await journalTask.uploadAudioBytes(
          bytes,
          filename: filename,
          mimeType: mimeType,
        );
      } else if (path != null) {
        entry = await journalTask.uploadAudio(path, filename: filename);
      } else {
        errors.value = '?�음 ?�이?��? ?�어??';
        return;
      }
      final id = entry['id']?.toString();
      if (id == null || id.isEmpty) {
        errors.value = '?�기 ?�?�에 ?�패?�어??';
        return;
      }
      _appendJournalProgress(id);
      exitMode();
    } catch (e) {
      errors.value = _clean(e);
    }
  }

  void _appendJournalSubmit(String text) {
    final preview = _journalPreview(text);
    final msg = GraphChatMessage(
      role: 'user',
      kind: 'journal_submit',
      content: preview,
    );
    _messages.add(msg);
    notifyListeners();
    if (_activeId != null) {
      unawaited(apiClient.appendChatEvent(
        _activeId!,
        role: 'user',
        kind: 'journal_submit',
        content: preview,
      ));
    }
  }

  String _journalPreview(String text) {
    const maxLen = 1600;
    final trimmed = text.trim();
    if (trimmed.length <= maxLen) return trimmed;
    return '${trimmed.substring(0, maxLen)}??;
  }

  void _appendJournalProgress(String entryId) {
    final msg = GraphChatMessage(
      role: 'assistant',
      kind: 'journal_progress',
      content: '?�� ?�기 처리 중�?,
      meta: {'entry_id': entryId},
    );
    _messages.add(msg);
    notifyListeners();
    if (_activeId != null) {
      unawaited(apiClient.appendChatEvent(
        _activeId!,
        role: 'assistant',
        kind: 'journal_progress',
        content: '?�� ?�기 처리 중�?,
        meta: {'entry_id': entryId},
      ));
    }
  }

  Future<void> sendMessage(String text) async {
    await _ensureSession();
    if (_activeId == null) return;
    _busy = true;
    _messages.add(GraphChatMessage(role: 'user', content: text));
    notifyListeners();
    try {
      final resp = await apiClient.sendChatMessage(_activeId!, text);
      final answer = resp['answer']?.toString() ?? '';
      final referenced = ((resp['referenced_node_ids'] as List?) ?? [])
          .map((e) => e.toString())
          .toList();
      _messages.add(GraphChatMessage(
        id: resp['assistant_message_id']?.toString(),
        role: 'assistant',
        content: answer,
        referencedNodeIds: referenced,
      ));
      if (referenced.isNotEmpty) onReferencedNodes?.call(referenced.toSet());
      unawaited(loadSessions()); // refresh preview + reorder sidebar
    } catch (e) {
      errors.value = _clean(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ?�?� Inline quiz ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

  /// Enter a quiz mode and pull a small session of items into the feed.
  /// [quizType]: 'composition' (typed drill) | 'cloze' | 'scramble' | 'mcq_nuance'.
  Future<void> startQuiz(String quizType) async {
    await _ensureSession();
    _quizType = quizType;
    _mode = quizType == 'composition'
        ? ChatMode.quizComposition
        : ChatMode.quizWord;
    _quizItems.clear();
    _quizIndex = 0;
    _quizFeedback = null;
    _busy = true;
    notifyListeners();
    try {
      final data = await apiClient.startQuizSession(quizType: quizType, size: 5);
      final items = ((data['items'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _quizItems.addAll(items);
      if (items.isEmpty) {
        errors.value = '?� ???�는 문제가 ?�어?? 메뉴 ??문제 ?�성?�서 만들??주세??';
        _mode = ChatMode.normal;
      }
    } catch (e) {
      errors.value = _clean(e);
      _mode = ChatMode.normal;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Grade a typed composition answer and surface tutor feedback.
  Future<void> answerComposition(String answer) async {
    final quiz = activeQuiz;
    if (quiz == null) return;
    _busy = true;
    _messages.add(GraphChatMessage(role: 'user', content: answer));
    notifyListeners();
    try {
      final resp = await apiClient.submitQuizAnswer(
        quizId: quiz['id'].toString(),
        answer: answer,
      );
      _quizFeedback =
          (resp['tutor_feedback'] as Map?)?.cast<String, dynamic>() ?? {};
      await _persistQuizEvent(quiz, answer, _quizFeedback);
    } catch (e) {
      errors.value = _clean(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Submit a word-quiz answer from a self-contained card. Returns the raw
  /// result so the card can reveal correctness; the caller then calls [nextQuiz].
  Future<Map<String, dynamic>?> submitWordQuiz({
    String? answer,
    List<int>? order,
    int? selectedIndex,
  }) async {
    final quiz = activeQuiz;
    if (quiz == null) return null;
    try {
      final resp = await apiClient.submitQuizAnswer(
        quizId: quiz['id'].toString(),
        answer: answer,
        order: order,
        selectedIndex: selectedIndex,
      );
      final summary = answer ?? order?.join(' ') ?? selectedIndex?.toString() ?? '';
      await _persistQuizEvent(quiz, summary, resp);
      return resp;
    } catch (e) {
      errors.value = _clean(e);
      return null;
    }
  }

  /// Advance to the next quiz item, or leave quiz mode when the session is done.
  void nextQuiz() {
    _quizIndex++;
    _quizFeedback = null;
    notifyListeners();
  }

  Future<void> _persistQuizEvent(
    Map<String, dynamic> quiz,
    String answer,
    Map<String, dynamic>? result,
  ) async {
    if (_activeId == null) return;
    try {
      await apiClient.appendChatEvent(
        _activeId!,
        role: 'assistant',
        kind: 'quiz_result',
        content: '?�� ?�즈: $answer',
        meta: {'quiz_id': quiz['id'], 'quiz_type': _quizType},
      );
    } catch (_) {
      // History persistence is best-effort ??never block the quiz on it.
    }
  }

  // ?�?� Chat ??journal distillation ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

  /// Enter distill mode and ask the server for a draft of the conversation.
  Future<void> startDistill() async {
    if (_activeId == null) {
      errors.value = '먼�? ?�?��? ?�작??주세??';
      return;
    }
    _mode = ChatMode.distill;
    _distillSentences.clear();
    _distillLoading = true;
    notifyListeners();
    try {
      final data = await apiClient.distillDraft(_activeId!);
      _applyDistill(data);
    } catch (e) {
      errors.value = _clean(e);
      _mode = ChatMode.normal;
    } finally {
      _distillLoading = false;
      notifyListeners();
    }
  }

  Future<void> refineDistill(String instruction) async {
    if (_activeId == null) return;
    _distillLoading = true;
    _messages.add(GraphChatMessage(role: 'user', content: instruction));
    notifyListeners();
    try {
      final data = await apiClient.distillRefine(_activeId!, instruction);
      _applyDistill(data);
    } catch (e) {
      errors.value = _clean(e);
    } finally {
      _distillLoading = false;
      notifyListeners();
    }
  }

  void _applyDistill(Map<String, dynamic> data) {
    _distillSentences
      ..clear()
      ..addAll(((data['sentences'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map)));
  }

  void toggleDistillSentence(int index, bool included) {
    if (index < 0 || index >= _distillSentences.length) return;
    _distillSentences[index]['included'] = included;
    notifyListeners();
    if (_activeId != null) {
      unawaited(apiClient.updateDistillState(
        _activeId!,
        _distillSentences.map((s) => s['included'] == true).toList(),
      ));
    }
  }

  /// Hand the confirmed draft to the inline journal pipeline (same card as chat save).
  Future<void> saveDistillAsJournal() async {
    if (journalTask.isBusy) {
      errors.value = '?��? ?�기 처리가 진행 중이?�요. ?�료?????�시 ?�?�해 주세??';
      return;
    }
    final included = _distillSentences
        .where((s) => s['included'] == true)
        .map((s) => (
              text: (s['text'] ?? '').toString().trim(),
              speaker: (s['speaker'] ?? '??).toString().trim().isEmpty
                  ? '??
                  : (s['speaker'] ?? '??).toString().trim(),
            ))
        .where((s) => s.text.isNotEmpty)
        .toList();
    if (included.isEmpty) {
      errors.value = '?�기???�을 문장???�나 ?�상 ?�택??주세??';
      return;
    }

    final allSelf = included.every((s) => s.speaker == '??);
    late final String paragraph;
    String? attributionKind;
    if (allSelf) {
      paragraph = included.map((s) => s.text).join('\n');
      attributionKind = 'self';
    } else {
      paragraph = included.map((s) => '[${s.speaker}]: ${s.text}').join('\n');
    }

    try {
      final entry = await journalTask.submitText(
        paragraph,
        attributionKind: attributionKind,
      );
      final id = entry['id']?.toString();
      if (id == null || id.isEmpty) {
        errors.value = '?�기 ?�?�에 ?�패?�어??';
        return;
      }
      _appendJournalProgress(id);
      exitMode();
    } catch (e) {
      errors.value = _clean(e);
    }
  }

  String _clean(Object e) => e.toString().replaceFirst('Exception: ', '');
}

/// App-wide singleton ??imported directly, like [journalTask].
final chatSession = ChatSessionController();
