import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart' show nodeDisplayLabel;

/// Confirm merging one graph node into another, and decide which name survives.
///
/// The gesture that opens this (long-press a node, drag it onto another) is
/// cheap to perform by accident, and the merge itself is the one place in the
/// app where edges are rewritten and a node disappears. So the drop does not
/// merge anything — it asks. Everything the answer depends on is stated here:
/// which node goes away, how many relations move, and that the discarded name
/// is kept as an alias rather than lost.
class NodeMergeSheet extends StatefulWidget {
  const NodeMergeSheet({
    super.key,
    required this.source,
    required this.target,
    required this.movingEdgeCount,
  });

  /// The node that disappears — its edges, provenance and importance move to
  /// [target], and its name is learned as an alias there.
  final Map<String, dynamic> source;
  final Map<String, dynamic> target;

  /// Relations currently attached to [source]. Shown because it is the size of
  /// the change: merging a node with 30 edges is not the same act as merging a
  /// stray duplicate with one.
  final int movingEdgeCount;

  /// The name to keep, or null when the user backed out.
  static Future<String?> show(
    BuildContext context, {
    required Map<String, dynamic> source,
    required Map<String, dynamic> target,
    required int movingEdgeCount,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      useSafeArea: true,
      builder: (_) => NodeMergeSheet(
        source: source,
        target: target,
        movingEdgeCount: movingEdgeCount,
      ),
    );
  }

  @override
  State<NodeMergeSheet> createState() => _NodeMergeSheetState();
}

class _NodeMergeSheetState extends State<NodeMergeSheet> {
  late String _keptName = nodeDisplayLabel(widget.target);

  String get _sourceName => nodeDisplayLabel(widget.source);
  String get _targetName => nodeDisplayLabel(widget.target);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Both names are offered, deduplicated: an OCR duplicate can carry the
    // exact same string, and two identical chips would read as a bug.
    final nameOptions = <String>[
      _targetName,
      if (_sourceName != _targetName) _sourceName,
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.pageH,
        0,
        AppSpacing.pageH,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('nodeMerge.title'), style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          // Direction is the part people get wrong, so draw it rather than
          // describe it: the left node is the one that stops existing.
          Row(
            children: [
              Expanded(
                child: _NodeChip(
                  label: _sourceName,
                  caption: tr('nodeMerge.disappears'),
                  strikethrough: true,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Icon(Icons.arrow_forward_rounded, size: 18),
              ),
              Expanded(
                child: _NodeChip(
                  label: _targetName,
                  caption: tr('nodeMerge.survives'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            tr('nodeMerge.body', {
              'source': _sourceName,
              'target': _targetName,
              'edges': '${widget.movingEdgeCount}',
            }),
            style: theme.textTheme.bodySmall,
          ),
          if (nameOptions.length > 1) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              tr('nodeMerge.keepNameLabel'),
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final name in nameOptions)
                  ChoiceChip(
                    label: Text(name),
                    selected: _keptName == name,
                    onSelected: (_) => setState(() => _keptName = name),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // The discarded name is not deleted — it becomes a searchable alias
            // and a fuzzy-resolution surface, which is why picking either side
            // is safe. Saying so is what makes the choice feel reversible.
            Text(
              tr('nodeMerge.aliasNote'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('common.cancel')),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _keptName),
                  child: Text(tr('nodeMerge.confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NodeChip extends StatelessWidget {
  const _NodeChip({
    required this.label,
    required this.caption,
    this.strikethrough = false,
  });

  final String label;
  final String caption;
  final bool strikethrough;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              decoration: strikethrough ? TextDecoration.lineThrough : null,
              color: strikethrough ? AppColors.textMuted : null,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
