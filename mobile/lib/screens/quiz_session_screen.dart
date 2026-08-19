import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/quiz/cloze_quiz_card.dart';
import '../widgets/quiz/composition_quiz_card.dart';
import '../widgets/quiz/mcq_quiz_card.dart';
import '../widgets/quiz/quiz_audio_button.dart';
import '../utils/idempotency_key.dart';
import '../widgets/quiz/scramble_quiz_card.dart';

class QuizSessionScreen extends StatefulWidget {
  const QuizSessionScreen({
    super.key,
    required this.quizType,
    this.entryId,
    this.quizIds,
    this.vocabSource,
  });

  final String quizType;
  final String? entryId;
  final List<String>? quizIds;
  final String? vocabSource;

  @override
  State<QuizSessionScreen> createState() => _QuizSessionScreenState();
}

class _QuizSessionScreenState extends State<QuizSessionScreen> {
  List<Map<String, dynamic>> _items = [];
  int _index = 0;
  bool _loading = true;
  bool _loadFailed = false;
  bool _answered = false;
  bool? _lastCorrect;
  bool _clozeSolved = false;
  String? _feedback;
  String? _revealedAnswer;
  int? _lastQuality;

  final _audioKey = GlobalKey<QuizAudioButtonState>();
  final _clozeKey = GlobalKey<ClozeQuizCardState>();

