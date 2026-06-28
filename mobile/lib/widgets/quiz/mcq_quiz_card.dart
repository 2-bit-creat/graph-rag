import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'quiz_audio_button.dart';

class McqQuizCard extends StatefulWidget {
  const McqQuizCard({
    super.key,
    required this.quizData,
    required this.onSubmit,
    this.audioUrl,
    this.audioButtonKey,
    this.enabled = true,
  });

  final Map<String, dynamic> quizData;
  final Future<void> Function(int index) onSubmit;
  final String? audioUrl;
  final GlobalKey<QuizAudioButtonState>? audioButtonKey;
  final bool enabled;

  @override
  State<McqQuizCard> createState() => _McqQuizCardState();
}

class _McqQuizCardState extends State<McqQuizCard> {
  int? _selected;
  bool _submitting = false;

  Future<void> _submit() async {
    if (_selected == null || _submitting || !widget.enabled) return;
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(_selected!);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _optionTile(int index, String label) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = _selected == index;
    final bg = isSelected
        ? AppColors.primary.withValues(alpha: 0.12)
        : scheme.surfaceContainerHighest;
    final border = isSelected ? AppColors.primary : scheme.outlineVariant;
    final fg = isSelected ? AppColors.primaryDark : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.enabled && !_submitting
              ? () => setState(() => _selected = index)
              : null,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.lg,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: border, width: isSelected ? 1.5 : 1),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected
                        ? AppColors.primary
                        : scheme.surfaceContainerHigh,
                    border: Border.all(color: border),
                  ),
                  child: Text(
                    String.fromCharCode(65 + index),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? Colors.white : AppColors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: fg,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final promptKo = widget.quizData['prompt_ko']?.toString() ?? '';
    final options = widget.quizData['options'];
    final opts =
        options is List ? options.map((e) => e.toString()).toList() : <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                promptKo,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      height: 1.35,
                    ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            QuizAudioButton(
              key: widget.audioButtonKey,
              audioUrl: widget.audioUrl,
              iconSize: 24,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          '가장 자연스러운 영어 표현을 고르세요',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.textMuted,
                fontSize: 15,
              ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        for (var i = 0; i < opts.length; i++) _optionTile(i, opts[i]),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: widget.enabled && !_submitting && _selected != null
              ? _submit
              : null,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('확인'),
        ),
      ],
    );
  }
}
