import 'package:flutter/material.dart';

import '../api/client.dart';
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
  bool _saving = false;
  Set<String> _savedExpressions = {};

  @override
  void initState() {
    super.initState();
    _loadVocabStatus();
  }

  Future<void> _loadVocabStatus() async {
    try {
      final res = await apiClient.getTutorVocab();
      final items = (res['items'] as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _savedExpressions = items
            .map((e) => (e is Map ? (e['expression'] ?? '') : '')
                .toString()
                .trim()
                .toLowerCase())
            .where((s) => s.isNotEmpty)
            .toSet();
      });
    } catch (_) {
      // Non-fatal — glossary chips just fall back to showing the add button.
    }
  }

  Future<void> _save(String expression) async {
    if (_saving || expression.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      await apiClient.saveTutorExpression(
        expression: expression,
        promptKo: widget.quiz['question_ko']?.toString() ?? '',
      );
      if (mounted) {
        setState(() => _savedExpressions.add(expression.trim().toLowerCase()));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('복습 단어장에 담았어요.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _glossaryChip(dynamic g) {
    final term = g is Map
        ? '${g['term'] ?? g['expression'] ?? ''}'
        : g.toString();
    final target = g is Map ? (g['target']?.toString() ?? '') : '';
    final expression = target.isNotEmpty ? target : term;
    return _GlossaryChip(
      term: term,
      expression: expression,
      saved: _savedExpressions.contains(expression.trim().toLowerCase()),
      busy: _saving,
      onAdd: _save,
    );
  }

  @override
  Widget build(BuildContext context) {
    final qd = (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
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
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (glossary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in glossary.take(6))
                  _glossaryChip(g),
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
            _FeedbackBody(feedback: fb, saving: _saving, onSave: _save),
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

class _GlossaryChip extends StatelessWidget {
  const _GlossaryChip({
    required this.term,
    required this.expression,
    required this.saved,
    required this.busy,
    required this.onAdd,
  });

  final String term;
  final String expression;
  final bool saved;
  final bool busy;
  final Future<void> Function(String expression) onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(term,
              style:
                  TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 2),
          if (saved)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.check_circle_rounded,
                  size: 15, color: Colors.green),
            )
          else
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: busy || expression.trim().isEmpty
                  ? null
                  : () => onAdd(expression),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.add_circle_outline_rounded, size: 15),
              ),
            ),
        ],
      ),
    );
  }
}

class _FeedbackBody extends StatelessWidget {
  const _FeedbackBody({
    required this.feedback,
    required this.saving,
    required this.onSave,
  });

  final Map<String, dynamic> feedback;
  final bool saving;
  final Future<void> Function(String expression) onSave;

  @override
  Widget build(BuildContext context) {
    final verdictLabel = feedback['verdict_label']?.toString() ?? '';
    final naturalVersions = (feedback['natural_versions'] as List?) ?? [];
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
          Text(attemptNote, style: const TextStyle(fontSize: 12.5, height: 1.35)),
        ],
        if (naturalVersions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('이렇게도 말할 수 있어요',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          for (final v in naturalVersions)
            _NaturalRow(
              text: v is Map ? (v['text'] ?? '').toString() : v.toString(),
              saving: saving,
              onSave: onSave,
            ),
        ],
      ],
    );
  }
}

class _NaturalRow extends StatelessWidget {
  const _NaturalRow(
      {required this.text, required this.saving, required this.onSave});

  final String text;
  final bool saving;
  final Future<void> Function(String expression) onSave;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 13, height: 1.35)),
          ),
          IconButton(
            tooltip: '복습 단어장에 담기',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: saving ? null : () => onSave(text),
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
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
    final qd = (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final answered = _result != null;
    final audioUrl = widget.quiz['audio_url']?.toString() ??
        qd['audio_url']?.toString();

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
        );
    }

    // cloze retries locally until correct; mcq/scramble grade once and move on
    // regardless of the outcome (see _grade above).
    final isCloze = type != 'scramble' && type != 'mcq' && type != 'mcq_nuance';
    final isCorrect = isCloze ? _solved : _result?['is_correct'] == true;
    final readyForNext = isCloze ? _solved : answered;

    return _CardShell(
      title: '단어 퀴즈',
      onClose: widget.onExit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          card,
          if (answered) ...[
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
                    isCorrect
                        ? '정답!'
                        : (isCloze ? '정답을 직접 입력해서 완성해보세요' : '오답'),
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