  static Map<String, String> get _typeLabels => {
        'cloze': tr('quizSession.typeCloze'),
        'composition': tr('quizSession.typeComposition'),
        'scramble': tr('quizSession.typeScramble'),
        'mcq_nuance': tr('quizSession.typeMcqNuance'),
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final session = await apiClient.startQuizSession(
        quizType: widget.quizType,
        size: widget.quizIds?.length ?? 10,
        entryId: widget.entryId,
        quizIds: widget.quizIds,
        vocabSource: widget.vocabSource,
      );
      final items = (session['items'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('quizSession.sessionLoadFailed', {'error': e}))),
        );
      }
    }
  }

  Map<String, dynamic>? get _current =>
      _items.isEmpty || _index >= _items.length ? null : _items[_index];

  String? _clozeAnswer(Map<String, dynamic> quizData) {
    final blank = quizData['blank']?.toString();
    if (blank != null && blank.isNotEmpty) return blank;
    final accepted = quizData['accepted_answers'];
    if (accepted is List && accepted.isNotEmpty) {
      return accepted.first.toString();
    }
    return null;
  }

  String? _compositionFeedback(dynamic raw) {
    if (raw is! Map) return null;
    final parts = <String>[];
    for (final key in ['verdict_label', 'encouragement', 'attempt_note', 'thinking_tip']) {
      final value = raw[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) parts.add(value);
    }
    final corrections = raw['corrections'];
    if (corrections is List) {
      for (final correction in corrections.whereType<Map>()) {
        final issue = correction['issue']?.toString().trim() ?? '';
        final suggestion = correction['suggestion']?.toString().trim() ?? '';
        if (issue.isNotEmpty || suggestion.isNotEmpty) {
          parts.add('• $issue${issue.isNotEmpty && suggestion.isNotEmpty ? ' → ' : ''}$suggestion');
        }
      }
    }
    return parts.isEmpty ? null : parts.join('\n');
  }

  Future<void> _handleResult(Map<String, dynamic> result) async {
    final correct = result['correct'] == true;
    final item = _current!;
    final quizData = Map<String, dynamic>.from(
      (item['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {},
    );

    setState(() {
      final revealedQuiz = result['quiz'];
      if (revealedQuiz is Map) {
        // The scramble response is deliberately richer only after submission.
        // Merge it before rebuilding so the revealed sentence/audio are usable.
        item.addAll(Map<String, dynamic>.from(revealedQuiz));
      }
      _answered = true;
      _lastCorrect = correct;
      _lastQuality = (result['quality'] as num?)?.toInt();
      final tutorFeedback = result['tutor_feedback'];
      _feedback = result['explanation']?.toString() ?? _compositionFeedback(tutorFeedback);
      if (!correct && widget.quizType == 'cloze') {
        _revealedAnswer = _clozeAnswer(quizData);
      }
    });

    // Cloze owns its answer-reveal transition and plays the prepared sequence
    // itself. Other quiz cards keep the existing sentence playback behavior.
    if (widget.quizType != 'cloze') {
      unawaited(
        (correct
                ? _audioKey.currentState?.playCorrectSequence(showError: false)
                : _audioKey.currentState?.play(showError: false)) ??
            Future<void>.value(),
      );
    }
  }

  void _goNext() {
    if (_index < _items.length - 1) {
      setState(() {
        _index++;
        _answered = false;
        _lastCorrect = null;
        _clozeSolved = false;
        _feedback = null;
        _revealedAnswer = null;
        _lastQuality = null;
      });
    } else {
      Navigator.pop(context, true);
    }
  }

  Future<bool> _submitCloze(String answer) async {
    final item = _current!;
    final telemetry = _clozeKey.currentState;
    final result = await apiClient.submitQuizAnswer(
      quizId: item['id'].toString(),
      answer: answer,
      entryId: widget.entryId,
      idempotencyKey: newIdempotencyKey('attempt'),
      hintLevel: telemetry?.telemetryHintLevel ?? 0,
      revealedTokens: telemetry?.telemetryRevealedTokens ?? const [],
      answerRevealed: telemetry?.telemetryAnswerRevealed ?? false,
    );
    await _handleResult(result);
    return result['correct'] == true;
  }

  Future<void> _submitScramble(List<String> order, int hintLevel) async {
    final item = _current!;
    final result = await apiClient.submitQuizAnswer(
      quizId: item['id'].toString(),
      order: order,
      entryId: widget.entryId,
      idempotencyKey: newIdempotencyKey('attempt'),
      hintLevel: hintLevel,
    );
    await _handleResult(result);
  }

  /// Order hint for the current scramble — the answer key is server-side only.
  Future<Map<String, dynamic>?> _scrambleHint(int hintLevel) async {
    final item = _current;
    if (item == null) return null;
    try {
      return await apiClient.fetchScrambleHint(
        quizId: item['id'].toString(),
        hintLevel: hintLevel,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      return null;
    }
  }

  Future<void> _submitMcq(int index) async {
    final item = _current!;
    final result = await apiClient.submitQuizAnswer(
      quizId: item['id'].toString(),
      selectedIndex: index,
      entryId: widget.entryId,
      idempotencyKey: newIdempotencyKey('attempt'),
    );
    await _handleResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final label = _typeLabels[widget.quizType] ?? widget.quizType;
    if (_loading) {
      return Scaffold(
        appBar: AppHubAppBar(title: tr('quizSession.quizTitle', {'label': label})),
        body: AppLoadingScreen(message: tr('quizSession.loadingQuestions')),
      );
    }
    if (_loadFailed) {
      return Scaffold(
        appBar: AppHubAppBar(title: tr('quizSession.quizTitle', {'label': label})),
        body: AppEmptyState(
          icon: Icons.error_outline_rounded,
          title: tr('quizSession.loadFailedTitle'),
          action: FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr('common.retry')),
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Scaffold(
        appBar: AppHubAppBar(title: tr('quizSession.quizTitle', {'label': label})),
        body: AppEmptyState(
          icon: Icons.inbox_outlined,
          title: tr('quizSession.emptyQueueTitle'),
          subtitle: tr('quizSession.emptyQueueSubtitle'),
        ),
      );
    }

    final item = _current!;
    final quizData = Map<String, dynamic>.from(
      (item['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {},
    );
    // Merge top-level sentence_en into quizData as fallback for cards that need it.
    final topSentenceEn = item['sentence_en']?.toString() ?? '';
    if (topSentenceEn.isNotEmpty) {
      if ((quizData['prompt_en']?.toString() ?? '').isEmpty) {
        quizData['prompt_en'] = topSentenceEn;
      }
      if ((quizData['sentence_en']?.toString() ?? '').isEmpty) {
        quizData['sentence_en'] = topSentenceEn;
      }
    }
    final audioUrl = item['audio_url']?.toString() ??
        quizData['audio_url']?.toString();
    final answerAudioUrl = item['answer_audio_url']?.toString() ??
        quizData['answer_audio_url']?.toString();
    final level = item['difficulty_level'];
    final questionKo =
        (item['question_native'] ?? item['question_ko'])?.toString() ?? '';

    return Scaffold(
      appBar: AppHubAppBar(
        title: tr('quizSession.progressTitle', {
          'label': label,
          'current': _index + 1,
          'total': _items.length,
        }),
        actions: [
          if (level != null)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: Center(
                child: Chip(
                  label: Text('Lv.$level'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: AppColors.hubQuiz.withValues(alpha: 0.12),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageH,
                AppSpacing.md,
                AppSpacing.pageH,
                AppSpacing.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (_index + 1) / _items.length,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  if (questionKo.isNotEmpty)
                    Text(
                      questionKo,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textMuted,
                          ),
                    ),
                  if (audioUrl == null || audioUrl.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        tr('quizSession.noAudioNote'),
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppSurfaceCard(
                            key: ValueKey(item['id']),
                            child: _buildQuizBody(
                              quizData,
                              audioUrl,
                              answerAudioUrl: answerAudioUrl,
                              questionKo: questionKo,
                            ),
                          ),
                          if (_answered && _lastCorrect != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: (_lastCorrect! ? Colors.green : Colors.red)
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.quizType == 'composition' && _lastQuality != null
                                        ? tr('quizSession.compositionScore', {'score': _lastQuality})
                                        : (_lastCorrect!
                                            ? tr('quizSession.correctBang')
                                            : tr('quizSession.incorrect')),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: _lastCorrect!
                                          ? Colors.green.shade800
                                          : Colors.red.shade800,
                                    ),
                                  ),
                                  if (!_lastCorrect! && _revealedAnswer != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        tr('quizSession.answerLabel', {'answer': _revealedAnswer}),
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.red.shade900,
                                        ),
                                      ),
                                    ),
                                  if (_feedback != null && _feedback!.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withValues(alpha: 0.08),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: Colors.green.withValues(alpha: 0.3),
                                          ),
                                        ),
                                        child: Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Icon(
                                              Icons.lightbulb_outline,
                                              size: 16,
                                              color: Colors.green.shade700,
                                            ),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                _feedback!,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.green.shade900,
                                                  height: 1.4,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    alignment: WrapAlignment.end,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (audioUrl != null && audioUrl.isNotEmpty)
                                        TextButton.icon(
                                          onPressed: () =>
                                              _audioKey.currentState?.play(),
                                          icon: const Icon(
                                            Icons.volume_up_outlined,
                                            size: 18,
                                          ),
                                          label: Text(tr('quizSession.listenAgain')),
                                        ),
                                      if (_lastCorrect == true || _clozeSolved || widget.quizType == 'composition')
                                        FilledButton.tonal(
                                          onPressed: _goNext,
                                          child: Text(tr('chat.nextQuestion')),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuizBody(
    Map<String, dynamic> quizData,
    String? audioUrl, {
    String? answerAudioUrl,
    String? questionKo,
  }) {
    final enabled = !_answered;
    switch (widget.quizType) {
      case 'cloze':
        return ClozeQuizCard(
          key: _clozeKey,
          quizData: quizData,
          audioUrl: audioUrl,
          answerAudioUrl: answerAudioUrl,
          audioButtonKey: _audioKey,
          onSubmit: _submitCloze,
          // The next button remains hidden after a wrong first attempt until
          // the learner retypes the revealed answer correctly.
          onSolved: () {
            if (mounted) setState(() => _clozeSolved = true);
          },
        );
      case 'composition':
        return CompositionQuizCard(
          quizData: quizData,
          question: questionKo ?? '',
          onSubmit: _submitCloze,
        );
      case 'scramble':
        return ScrambleQuizCard(
          quizData: quizData,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          enabled: enabled,
          questionKo: questionKo,
          onHint: _scrambleHint,
          onSubmit: _submitScramble,
        );
      case 'mcq_nuance':
        return McqQuizCard(
          quizData: quizData,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          enabled: enabled,
          onSubmit: _submitMcq,
        );
      default:
        return Text('Unknown quiz type: ${widget.quizType}');
    }
  }
}
