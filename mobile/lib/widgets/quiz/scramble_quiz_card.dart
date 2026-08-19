import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import 'quiz_audio_button.dart';

class ScrambleQuizCard extends StatefulWidget {
  const ScrambleQuizCard({
    super.key,
    required this.quizData,
    required this.onSubmit,
    this.onHint,
    this.audioUrl,
    this.audioButtonKey,
    this.enabled = true,
    this.questionKo,
  });

  final Map<String, dynamic> quizData;

  /// Grades the arrangement. [hintLevel] is how many chunks the learner had
  /// placed for them, so the attempt records assisted answers honestly.
  final Future<void> Function(List<String> order, int hintLevel) onSubmit;

  /// Asks the backend for the first N chunks of the reference order (the
  /// answer key is withheld client-side, so hints have to be served). Returns
  /// the raw `{hint_level, ordered_prefix, max_hint_level}` response.
  final Future<Map<String, dynamic>?> Function(int hintLevel)? onHint;
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

  /// Hint state: how many leading chunks the backend has placed. Those sit at
  /// the front of [_selectedIndices] and are locked — undo/reset/tap must not
  /// take them back out, otherwise the hint stops being a hint.
  int _hintLevel = 0;
  bool _hintBusy = false;
  int? _maxHintLevel;

  // Hide the speaker until the card is answered/disabled — hearing the
  // sentence beforehand gives the word order away.
  bool get _showAudio => !widget.enabled;

  List<Map<String, String>> get _chunks {
    final raw = widget.quizData['chunks'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) => {
      'id': e['id'].toString(),
      'text': e['text'].toString(),
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _resetPool();
  }

  void _resetPool() {
    if (_submitting) return;
    setState(() {
      // The server shuffled this exact order once. Re-shuffling here makes
      // reproduction/debugging needlessly non-deterministic.
      final locked = _selectedIndices.take(_hintLevel).toList();
      _selectedIndices
        ..clear()
        ..addAll(locked);
      _poolIndices = [
        for (var i = 0; i < _chunks.length; i++)
          if (!locked.contains(i)) i,
      ];
    });
  }

  /// Places the next chunk of the reference order for the learner. Everything
  /// already placed after the new prefix goes back to the pool, so the board
  /// stays consistent with the hint instead of silently contradicting it.
  Future<void> _requestHint() async {
    final onHint = widget.onHint;
    if (onHint == null || _hintBusy || _submitting || !widget.enabled) return;
    setState(() => _hintBusy = true);
    try {
      final res = await onHint(_hintLevel + 1);
      if (!mounted || res == null) return;
      final prefix = (res['ordered_prefix'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      final maxLevel = (res['max_hint_level'] as num?)?.toInt();
      final chunks = _chunks;
      final placed = <int>[];
      for (final id in prefix) {
        final index = chunks.indexWhere((chunk) => chunk['id'] == id);
        if (index >= 0) placed.add(index);
      }
      setState(() {
        _maxHintLevel = maxLevel;
        _hintLevel = placed.length;
        _selectedIndices
          ..clear()
          ..addAll(placed);
        _poolIndices = [
          for (var i = 0; i < chunks.length; i++)
            if (!placed.contains(i)) i,
        ];
      });
      if (placed.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('scrambleCard.hintExhausted'))),
        );
      }
    } finally {
      if (mounted) setState(() => _hintBusy = false);
    }
  }

  void _tapPoolIndex(int poolIdx) {
    if (_submitting) return;
    setState(() {
      final chunkIdx = _poolIndices.removeAt(poolIdx);
      _selectedIndices.add(chunkIdx);
    });
  }

  void _returnSelected(int selectedIdx) {
    if (_submitting || selectedIdx < _hintLevel) return;
    setState(() {
      final chunkIdx = _selectedIndices.removeAt(selectedIdx);
      _poolIndices.add(chunkIdx);
    });
  }

  void _undoLast() {
    if (_submitting || _selectedIndices.length <= _hintLevel) return;
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
      await widget.onSubmit([
        for (final index in _selectedIndices) _chunks[index]['id']!,
      ], _hintLevel);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _wordChip({
    required String label,
    required VoidCallback onTap,
    required bool isSelected,
    bool locked = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final bg = locked
        ? AppColors.accent.withValues(alpha: 0.16)
        : isSelected
            ? AppColors.primary.withValues(alpha: 0.14)
            : scheme.surfaceContainerHighest;
    final border = locked
        ? AppColors.accent
        : isSelected
            ? AppColors.primary
            : scheme.outlineVariant;
    final fg = locked
        ? AppColors.accent
        : isSelected
            ? AppColors.primaryDark
            : scheme.onSurface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: locked ? null : onTap,
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (locked) ...[
                Icon(Icons.lightbulb_rounded, size: 14, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: fg,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The backend caps hints at "everything but the last two chunks" — past
  /// that there is nothing left to work out. [_maxHintLevel] is unknown until
  /// the first hint comes back, so the button starts enabled.
  bool get _hintExhausted =>
      _maxHintLevel != null && _hintLevel >= _maxHintLevel!;

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
            Offstage(
              offstage: !_showAudio,
              child: Padding(
                padding: const EdgeInsets.only(left: AppSpacing.sm),
                child: QuizAudioButton(
                  key: widget.audioButtonKey,
                  audioUrl: widget.audioUrl,
                  preload: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        if (!widget.enabled && (widget.quizData['sentence_target']?.toString().isNotEmpty ?? false)) ...[
          Text(
            tr('scrambleCard.correctSentence'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: AppColors.textMuted,
                ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            widget.quizData['sentence_target'].toString(),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.45,
                ),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
        Text(
          tr('scrambleCard.myAnswer'),
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
                  tr('scrambleCard.tapWordsInOrder'),
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
                        label: chunks[_selectedIndices[i]]['text']!,
                        isSelected: true,
                        locked: i < _hintLevel,
                        onTap: () => _returnSelected(i),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Text(
          tr('scrambleCard.wordPieces'),
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
                label: chunks[_poolIndices[i]]['text']!,
                isSelected: false,
                onTap: () => _tapPoolIndex(i),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        Row(
          children: [
            TextButton(onPressed: _undoLast, child: Text(tr('scrambleCard.undo'))),
            TextButton(onPressed: _resetPool, child: Text(tr('scrambleCard.reset'))),
            if (widget.onHint != null && widget.enabled)
              TextButton.icon(
                onPressed: _hintExhausted || _hintBusy ? null : _requestHint,
                icon: _hintBusy
                    ? const SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lightbulb_outline_rounded, size: 16),
                label: Text(tr('scrambleCard.hint')),
              ),
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
                  : Text(tr('common.confirm')),
            ),
          ],
        ),
      ],
    );
  }
}
