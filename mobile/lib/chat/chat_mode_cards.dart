import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/quiz/cloze_quiz_card.dart';
import '../widgets/quiz/mcq_quiz_card.dart';
import '../widgets/quiz/quiz_audio_button.dart';
import '../widgets/quiz/scramble_quiz_card.dart';

/// Light "sheet" wrapper so the light-themed quiz/draft cards stay legible
/// inside the dark chat panel.
class _CardShell extends StatelessWidget {
  const _CardShell({required this.child, this.title, this.onClose});

  final Widget child;
  final String? title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.shell.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Row(
              children: [
                Expanded(
                  child: Text(title!,
                      // w800 breaks CanvasKit's Korean fallback glyphs on web.
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                if (onClose != null)
                  InkWell(
                    onTap: onClose,
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.close_rounded, size: 18),
                    ),
                  ),
              ],
            ),
          if (title != null) const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

// ── 대화 → 일기 정제 ──────────────────────────────────────────────────────────

class DistillDraftCard extends StatelessWidget {
  const DistillDraftCard({
    super.key,
    required this.sentences,
    required this.loading,
    required this.onToggle,
    required this.onSave,
    required this.onCancel,
  });

  final List<Map<String, dynamic>> sentences;
  final bool loading;
  final void Function(int index, bool included) onToggle;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (loading && sentences.isEmpty) {
      return const _CardShell(
        title: '이 대화 → 일기 초안',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('대화를 정리하는 중…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }

    final includedCount = sentences.where((s) => s['included'] == true).length;
    return _CardShell(
      title: '이 대화 → 일기 초안',
      onClose: onCancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sentences.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('대화에서 새로 정리할 내용을 찾지 못했어요.',
                  style: TextStyle(fontSize: 13)),
            )
          else
            for (var i = 0; i < sentences.length; i++)
              _SentenceRow(
                data: sentences[i],
                onChanged: (v) => onToggle(i, v),
              ),
          const SizedBox(height: 6),
          Text(
            '빼거나 고칠 부분은 아래 입력창에 말해보세요. 예) "첫 문장 빼줘"',
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (loading) ...[
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              TextButton(onPressed: onCancel, child: const Text('취소')),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: includedCount > 0 ? onSave : null,
                icon: const Icon(Icons.auto_stories_rounded, size: 16),
                label: Text('일기로 저장 ($includedCount)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SentenceRow extends StatelessWidget {
  const _SentenceRow({required this.data, required this.onChanged});

  final Map<String, dynamic> data;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final included = data['included'] == true;
    final duplicate = data['duplicate'] == true;
    final matched = (data['matched_statement'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Checkbox(
              value: included,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((data['text'] ?? '').toString(),
                    style: const TextStyle(fontSize: 13.5, height: 1.35)),
                if (duplicate) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          matched.isEmpty
                              ? '이미 그래프에 있음'
                              : '이미 그래프에 있음: "$matched"',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textMuted),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 작문 퀴즈 (composition drill) ─────────────────────────────────────────────

class CompositionDrillCard extends StatefulWidget {
  const CompositionDrillCard({
    super.key,
    required this.quiz,
    required this.feedback,
    required this.busy,
    required this.onNext,
    required this.onExit,
  });

  final Map<String, dynamic> quiz;
  final Map<String, dynamic>? feedback;
  final bool busy;
  final VoidCallback onNext;
  final VoidCallback onExit;

  @override
  State<CompositionDrillCard> createState() => _CompositionDrillCardState();
}

class _CompositionDrillCardState extends State<CompositionDrillCard> {
  @override
  Widget build(BuildContext context) {
    final qd =
        (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final prompt = widget.quiz['question_ko']?.toString() ?? '';
    final glossary = (qd['glossary'] as List?) ?? [];
    final fb = widget.feedback;

    return _CardShell(
      title: '작문 퀴즈',
      onClose: widget.onExit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(prompt,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (glossary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in glossary.take(6))
                  Chip(
                    label: Text(
                      g is Map
                          ? '${g['term'] ?? g['expression'] ?? ''}'
                          : g.toString(),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          if (fb == null)
            Row(
              children: [
                if (widget.busy) ...[
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  const Text('채점 중…', style: TextStyle(fontSize: 12.5)),
                ] else
                  Expanded(
                    child: Text('아래 입력창에 영어로 작문해서 보내보세요.',
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.textMuted)),
                  ),
              ],
            )
          else
            _FeedbackBody(feedback: fb),
          if (fb != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Spacer(),
                FilledButton.icon(
                  onPressed: widget.onNext,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                  label: const Text('다음 문장'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FeedbackBody extends StatelessWidget {
  const _FeedbackBody({required this.feedback});

  final Map<String, dynamic> feedback;

  @override
  Widget build(BuildContext context) {
    final verdictLabel = feedback['verdict_label']?.toString() ?? '';
    final naturalVersions = (feedback['natural_versions'] as List?) ?? [];
    final saveSuggestions = (feedback['save_suggestions'] as List?) ?? [];
    final attemptNote = feedback['attempt_note']?.toString() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (verdictLabel.isNotEmpty)
          Text(verdictLabel,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent)),
        if (attemptNote.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(attemptNote,
              style: const TextStyle(fontSize: 12.5, height: 1.35)),
        ],
        if (saveSuggestions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('유용한 표현',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          for (final item in saveSuggestions)
            if (item is Map &&
                (item['expression'] ?? '').toString().trim().isNotEmpty)
              _SaveSuggestionRow(
                expression: item['expression'].toString().trim(),
                meaning: item['meaning']?.toString() ?? '',
              ),
        ],
        if (naturalVersions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('이렇게도 말할 수 있어요',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          for (final v in naturalVersions)
            _NaturalRow(
              text: v is Map ? (v['text'] ?? '').toString() : v.toString(),
            ),
        ],
      ],
    );
  }
}

class _NaturalRow extends StatelessWidget {
  const _NaturalRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text, style: const TextStyle(fontSize: 13, height: 1.35)),
    );
  }
}

class _SaveSuggestionRow extends StatelessWidget {
  const _SaveSuggestionRow({
    required this.expression,
    required this.meaning,
  });

  final String expression;
  final String meaning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(expression,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (meaning.trim().isNotEmpty)
            Text(meaning,
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

// ── 단어 퀴즈 (self-contained cloze / scramble / mcq cards) ───────────────────

class WordQuizCard extends StatefulWidget {
  const WordQuizCard({
    super.key,
    required this.quiz,
    required this.onSubmit,
    required this.onNext,
    required this.onExit,
    this.externalResult,
    this.clozeSolved = false,
    this.clozeCompletedWords = const [],
    this.clozeLiveDraft = '',
    this.onClozeHintRequested,
  });

  final Map<String, dynamic> quiz;

  /// Grades the answer and returns the raw result (or null on error).
  final Future<Map<String, dynamic>?> Function({
    String? answer,
    List<int>? order,
    int? selectedIndex,
  }) onSubmit;
  final VoidCallback onNext;
  final VoidCallback onExit;
  final Map<String, dynamic>? externalResult;
  final bool clozeSolved;

  /// Words already matched live from the composer, in order (see
  /// ChatSessionController.updateClozeDraft), and the in-progress text for
  /// the word currently being typed.
  final List<String> clozeCompletedWords;
  final String clozeLiveDraft;

  /// Fired after the hint or reveal-answer buttons are tapped — clears a
  /// stale mismatched attempt from the shared composer and returns keyboard
  /// focus to it (those buttons otherwise steal focus with nowhere for it to
  /// go back to, breaking further typing).
  final VoidCallback? onClozeHintRequested;

  @override
  State<WordQuizCard> createState() => _WordQuizCardState();
}

class _WordQuizCardState extends State<WordQuizCard> {
  Map<String, dynamic>? _result;
  bool _solved = false;
  final _audioKey = GlobalKey<QuizAudioButtonState>();

  /// mcq / scramble: single-shot grading — the correct choice/order isn't
  /// known client-side, so there's no way to let the learner retry locally.
  /// Right or wrong, the attempt is final and "다음 문제" unlocks immediately.
  Future<void> _grade({List<int>? order, int? selectedIndex}) async {
    final res =
        await widget.onSubmit(order: order, selectedIndex: selectedIndex);
    if (res == null || !mounted) return;
    setState(() => _result = res);
    _audioKey.currentState?.play(showError: false);
  }

  /// cloze: first attempt goes to the backend; the card itself then allows
  /// the learner to retype the revealed answer until it matches, without
  /// hitting the backend again (a second submit would double-grade the SM2
  /// review).
  Future<bool> _gradeCloze(String answer) async {
    final res = await widget.onSubmit(answer: answer);
    if (res == null) return false;
    if (mounted) setState(() => _result = res);
    return res['is_correct'] == true;
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.quiz['quiz_type']?.toString() ?? 'cloze';
    final qd =
        (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final effectiveResult = widget.externalResult ?? _result;
    final answered = effectiveResult != null;
    final audioUrl =
        widget.quiz['audio_url']?.toString() ?? qd['audio_url']?.toString();

    Widget card;
    switch (type) {
      case 'scramble':
        card = ScrambleQuizCard(
          quizData: qd,
          enabled: !answered,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          onSubmit: (order) => _grade(order: order),
        );
        break;
      case 'mcq_nuance':
      case 'mcq':
        card = McqQuizCard(
          quizData: qd,
          enabled: !answered,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          onSubmit: (i) => _grade(selectedIndex: i),
        );
        break;
      case 'cloze':
      default:
        card = ClozeQuizCard(
          quizData: qd,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          onSubmit: _gradeCloze,
          onSolved: () => setState(() => _solved = true),
          externalInput: true,
          externalResult: widget.externalResult,
          externalSolved: widget.clozeSolved,
          externalCompletedWords: widget.clozeCompletedWords,
          externalLiveDraft: widget.clozeLiveDraft,
          onHintRequested: widget.onClozeHintRequested,
        );
    }

    // cloze retries locally until correct; mcq/scramble grade once and move on
    // regardless of the outcome (see _grade above).
    final isCloze = type != 'scramble' && type != 'mcq' && type != 'mcq_nuance';
    final clozeComplete = widget.clozeSolved || _solved;
    final isCorrect =
        isCloze ? clozeComplete : effectiveResult?['is_correct'] == true;
    final readyForNext = isCloze ? clozeComplete : answered;

    return _CardShell(
      title: '단어 퀴즈',
      onClose: widget.onExit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          card,
          if (isCloze && readyForNext) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: widget.onNext,
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: const Text('다음 문제'),
            ),
          ] else if (answered && !isCloze) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  isCorrect
                      ? Icons.check_circle_rounded
                      : (isCloze
                          ? Icons.edit_note_rounded
                          : Icons.cancel_rounded),
                  size: 18,
                  color: isCorrect
                      ? Colors.green
                      : (isCloze ? Colors.orange : Colors.redAccent),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isCorrect ? '정답!' : (isCloze ? '정답을 직접 입력해서 완성해보세요' : '오답'),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                if (readyForNext)
                  FilledButton.icon(
                    onPressed: widget.onNext,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                    label: const Text('다음 문제'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
