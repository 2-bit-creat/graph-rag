import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/quiz/cloze_quiz_card.dart';
import '../widgets/quiz/mcq_quiz_card.dart';
import '../widgets/quiz/quiz_audio_button.dart';
import '../widgets/quiz/scramble_quiz_card.dart';

class QuizSessionScreen extends StatefulWidget {
  const QuizSessionScreen({
    super.key,
    required this.quizType,
    this.entryId,
    this.quizIds,
  });

  final String quizType;
  final String? entryId;
  final List<String>? quizIds;

  @override
  State<QuizSessionScreen> createState() => _QuizSessionScreenState();
}

class _QuizSessionScreenState extends State<QuizSessionScreen> {
  List<Map<String, dynamic>> _items = [];
  int _index = 0;
  bool _loading = true;
  bool _answered = false;
  bool? _lastCorrect;
  String? _feedback;
  String? _revealedAnswer;

  final _audioKey = GlobalKey<QuizAudioButtonState>();

  static const _typeLabels = {
    'cloze': '단어 완성',
    'scramble': '문장 배열',
    'mcq_nuance': '뉘앙스 선택',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final session = await apiClient.startQuizSession(
        quizType: widget.quizType,
        size: widget.quizIds?.length ?? 10,
        entryId: widget.entryId,
        quizIds: widget.quizIds,
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
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('세션 로드 실패: $e')),
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

  Future<void> _handleResult(Map<String, dynamic> result) async {
    final correct = result['correct'] == true;
    final item = _current!;
    final quizData = Map<String, dynamic>.from(
      (item['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {},
    );

    setState(() {
      _answered = true;
      _lastCorrect = correct;
      _feedback = result['explanation']?.toString();
      if (!correct && widget.quizType == 'cloze') {
        _revealedAnswer = _clozeAnswer(quizData);
      }
    });

    if (correct) {
      unawaited(_audioKey.currentState?.play(showError: false));
    }
  }

  void _goNext() {
    if (_index < _items.length - 1) {
      setState(() {
        _index++;
        _answered = false;
        _lastCorrect = null;
        _feedback = null;
        _revealedAnswer = null;
      });
    } else {
      Navigator.pop(context, true);
    }
  }

  Future<void> _submitCloze(String answer) async {
    final item = _current!;
    final result = await apiClient.submitQuizAnswer(
      quizId: item['id'].toString(),
      answer: answer,
      entryId: widget.entryId,
    );
    await _handleResult(result);
  }

  Future<void> _submitScramble(List<int> order) async {
    final item = _current!;
    final result = await apiClient.submitQuizAnswer(
      quizId: item['id'].toString(),
      order: order,
      entryId: widget.entryId,
    );
    await _handleResult(result);
  }

  Future<void> _submitMcq(int index) async {
    final item = _current!;
    final result = await apiClient.submitQuizAnswer(
      quizId: item['id'].toString(),
      selectedIndex: index,
      entryId: widget.entryId,
    );
    await _handleResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final label = _typeLabels[widget.quizType] ?? widget.quizType;
    if (_loading) {
      return Scaffold(
        appBar: AppHubAppBar(title: '$label 퀴즈'),
        body: const AppLoadingScreen(message: '문제 불러오는 중…'),
      );
    }
    if (_items.isEmpty) {
      return Scaffold(
        appBar: AppHubAppBar(title: '$label 퀴즈'),
        body: AppEmptyState(
          icon: Icons.inbox_outlined,
          title: '큐에 문제가 없습니다',
          subtitle: '개발자 도구 → 문제 생성에서 새 문제를 만든 뒤 다시 시도하세요.',
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
    final level = item['difficulty_level'];
    final questionKo = item['question_ko']?.toString() ?? '';

    return Scaffold(
      appBar: AppHubAppBar(
        title: '$label ${_index + 1}/${_items.length}',
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
                            color: context.mutedText,
                          ),
                    ),
                  if (audioUrl == null || audioUrl.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '이 문제에는 음성이 없습니다. 새로 생성한 문제만 재생됩니다.',
                        style: TextStyle(fontSize: 12, color: context.mutedText),
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
                            child: _buildQuizBody(quizData, audioUrl, questionKo: questionKo),
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
                                    _lastCorrect! ? '정답!' : '오답',
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
                                        '정답: $_revealedAnswer',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.red.shade900,
                                        ),
                                      ),
                                    ),
                                  if (_lastCorrect! && _feedback != null && _feedback!.isNotEmpty)
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
                                          label: const Text('다시 듣기'),
                                        ),
                                      FilledButton.tonal(
                                        onPressed: _goNext,
                                        child: const Text('다음 문제'),
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

  Widget _buildQuizBody(Map<String, dynamic> quizData, String? audioUrl, {String? questionKo}) {
    final enabled = !_answered;
    switch (widget.quizType) {
      case 'cloze':
        return ClozeQuizCard(
          quizData: quizData,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          showCorrectAnswer: _answered && _lastCorrect == false,
          enabled: enabled,
          onSubmit: _submitCloze,
        );
      case 'scramble':
        return ScrambleQuizCard(
          quizData: quizData,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          enabled: enabled,
          questionKo: questionKo,
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
