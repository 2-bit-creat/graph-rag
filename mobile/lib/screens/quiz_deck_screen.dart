import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../utils/idempotency_key.dart';
import '../widgets/app_ui.dart';
import '../widgets/quiz/flip_card.dart';
import '../widgets/quiz/quiz_audio_button.dart';
import '../widgets/quiz/swipe_deck.dart';

/// Full-screen Quizlet-style review deck.
///
/// Distinct from [QuizSessionScreen], which drills typed answers one card at a
/// time. Here the learner reads the prompt, flips to check themselves, and
/// swipes a verdict — so the grading authority is the learner, and the backend
/// takes `self_grade` instead of comparing an answer string.
///
/// The card list comes from the existing `POST /quiz/session`, so the 70/30
/// review-to-new split and the level window are inherited unchanged.
class QuizDeckScreen extends StatefulWidget {
  const QuizDeckScreen({
    super.key,
    required this.quizType,
    this.entryId,
    this.quizIds,
    this.vocabSource,
    this.language,
  });

  final String quizType;
  final String? entryId;
  final List<String>? quizIds;
  final String? vocabSource;
  final String? language;

  static Route<bool> route({
    required String quizType,
    String? entryId,
    List<String>? quizIds,
    String? vocabSource,
    String? language,
  }) {
    return PageRouteBuilder<bool>(
      opaque: true,
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => QuizDeckScreen(
        quizType: quizType,
        entryId: entryId,
        quizIds: quizIds,
        vocabSource: vocabSource,
        language: language,
      ),
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  State<QuizDeckScreen> createState() => _QuizDeckScreenState();
}

class _QuizDeckScreenState extends State<QuizDeckScreen> {
  final _deck = SwipeDeckController();

  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  bool _flipped = false;
  int _known = 0;
  int _again = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _deck.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final session = await apiClient.startQuizSession(
        quizType: widget.quizType,
        size: widget.quizIds?.length ?? 10,
        entryId: widget.entryId,
        quizIds: widget.quizIds,
        vocabSource: widget.vocabSource,
        language: widget.language,
      );
      final items = (session['items'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _items = items;
        _total = items.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('quizDeck.loadFailed', {'error': e}))),
      );
    }
  }

  /// Pop the card locally first, then record the verdict.
  ///
  /// The deck must not stall on the network: a slow submit would freeze the
  /// stack mid-swipe. A failed submit is surfaced but the card still leaves —
  /// re-showing it would contradict the animation the learner just watched, and
  /// SM-2 will resurface it on the next session anyway.
  Future<void> _onSwipe(SwipeDirection direction) async {
    if (_items.isEmpty) return;
    final item = _items.first;
    final known = direction == SwipeDirection.right;

    setState(() {
      _items = _items.sublist(1);
      _flipped = false;
      if (known) {
        _known++;
      } else {
        _again++;
      }
    });
    unawaited(HapticFeedback.selectionClick());

    try {
      await apiClient.submitQuizAnswer(
        quizId: item['id'].toString(),
        selfGrade: known ? 'known' : 'again',
        entryId: widget.entryId,
        idempotencyKey: newIdempotencyKey('deck'),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('quizDeck.submitFailed', {'error': e}))),
      );
    }
  }

  String _front(Map<String, dynamic> item) {
    final quizData = (item['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final prompt = (item['question_native'] ?? item['question_ko'])?.toString();
    if (prompt != null && prompt.trim().isNotEmpty) return prompt;
    return quizData['prompt']?.toString() ?? '';
  }

  String _back(Map<String, dynamic> item) {
    final quizData = (item['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final sentence =
        (item['sentence_target'] ?? item['sentence_en'])?.toString();
    if (sentence != null && sentence.trim().isNotEmpty) return sentence;
    final accepted = quizData['accepted_answers'];
    if (accepted is List && accepted.isNotEmpty) return accepted.first.toString();
    return quizData['blank']?.toString() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        body: SafeArea(
          child: AppLoadingScreen(message: tr('quizDeck.loading')),
        ),
      );
    }

    if (_total == 0) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(onClose: () => Navigator.pop(context, false)),
              Expanded(
                child: AppEmptyState(
                  icon: Icons.style_outlined,
                  title: tr('quizDeck.emptyTitle'),
                  subtitle: tr('quizDeck.emptySubtitle'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final done = _items.isEmpty;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              onClose: () => Navigator.pop(context, true),
              progress: (_total - _items.length) / _total,
              label: done
                  ? tr('quizDeck.finishedLabel')
                  : tr('quizDeck.progressLabel', {
                      'current': _total - _items.length + 1,
                      'total': _total,
                    }),
            ),
            Expanded(
              child: done
                  ? _Summary(
                      known: _known,
                      again: _again,
                      onClose: () => Navigator.pop(context, true),
                    )
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.pageH,
                        AppSpacing.lg,
                        AppSpacing.pageH,
                        AppSpacing.lg,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: SwipeDeck(
                            controller: _deck,
                            itemCount: _items.length,
                            onSwipe: (_, direction) => _onSwipe(direction),
                            overlayBuilder: _verdictOverlay,
                            itemBuilder: (context, index) {
                              final item = _items[index];
                              // Only the top card is interactive, so only it
                              // tracks the flip state.
                              return _DeckCard(
                                key: ValueKey(item['id']),
                                front: _front(item),
                                back: _back(item),
                                audioUrl: item['audio_url']?.toString(),
                                answerAudioUrl:
                                    item['answer_audio_url']?.toString(),
                                level: (item['difficulty_level'] as num?)
                                    ?.toInt(),
                                flipped: index == 0 && _flipped,
                                onTap: index == 0
                                    ? () => setState(() => _flipped = !_flipped)
                                    : null,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
            ),
            if (!done)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageH,
                  0,
                  AppSpacing.pageH,
                  AppSpacing.xl,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _VerdictButton(
                        icon: Icons.refresh,
                        label: tr('quizDeck.again'),
                        color: AppColors.accentWarm,
                        onPressed: () => _deck.swipe(SwipeDirection.left),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: _VerdictButton(
                        icon: Icons.check,
                        label: tr('quizDeck.known'),
                        color: AppColors.accent,
                        onPressed: () => _deck.swipe(SwipeDirection.right),
                      ),
                    ),
                  ],
                ),
              ),
            if (!done)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                  tr('quizDeck.hint'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _verdictOverlay(
    BuildContext context,
    SwipeDirection direction,
    double progress,
  ) {
    final known = direction == SwipeDirection.right;
    final color = known ? AppColors.accent : AppColors.accentWarm;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16 * progress),
        borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        border: Border.all(
          color: color.withValues(alpha: 0.7 * progress),
          width: 2,
        ),
      ),
      child: Align(
        alignment: known ? Alignment.topRight : Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Opacity(
            opacity: progress,
            child: Icon(
              known ? Icons.check_circle : Icons.refresh,
              color: color,
              size: 44,
            ),
          ),
        ),
      ),
    );
  }
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({
    super.key,
    required this.front,
    required this.back,
    required this.flipped,
    this.audioUrl,
    this.answerAudioUrl,
    this.level,
    this.onTap,
  });

  final String front;
  final String back;
  final bool flipped;
  final String? audioUrl;
  final String? answerAudioUrl;
  final int? level;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FlipCard(
        showBack: flipped,
        front: _face(context, front, isBack: false),
        back: _face(context, back, isBack: true),
      ),
    );
  }

  Widget _face(BuildContext context, String text, {required bool isBack}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 320),
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: BoxDecoration(
        color: isBack ? scheme.surfaceContainerHighest : scheme.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isBack ? tr('quizDeck.answerSide') : tr('quizDeck.promptSide'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              if (level != null)
                Text(
                  'Lv.$level',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    height: 1.4,
                    fontWeight: isBack ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          if (isBack && (audioUrl != null || answerAudioUrl != null))
            Center(
              child: QuizAudioButton(
                audioUrl: audioUrl,
                answerAudioUrl: answerAudioUrl,
              ),
            ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose, this.progress, this.label});

  final VoidCallback onClose;
  final double? progress;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close),
            tooltip: tr('quizDeck.close'),
          ),
          Expanded(
            child: progress == null
                ? const SizedBox.shrink()
                : ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress!.clamp(0.0, 1.0),
                      minHeight: 6,
                    ),
                  ),
          ),
          SizedBox(
            width: 72,
            child: Text(
              label ?? '',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _VerdictButton extends StatelessWidget {
  const _VerdictButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.14),
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.known,
    required this.again,
    required this.onClose,
  });

  final int known;
  final int again;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.celebration_outlined, size: 56, color: AppColors.accent),
          const SizedBox(height: AppSpacing.lg),
          Text(tr('quizDeck.doneTitle'), style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          Text(
            tr('quizDeck.doneSummary', {'known': known, 'again': again}),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.xxl),
          FilledButton(
            onPressed: onClose,
            child: Text(tr('quizDeck.doneClose')),
          ),
        ],
      ),
    );
  }
}
