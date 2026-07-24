import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';

/// Free-writing answer surface. It deliberately avoids one fixed "model
/// answer": writing is graded for grammar and naturalness instead.
class CompositionQuizCard extends StatefulWidget {
  const CompositionQuizCard({
    super.key,
    required this.quizData,
    required this.question,
    required this.onSubmit,
  });

  final Map<String, dynamic> quizData;
  final String question;
  final Future<bool> Function(String answer) onSubmit;

  @override
  State<CompositionQuizCard> createState() => _CompositionQuizCardState();
}

class _CompositionQuizCardState extends State<CompositionQuizCard> {
  final _controller = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || _controller.text.trim().isEmpty) return;
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(_controller.text.trim());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expressions = (widget.quizData['target_expressions'] as List? ?? [])
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList();
    final prompt = widget.question.isNotEmpty
        ? widget.question
        : (widget.quizData['prompt']?.toString() ?? tr('compQuizCard.defaultPrompt'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(prompt, style: Theme.of(context).textTheme.titleMedium?.copyWith(height: 1.4)),
        ),
        if (expressions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(tr('compQuizCard.usefulExpressions'), style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 7),
          Wrap(spacing: 7, runSpacing: 7, children: [
            for (final expression in expressions)
              Chip(label: Text(expression), visualDensity: VisualDensity.compact),
          ]),
        ],
        const SizedBox(height: 18),
        TextField(
          controller: _controller,
          minLines: 4,
          maxLines: 8,
          enabled: !_submitting,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: tr('compQuizCard.answerLabel'),
            hintText: tr('compQuizCard.answerHint'),
            alignLabelWithHint: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.rate_review_outlined),
          label: Text(tr('compQuizCard.gradeButton')),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }
}
