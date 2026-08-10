import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../utils/idempotency_key.dart';
import '../app_navigator.dart';
import '../compose/journal_phase.dart';
import '../l10n/app_strings.dart';
import '../widgets/graph_chat_panel.dart' show GraphChatMessage;
import 'journal_task_controller.dart';

/// Input mode of the chat composer — the "+" button switches between them.
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
  String? _quizLanguage; // sticky across "더보기" retries within the same mode
  Map<String, dynamic>?
      _quizFeedback; // composition tutor feedback for current item
  bool _wordQuizSolved = false;

  // Live word-by-word cloze typing (composer feeds keystrokes here instead of
  // grading the whole phrase at once — see [updateClozeDraft]).
  final List<String> _clozeCompletedWords = [];
  String _clozeLiveDraft = '';

  // Distill (chat → journal) draft state.
  final List<Map<String, dynamic>> _distillSentences = [];
  bool _distillLoading = false;

  /// True while an empty queue is being refilled and we are waiting for the
  /// first cards to land. The feed shows a "만드는 중" card instead of bouncing
  /// the learner out of quiz mode — see [startQuiz].
  bool _quizRefilling = false;

  /// Bumped whenever a quiz mode is entered or left, so a refill wait that is
  /// still polling can tell its session ended and stop touching state.
  int _quizEpoch = 0;

  bool get quizRefilling => _quizRefilling;

  /// Set by the graph screen so referenced nodes glow + the camera flies to them.
  ValueChanged<Set<String>>? onReferencedNodes;

  /// Transient errors for the UI to surface as a SnackBar (screen owns context).
  final ValueNotifier<String?> errors = ValueNotifier<String?>(null);

  /// Text to push back into the journal composer — set when an in-flight entry
  /// is abandoned so the user's original draft is never lost.
  final ValueNotifier<String?> composerRestore = ValueNotifier<String?>(null);

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
  bool get wordQuizSolved => _wordQuizSolved;
  List<String> get clozeCompletedWords =>
      List.unmodifiable(_clozeCompletedWords);
  String get clozeLiveDraft => _clozeLiveDraft;
  bool get wordQuizUsesComposer {
    if (_mode != ChatMode.quizWord) return false;
    final type = activeQuiz?['quiz_type']?.toString() ?? 'cloze';
    return type == 'cloze';
  }

  bool get quizExhausted =>
      _quizItems.isNotEmpty && _quizIndex >= _quizItems.length;

  /// 1-based position of the active card within the loaded queue, and the
  /// queue's current size — e.g. "3 / 8". Null once the queue is exhausted
  /// (nothing meaningful to count against) or before anything has loaded.
  int? get quizPosition =>
      _quizIndex < _quizItems.length ? _quizIndex + 1 : null;
  int? get quizTotal => _quizItems.isEmpty ? null : _quizItems.length;

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

  // ── Session lifecycle ────────────────────────────────────────────────────

  /// Load rooms once and open the most recent (or create one if none exist).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _attachJournalListener();
    await loadSessions();
    if (_sessions.isNotEmpty) {
      await selectSession(_sessions.first['id'].toString());
    }
  }

  /// Wipe every account-scoped field so the next [init] call reloads from
  /// scratch instead of silently keeping the previous account's rooms and
  /// messages on screen. [chatSession] is a single app-wide singleton (see
  /// class doc), and [init]'s `_initialized` guard is a one-shot: without an
  /// explicit reset, switching accounts remounts the screen but `init()`
  /// no-ops, leaving the OLD account's chat history and active room visible
  /// under the NEW account's identity. Call this before the new account's
  /// `init()` runs — [AccountController.enter]/`switchTo`/`signOut` do so.
  void reset() {
    _sessions = [];
    _activeId = null;
    _messages.clear();
    _busy = false;
    _loadingMessages = false;
    _mode = ChatMode.normal;
    _initialized = false;
    _quizItems.clear();
    _quizIndex = 0;
    _quizType = 'composition';
    _quizLanguage = null;
    _quizFeedback = null;
    _wordQuizSolved = false;
    _clozeCompletedWords.clear();
    _clozeLiveDraft = '';
    _distillSentences.clear();
    _distillLoading = false;
    _journalCompleteNotified.clear();
    errors.value = null;
    composerRestore.value = null;
    notifyListeners();
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
    // NOTE: no loadSessions() while busy — the sidebar preview for the active
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
    final content = tr('chat.graphCompleteMsg');
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
    // Surface the failure to the user (was previously silent).
    errors.value = tr('journal.failed');
    await _ensureSession();
    if (_activeId == null) return;
    final content = tr('chat.journalFailedMsg');
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
      // Retires the epoch so a refill still polling for this session stops and
      // does not resurrect quiz state after the learner has left it.
      _quizEpoch++;
      _quizRefilling = false;
      _quizItems.clear();
      _quizIndex = 0;
      _quizFeedback = null;
      _wordQuizSolved = false;
      _clozeCompletedWords.clear();
      _clozeLiveDraft = '';
      _distillSentences.clear();
    }
    notifyListeners();
  }

  /// Free the journal pipeline for a new save.
  ///
  /// Only real backend work blocks — a pipeline merely *parked on a user gate*
  /// (화자 확인 / 그래프 검토) is set aside instead, because refusing there is
  /// what left the user with no way forward: neither finishing nor abandoning
  /// the entry was possible, and every later save was rejected. The parked
  /// entry keeps its progress card in the feed and stays resumable from it.
  bool _claimJournalPipeline() {
    if (journalTask.systemProcessing) {
      errors.value = tr('chat.journalAlreadyProcessing');
      return false;
    }
    if (journalTask.needsInput) {
      journalTask.release(force: true);
      errors.value = tr('chat.journalParkedNotice');
    }
    return true;
  }

  /// Set the live entry aside without deleting it — the feed card keeps it
  /// resumable. [restoreDraft] puts its original text back in the composer.
  void abandonJournal({bool restoreDraft = false}) {
    final draft = journalTask.sourceText;
    journalTask.release(force: true);
    if (restoreDraft && draft != null && draft.trim().isNotEmpty) {
      composerRestore.value = draft;
      if (_mode != ChatMode.journal) {
        _mode = ChatMode.journal;
      }
    }
    notifyListeners();
  }

  /// 일기 쓰기 모드 진입 — 대화창에 모드 경계 표시.
  void enterJournalMode() {
    if (journalTask.systemProcessing) {
      errors.value = tr('chat.journalBusyEnterMode');
      return;
    }
    if (_mode == ChatMode.journal) return;
    _mode = ChatMode.journal;
    _appendJournalModeMarker();
    notifyListeners();
  }

  void _appendJournalModeMarker() {
    // The marker is a one-time "here's how journal mode works" explainer, not
    // content — once the room has seen it, re-entering the mode later (even
    // after other messages in between) shouldn't repeat it. Used to only check
    // the immediately preceding message, which still stacked a duplicate any
    // time something else happened between two visits to journal mode.
    if (_messages.any((m) => m.kind == 'journal_mode')) return;
    final msg = GraphChatMessage(
      role: 'assistant',
      kind: 'journal_mode',
      content: tr('chat.journalModeBanner'),
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

  // ── Sending ──────────────────────────────────────────────────────────────

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
        // Save is a dedicated button on the composer pill; Enter = newline.
        break;
      case ChatMode.normal:
        await sendMessage(text);
        break;
      case ChatMode.quizWord:
        if (wordQuizUsesComposer) await answerWordQuiz(text);
        break;
    }
  }

  /// Persist user echo + journal_progress card and hand work to [journalTask].
  Future<void> saveJournalText(String labeledText,
      {String? displayText}) async {
    if (!_claimJournalPipeline()) return;
    await _ensureSession();
    try {
      _appendJournalSubmit(displayText ?? labeledText);
      // The API does refinement synchronously before it can return an entry id.
      // Put a real in-feed status card up first, rather than leaving the only
      // feedback as the tiny spinner in the send button.
      _appendJournalSubmissionProgress();
      final entry =
          await journalTask.submitText(labeledText, sourceText: displayText);
      final id = entry['id']?.toString();
      if (id == null || id.isEmpty) {
        errors.value = tr('chat.journalSaveFailed');
        return;
      }
      _promoteJournalSubmissionProgress(id);
      exitMode();
    } catch (e) {
      _failJournalSubmissionProgress(_clean(e));
      errors.value = _clean(e);
    }
  }

  Future<void> saveJournalAudio({
    String? path,
    List<int>? bytes,
    required String filename,
    String mimeType = 'audio/wav',
  }) async {
    if (!_claimJournalPipeline()) return;
    await _ensureSession();
    try {
      _appendJournalSubmit(filename);
      _appendJournalSubmissionProgress();
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
        errors.value = tr('chat.noRecordingData');
        return;
      }
      final id = entry['id']?.toString();
      if (id == null || id.isEmpty) {
        errors.value = tr('chat.journalSaveFailed');
        return;
      }
      _promoteJournalSubmissionProgress(id);
      exitMode();
    } catch (e) {
      _failJournalSubmissionProgress(_clean(e));
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
    return '${trimmed.substring(0, maxLen)}…';
  }

  void _appendJournalProgress(String entryId) {
    final msg = GraphChatMessage(
      role: 'assistant',
      kind: 'journal_progress',
      content: tr('chat.journalProcessing'),
      meta: {'entry_id': entryId},
    );
    _messages.add(msg);
    notifyListeners();
    if (_activeId != null) {
      unawaited(apiClient.appendChatEvent(
        _activeId!,
        role: 'assistant',
        kind: 'journal_progress',
        content: tr('chat.journalProcessing'),
        meta: {'entry_id': entryId},
      ));
    }
  }

  void _appendJournalSubmissionProgress() {
    _messages.add(GraphChatMessage(
      role: 'assistant',
      kind: 'journal_submission_progress',
      content: tr('chat.journalSending'),
    ));
    notifyListeners();
  }

  void _promoteJournalSubmissionProgress(String entryId) {
    final index = _messages.lastIndexWhere(
        (message) => message.kind == 'journal_submission_progress');
    if (index >= 0) {
      _messages[index] = GraphChatMessage(
        role: 'assistant',
        kind: 'journal_progress',
        content: tr('chat.journalProcessing'),
        meta: {'entry_id': entryId},
      );
      notifyListeners();
      if (_activeId != null) {
        unawaited(apiClient.appendChatEvent(
          _activeId!,
          role: 'assistant',
          kind: 'journal_progress',
          content: tr('chat.journalProcessing'),
          meta: {'entry_id': entryId},
        ));
      }
      return;
    }
    _appendJournalProgress(entryId);
  }

  void _failJournalSubmissionProgress(String detail) {
    final index = _messages.lastIndexWhere(
        (message) => message.kind == 'journal_submission_progress');
    if (index < 0) return;
    _messages[index] = GraphChatMessage(
      role: 'assistant',
      kind: 'journal_submission_failed',
      content: detail,
    );
    notifyListeners();
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
        meta: resp['retrieval_meta'] == null
            ? null
            : {
                'retrieval':
                    Map<String, dynamic>.from(resp['retrieval_meta'] as Map)
              },
      ));
      final cardRaw = resp['learning_card'];
      if (cardRaw is Map &&
          (cardRaw['prompt']?.toString().trim().isNotEmpty ?? false)) {
        final card = Map<String, dynamic>.from(cardRaw);
        final prompt = card['prompt'].toString();
        _messages.add(GraphChatMessage(
          role: 'assistant',
          kind: 'learning_card',
          content: prompt,
          referencedNodeIds: [
            if (card['source_node_id'] != null)
              card['source_node_id'].toString()
          ],
          meta: card,
        ));
        // Persist the optional practice prompt separately from the factual
        // answer so it remains recoverable in the room history.
        unawaited(apiClient.appendChatEvent(
          _activeId!,
          role: 'assistant',
          kind: 'learning_card',
          content: prompt,
          referencedNodeIds: [
            if (card['source_node_id'] != null)
              card['source_node_id'].toString()
          ],
          meta: card,
        ));
      }
      if (referenced.isNotEmpty) onReferencedNodes?.call(referenced.toSet());
      unawaited(loadSessions()); // refresh preview + reorder sidebar
    } catch (e) {
      errors.value = _clean(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── Inline quiz ──────────────────────────────────────────────────────────

  /// Enter a quiz mode and pull a small session of items into the feed.
  /// [quizType]: 'composition' (typed drill) | 'cloze' | 'scramble' | 'mcq_nuance'.
  /// [language]: which target language to draw from when the learner has more
  /// than one configured (null = backend default).
  Future<void> startQuiz(
    String quizType, {
    String? language,
    List<String>? quizIds,
  }) async {
    await _ensureSession();
    _quizType = quizType;
    _quizLanguage = language ?? _quizLanguage;
    _mode = quizType == 'composition'
        ? ChatMode.quizComposition
        : ChatMode.quizWord;
    _quizItems.clear();
    _quizIndex = 0;
    _quizFeedback = null;
    _wordQuizSolved = false;
    _clozeCompletedWords.clear();
    _clozeLiveDraft = '';
    _busy = true;
    final epoch = ++_quizEpoch;
    notifyListeners();
    try {
      final data = await apiClient.startQuizSession(
          quizType: quizType,
          size: quizIds != null && quizIds.isNotEmpty ? quizIds.length : 5,
          language: _quizLanguage,
          quizIds: quizIds);
      final items = ((data['items'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _quizItems.addAll(items);
      if (items.isEmpty) {
        // Nothing queued yet. Refill generates straight from the learner's
        // graph statements and takes ~20s of LLM + TTS work, so telling them to
        // "press again in a moment" sent them back too early, onto the same
        // empty queue. Hold them in quiz mode behind a preparing state and pull
        // the cards in ourselves the moment they exist.
        await _refillAndWaitForQuizzes(epoch);
      }
    } catch (e) {
      errors.value = _clean(e);
      _mode = ChatMode.normal;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// How long to keep waiting on a refill before handing control back.
  ///
  /// A refill is several LLM calls plus TTS per card; measured end-to-end it
  /// runs a little over 20s, so the budget has to clear that with room to spare
  /// or the learner is dropped right before their cards land.
  static const _refillTimeout = Duration(seconds: 75);
  static const _refillPollInterval = Duration(seconds: 3);

  /// Kick a queue refill and stay on it until the first cards arrive.
  ///
  /// The learner stays in quiz mode the whole time; [quizRefilling] drives a
  /// "preparing" card in the feed. Returns with items loaded, or leaves quiz
  /// mode if the refill produced nothing inside [_refillTimeout].
  Future<void> _refillAndWaitForQuizzes(int epoch) async {
    _quizRefilling = true;
    notifyListeners();
    try {
      await apiClient.refillQuizzes();

      final deadline = DateTime.now().add(_refillTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_refillPollInterval);
        // The learner left this quiz session (closed it, switched mode, or
        // started another) — abandon the wait rather than write into it.
        if (epoch != _quizEpoch) return;

        final data = await apiClient.startQuizSession(
          quizType: _quizType,
          size: 5,
          language: _quizLanguage,
        );
        final items = ((data['items'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (items.isNotEmpty) {
          if (epoch != _quizEpoch) return;
          _quizItems.addAll(items);
          return;
        }
      }
      if (epoch != _quizEpoch) return;
      errors.value = tr('quiz.refillSlow');
      _mode = ChatMode.normal;
    } catch (e) {
      if (epoch != _quizEpoch) return;
      errors.value = _clean(e);
      _mode = ChatMode.normal;
    } finally {
      if (epoch == _quizEpoch) {
        _quizRefilling = false;
        notifyListeners();
      }
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
        idempotencyKey: newIdempotencyKey('attempt'),
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
  Future<void> answerWordQuiz(String answer) async {
    final quiz = activeQuiz;
    if (quiz == null || !wordQuizUsesComposer || _wordQuizSolved) return;
    final normalized =
        answer.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return;

    _messages.add(GraphChatMessage(role: 'user', content: answer.trim()));
    if (_quizFeedback != null) {
      final qd = (quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
      final accepted = <String>{
        if ((qd['blank']?.toString() ?? '').trim().isNotEmpty)
          qd['blank'].toString().trim().toLowerCase(),
        for (final value in (qd['accepted_answers'] as List? ?? const []))
          value.toString().trim().toLowerCase(),
      }.map((value) => value.replaceAll(RegExp(r'\s+'), ' ')).toSet();
      if (accepted.contains(normalized)) {
        _wordQuizSolved = true;
        _quizFeedback = {..._quizFeedback!, 'is_correct': true};
      } else {
        // Keep this on the card itself (via is_correct) rather than only a
        // transient snackbar — the learner is typing in the composer, not
        // looking at where a snackbar appears.
        _quizFeedback = {..._quizFeedback!, 'is_correct': false};
        errors.value = tr('chat.wrongAnswerHint');
      }
      notifyListeners();
      return;
    }

    _busy = true;
    notifyListeners();
    try {
      final result = await submitWordQuiz(answer: answer.trim());
      if (result != null) {
        _quizFeedback = result;
        _wordQuizSolved = result['is_correct'] == true;
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Submit choices made directly on non-cloze cards. Cloze text normally
  /// enters through [answerWordQuiz] and therefore through the shared composer.
  Future<Map<String, dynamic>?> submitWordQuiz({
    String? answer,
    List<int>? order,
    int? selectedIndex,
    int hintLevel = 0,
    List<String> revealedTokens = const [],
    bool answerRevealed = false,
  }) async {
    final quiz = activeQuiz;
    if (quiz == null) return null;
    try {
      final resp = await apiClient.submitQuizAnswer(
        quizId: quiz['id'].toString(),
        answer: answer,
        order: order,
        selectedIndex: selectedIndex,
        idempotencyKey: newIdempotencyKey('attempt'),
        hintLevel: hintLevel,
        revealedTokens: revealedTokens,
        answerRevealed: answerRevealed,
      );
      final summary =
          answer ?? order?.join(' ') ?? selectedIndex?.toString() ?? '';
      await _persistQuizEvent(quiz, summary, resp);
      return resp;
    } catch (e) {
      errors.value = _clean(e);
      return null;
    }
  }

  /// Live per-keystroke update from the shared composer while a cloze word
  /// quiz is active. Matches one word at a time instead of grading the whole
  /// phrase at once: each keystroke is compared against the next unmatched
  /// answer word, and a match commits that word (advancing the "cursor" to
  /// the next blank) instead of waiting for an explicit submit. Returns true
  /// when the composer should clear itself (a word just completed).
  Future<bool> updateClozeDraft(
    String text, {
    int hintLevel = 0,
    List<String> revealedTokens = const [],
    bool answerRevealed = false,
  }) async {
    if (_mode != ChatMode.quizWord ||
        !wordQuizUsesComposer ||
        _wordQuizSolved) {
      return false;
    }
    final quiz = activeQuiz;
    if (quiz == null) return false;
    final qd = (quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final words = (qd['blank']?.toString() ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty || _clozeCompletedWords.length >= words.length) {
      return false;
    }

    final normalized =
        text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final target = words[_clozeCompletedWords.length].toLowerCase();
    if (normalized.isEmpty || normalized != target) {
      _clozeLiveDraft = text;
      notifyListeners();
      return false;
    }

    _clozeCompletedWords.add(words[_clozeCompletedWords.length]);
    _clozeLiveDraft = '';
    final allWordsMatched = _clozeCompletedWords.length == words.length;
    if (allWordsMatched) {
      // The learner already proved the answer letter-by-letter — mark it
      // solved immediately instead of waiting on a network round trip.
      // Otherwise "다음 문제"/audio only appear once the request returns (or
      // never, if it fails), which looks like the quiz just froze.
      _wordQuizSolved = true;
    }
    notifyListeners();
    if (allWordsMatched) {
      unawaited(_finalizeClozeSubmission(
        hintLevel: hintLevel,
        revealedTokens: revealedTokens,
        answerRevealed: answerRevealed,
      ));
    }
    return true;
  }

  /// Records the already-confirmed-correct cloze answer for real grading/SRS.
  /// Runs after the UI has already moved on, so a slow or failed request
  /// can't undo the learner-visible completion.
  Future<void> _finalizeClozeSubmission({
    int hintLevel = 0,
    List<String> revealedTokens = const [],
    bool answerRevealed = false,
  }) async {
    final answer = _clozeCompletedWords.join(' ');
    try {
      final result = await submitWordQuiz(
        answer: answer,
        hintLevel: hintLevel,
        revealedTokens: revealedTokens,
        answerRevealed: answerRevealed,
      );
      if (result != null) {
        _quizFeedback = result;
        notifyListeners();
      }
    } catch (_) {
      // Best-effort — the card already reflects success either way.
    }
  }

  /// Advance to the next quiz item, or leave quiz mode when the session is done.
  void nextQuiz() {
    _quizIndex++;
    _quizFeedback = null;
    _wordQuizSolved = false;
    _clozeCompletedWords.clear();
    _clozeLiveDraft = '';
    notifyListeners();
  }

  Future<void> _persistQuizEvent(
    Map<String, dynamic> quiz,
    String answer,
    Map<String, dynamic>? result,
  ) async {
    // Show it in the live feed immediately — this used to only persist to
    // the backend, so every answer past the first (loaded on the next full
    // history fetch) was invisible until the room was reopened.
    final content = tr('chat.quizAnswerContent', {'answer': answer});
    _messages.add(GraphChatMessage(
      role: 'assistant',
      kind: 'quiz_result',
      content: content,
      meta: {'quiz_id': quiz['id'], 'quiz_type': _quizType},
    ));
    notifyListeners();
    if (_activeId == null) return;
    try {
      await apiClient.appendChatEvent(
        _activeId!,
        role: 'assistant',
        kind: 'quiz_result',
        content: content,
        meta: {'quiz_id': quiz['id'], 'quiz_type': _quizType},
      );
    } catch (_) {
      // History persistence is best-effort — never block the quiz on it.
    }
  }

  // ── Chat → journal distillation ──────────────────────────────────────────

  /// Enter distill mode and ask the server for a draft of the conversation.
  Future<void> startDistill() async {
    if (_activeId == null) {
      errors.value = tr('chat.startConversationFirst');
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
    if (!_claimJournalPipeline()) return;
    final selfLabel = selfSpeakerLabel;
    final included = _distillSentences
        .where((s) => s['included'] == true)
        .map((s) => (
              text: (s['text'] ?? '').toString().trim(),
              speaker: (s['speaker'] ?? selfLabel).toString().trim().isEmpty
                  ? selfLabel
                  : (s['speaker'] ?? selfLabel).toString().trim(),
            ))
        .where((s) => s.text.isNotEmpty)
        .toList();
    if (included.isEmpty) {
      errors.value = tr('chat.selectAtLeastOneSentence');
      return;
    }

    final allSelf = included.every((s) => s.speaker == selfLabel);
    late final String paragraph;
    String? attributionKind;
    if (allSelf) {
      paragraph = included.map((s) => s.text).join('\n');
      attributionKind = 'self';
    } else {
      paragraph = included.map((s) => '[${s.speaker}]: ${s.text}').join('\n');
    }

    try {
      _appendJournalSubmit(paragraph);
      _appendJournalSubmissionProgress();
      final entry = await journalTask.submitText(
        paragraph,
        attributionKind: attributionKind,
      );
      final id = entry['id']?.toString();
      if (id == null || id.isEmpty) {
        errors.value = tr('chat.journalSaveFailed');
        return;
      }
      _promoteJournalSubmissionProgress(id);
      exitMode();
    } catch (e) {
      _failJournalSubmissionProgress(_clean(e));
      errors.value = _clean(e);
    }
  }

  String _clean(Object e) => e.toString().replaceFirst('Exception: ', '');
}

/// App-wide singleton — imported directly, like [composeSession].
final chatSession = ChatSessionController();

/// Single entry point for "새 일기 쓰기" from anywhere outside the home shell
/// (timeline FAB, journal hub, quiz gen). Returns to the home shell and enters
/// the in-chat journal compose mode — replacing the old popup compose window,
/// so journal writing always happens inline in the conversation.
void openChatJournalCompose() {
  appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
  chatSession.enterJournalMode();
}
