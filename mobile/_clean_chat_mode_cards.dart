import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/mention_editor_core.dart' show colorForSpeaker;
import '../widgets/quiz/cloze_quiz_card.dart';
import '../widgets/quiz/mcq_quiz_card.dart';
import '../widgets/quiz/scramble_quiz_card.dart';

/// Light "sheet" wrapper so the light-themed quiz/draft cards stay legible
/// inside the dark chat panel.
class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.child,
    this.title,
    this.onClose,
  });

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
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800)),
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

// ?�?� ?�?????�기 ?�제 ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

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
        title: '???�?????�기 초안',
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
              Text('?�?��? ?�리?�는 중�?, style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }

    final includedCount = sentences.where((s) => s['included'] == true).length;
    return _CardShell(
      title: '???�?????�기 초안',
      onClose: onCancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '?��? 채팅?�서 ??말만 ?�리?�요 (AI ?��? ?�외). 체크 ???�?�하거나 ?�래 ?�력창으�??�정.',
            style: TextStyle(
                fontSize: 11.5, color: context.mutedText, height: 1.35),
          ),
          const SizedBox(height: 10),
          if (sentences.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('?�?�에???�로 ?�리???�용??찾�? 못했?�요.',
                  style: TextStyle(fontSize: 13)),
            )
          else
            for (var i = 0; i < sentences.length; i++)
              _SentenceRow(
                data: sentences[i],
                onChanged: (v) => onToggle(i, v),
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
                label: Text('?�기�??�??($includedCount)'),
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
    final speaker = (data['speaker'] ?? '??).toString().trim();
    final showSpeaker = speaker.isNotEmpty && speaker != '??;
    final speakerColor = colorForSpeaker(speaker, ['??, if (showSpeaker) speaker]);
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
                if (showSpeaker)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: speakerColor,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '@$speaker',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                Text((data['text'] ?? '').toString(),
                    style: const TextStyle(fontSize: 13.5, height: 1.35)),
                if (duplicate) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 12, color: context.mutedText),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          matched.isEmpty
                              ? '?��? 그래?�에 ?�음'
                              : '?��? 그래?�에 ?�음: "$matched"',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: context.mutedText),
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

// ?�?� ?�문 ?�즈 (composition drill) ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

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

  Future<void> _save(String expression) async {
    if (_saving || expression.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      await apiClient.saveTutorExpression(
        expression: expression,
        promptKo: widget.quiz['question_ko']?.toString() ?? '',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('복습 ?�어?�에 ?�았?�요.')),
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

  @override
  Widget build(BuildContext context) {
    final qd = (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final prompt = widget.quiz['question_ko']?.toString() ?? '';
    final glossary = (qd['glossary'] as List?) ?? [];
    final fb = widget.feedback;

    return _CardShell(
      title: '?�문 ?�즈',
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
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      g is Map
                          ? '${g['term'] ?? g['expression'] ?? ''}'
                          : g.toString(),
                      style: const TextStyle(fontSize: 11),
                    ),
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
                  const Text('채점 중�?, style: TextStyle(fontSize: 12.5)),
                ] else
                  Expanded(
                    child: Text('?�래 ?�력창에 ?�어�??�문?�서 보내보세??',
                        style: TextStyle(
                            fontSize: 12.5, color: context.mutedText)),
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
                  label: const Text('?�음 문장'),
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
          Text('?�렇게도 말할 ???�어??,
              style: TextStyle(fontSize: 11.5, color: context.mutedText)),
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
            tooltip: '복습 ?�어?�에 ?�기',
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

// ?�?� ?�어 ?�즈 (self-contained cloze / scramble / mcq cards) ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

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

  Future<void> _grade({String? answer, List<int>? order, int? selectedIndex}) async {
    final res = await widget.onSubmit(
        answer: answer, order: order, selectedIndex: selectedIndex);
    if (res != null && mounted) setState(() => _result = res);
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.quiz['quiz_type']?.toString() ?? 'cloze';
    final qd = (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final answered = _result != null;

    Widget card;
    switch (type) {
      case 'scramble':
        card = ScrambleQuizCard(
          quizData: qd,
          enabled: !answered,
          onSubmit: (order) => _grade(order: order),
        );
        break;
      case 'mcq_nuance':
      case 'mcq':
        card = McqQuizCard(
          quizData: qd,
          enabled: !answered,
          onSubmit: (i) => _grade(selectedIndex: i),
        );
        break;
      case 'cloze':
      default:
        card = ClozeQuizCard(
          quizData: qd,
          enabled: !answered,
          showCorrectAnswer: answered,
          onSubmit: (a) => _grade(answer: a),
        );
    }

    return _CardShell(
      title: '?�어 ?�즈',
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
                  _result!['is_correct'] == true
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: 18,
                  color: _result!['is_correct'] == true
                      ? Colors.green
                      : Colors.redAccent,
                ),
                const SizedBox(width: 6),
                Text(_result!['is_correct'] == true ? '?�답!' : '?�답',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                const Spacer(),
                FilledButton.icon(
                  onPressed: widget.onNext,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                  label: const Text('?�음 문제'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
