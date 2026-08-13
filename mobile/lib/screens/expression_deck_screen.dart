import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/quiz/flip_card.dart';

/// A quiet, read-only Quizlet-style deck for expressions extracted from
/// Statement nodes. Tapping a card reveals its meaning; paging changes cards.
class ExpressionDeckScreen extends StatefulWidget {
  const ExpressionDeckScreen({super.key, required this.items});

  final List<Map<String, dynamic>> items;

  static Route<void> route(List<Map<String, dynamic>> items) {
    return MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ExpressionDeckScreen(items: items),
    );
  }

  /// Fetch the deck and open it, reporting empty/failed loads on the caller's
  /// messenger. Lives here (not on a host screen) so any entry point — the
  /// sidebar menu today, anything else later — opens the deck the same way.
  static Future<void> open(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final data = await apiClient.graphExpressionCards();
      final items = (data['items'] as List<dynamic>? ?? [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (items.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('expressionDeck.empty'))),
        );
        return;
      }
      await navigator.push(route(items));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('expressionDeck.loadFailed', {'error': e}))),
      );
    }
  }

  @override
  State<ExpressionDeckScreen> createState() => _ExpressionDeckScreenState();
}

class _ExpressionDeckScreenState extends State<ExpressionDeckScreen> {
  final _pageController = PageController(viewportFraction: .92);
  var _index = 0;
  var _flipped = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final next = (_index + delta).clamp(0, widget.items.length - 1);
    if (next == _index) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(tr('expressionDeck.title')),
        centerTitle: false,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageH,
                AppSpacing.sm,
                AppSpacing.pageH,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  Text(
                    '${_index + 1} / ${widget.items.length}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: (_index + 1) / widget.items.length,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(99),
                      backgroundColor: colors.surfaceContainerHighest,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.items.length,
                onPageChanged: (value) => setState(() {
                  _index = value;
                  _flipped = false;
                }),
                itemBuilder: (context, index) {
                  final item = widget.items[index];
                  final expression = item['expression']?.toString() ?? '';
                  final meaning = item['meaning']?.toString().trim() ?? '';
                  final example = item['example']?.toString().trim() ?? '';
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.md,
                    ),
                    child: GestureDetector(
                      onTap: index == _index
                          ? () => setState(() => _flipped = !_flipped)
                          : null,
                      child: FlipCard(
                        showBack: index == _index && _flipped,
                        front: _ExpressionFace(
                          label: tr('expressionDeck.expressionSide'),
                          text: expression,
                          hint: tr('expressionDeck.flipHint'),
                        ),
                        back: _ExpressionFace(
                          label: tr('expressionDeck.meaningSide'),
                          text: meaning.isEmpty
                              ? tr('expressionDeck.noMeaning')
                              : meaning,
                          detail: example,
                          isBack: true,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageH,
                AppSpacing.sm,
                AppSpacing.pageH,
                AppSpacing.xl,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton.outlined(
                    onPressed: _index == 0 ? null : () => _move(-1),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _flipped = !_flipped),
                    child: Text(_flipped
                        ? tr('expressionDeck.showExpression')
                        : tr('expressionDeck.showMeaning')),
                  ),
                  IconButton.outlined(
                    onPressed: _index == widget.items.length - 1
                        ? null
                        : () => _move(1),
                    icon: const Icon(Icons.arrow_forward_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpressionFace extends StatelessWidget {
  const _ExpressionFace({
    required this.label,
    required this.text,
    this.hint,
    this.detail = '',
    this.isBack = false,
  });

  final String label;
  final String text;
  final String? hint;
  final String detail;
  final bool isBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: BoxDecoration(
        color: isBack ? colors.surfaceContainerHigh : colors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Text(
                      text,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        detail,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (hint != null)
            Align(
              alignment: Alignment.center,
              child: Text(
                hint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
