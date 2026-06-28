import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'quiz_audio_button.dart';

class ScrambleQuizCard extends StatefulWidget {
  const ScrambleQuizCard({
    super.key,
    required this.quizData,
    required this.onSubmit,
    this.audioUrl,
    this.audioButtonKey,
    this.enabled = true,
    this.questionKo,
  });

  final Map<String, dynamic> quizData;
  final Future<void> Function(List<int> order) onSubmit;
  final String? audioUrl;
  final GlobalKey<QuizAudioButtonState>? audioButtonKey;
  final bool enabled;
  final String? questionKo;

  @override
  State<ScrambleQuizCard> createState() => _ScrambleQuizCardState();
}

class _ScrambleQuizCardState extends State<ScrambleQuizCard> {
  late List<int> _poolIndices;
  final List<int> _selectedIndices = [];
  bool _submitting = false;

  List<String> get _chunks {
    final raw = widget.quizData['chunks'];
    if (raw is! List) return [];
    return raw.map((e) => e.toString()).toList();
  }

  @override
  void initState() {
    super.initState();
    _resetPool();
  }

  void _resetPool() {
    if (_submitting) return;
    setState(() {
      _poolIndices = List.generate(_chunks.length, (i) => i);
      _poolIndices.shuffle();
      _selectedIndices.clear();
    });
  }

  void _tapPoolIndex(int poolIdx) {
    if (_submitting) return;
    setState(() {
      final chunkIdx = _poolIndices.removeAt(poolIdx);
      _selectedIndices.add(chunkIdx);
    });
  }

  void _returnSelected(int selectedIdx) {
    if (_submitting) return;
    setState(() {
      final chunkIdx = _selectedIndices.removeAt(selectedIdx);
      _poolIndices.add(chunkIdx);
    });
  }

  void _undoLast() {
    if (_submitting || _selectedIndices.isEmpty) return;
    setState(() {
      final chunkIdx = _selectedIndices.removeLast();
      _poolIndices.add(chunkIdx);
    });
  }

  Future<void> _submit() async {
    if (_submitting || !widget.enabled) return;
    if (_selectedIndices.length != _chunks.length) return;
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(List<int>.from(_selectedIndices));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _wordChip({
    required String label,
    required VoidCallback onTap,
    required bool isSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final bg = isSelected
        ? AppColors.primary.withValues(alpha: 0.14)
        : scheme.surfaceContainerHighest;
    final border = isSelected ? AppColors.primary : scheme.outlineVariant;
    final fg = isSelected ? AppColors.primaryDark : scheme.onSurface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            border: Border.all(color: border, width: isSelected ? 1.5 : 1),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: fg,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.questionKo ?? '';
    final chunks = _chunks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hint.isNotEmpty)
              Expanded(
                child: Text(
                  hint,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textMuted,
                        fontStyle: FontStyle.italic,
                        height: 1.45,
                      ),
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: AppSpacing.sm),
            QuizAudioButton(
              key: widget.audioButtonKey,
              audioUrl: widget.audioUrl,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        Text(
          '내 답안',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppColors.textMuted,
              ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: _selectedIndices.isEmpty
              ? Text(
                  '아래 단어를 순서대로 탭하세요',
                  style: TextStyle(
                    color: AppColors.textMuted.withValues(alpha: 0.8),
                    fontSize: 14,
                  ),
                )
              : Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (var i = 0; i < _selectedIndices.length; i++)
                      _wordChip(
                        label: chunks[_selectedIndices[i]],
                        isSelected: true,
                        onTap: () => _returnSelected(i),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Text(
          '단어 조각',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppColors.textMuted,
              ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (var i = 0; i < _poolIndices.length; i++)
              _wordChip(
                label: chunks[_poolIndices[i]],
                isSelected: false,
                onTap: () => _tapPoolIndex(i),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        Row(
          children: [
            TextButton(onPressed: _undoLast, child: const Text('되돌리기')),
            TextButton(onPressed: _resetPool, child: const Text('초기화')),
            const Spacer(),
            FilledButton(
              onPressed: widget.enabled &&
                      !_submitting &&
                      _selectedIndices.length == chunks.length
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
        ),
      ],
    );
  }
}
