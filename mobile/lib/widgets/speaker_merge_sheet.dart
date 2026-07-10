import 'package:flutter/material.dart';

import '../api/client.dart';

/// Drag-and-drop speaker grouping: long-press a speaker card and drop it onto
/// another to merge them; tap a merged card's split icon to break it apart.
/// Sends a group_map (speaker_original -> group label) on apply. Fully reversible
/// because the original diarization label is preserved per segment.
Future<bool?> showSpeakerMergeSheet({
  required BuildContext context,
  required String entryId,
  required List<dynamic> segments,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SpeakerMergeSheet(entryId: entryId, segments: segments),
  );
}

class _SpeakerMergeSheet extends StatefulWidget {
  const _SpeakerMergeSheet({required this.entryId, required this.segments});

  final String entryId;
  final List<dynamic> segments;

  @override
  State<_SpeakerMergeSheet> createState() => _SpeakerMergeSheetState();
}

class _SpeakerMergeSheetState extends State<_SpeakerMergeSheet> {
  /// Each group is a list of original diarization labels grouped together.
  late List<List<String>> _groups;
  final Map<String, String> _sample = {}; // original label -> sample line
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final byEffective = <String, List<String>>{};
    final seen = <String>{};
    for (final raw in widget.segments) {
      if (raw is! Map) continue;
      final orig = (raw['speaker_original'] ?? raw['speaker'])?.toString() ?? '';
      final eff = raw['speaker']?.toString() ?? '';
      if (orig.isEmpty) continue;
      _sample.putIfAbsent(orig, () => raw['text']?.toString() ?? '');
      if (!seen.contains(orig)) {
        seen.add(orig);
        byEffective.putIfAbsent(eff, () => <String>[]).add(orig);
      }
    }
    _groups = byEffective.values.map((e) => e.toList()).toList();
  }

  void _merge(int from, int to) {
    if (from == to || from < 0 || to < 0) return;
    setState(() {
      _groups[to].addAll(_groups[from]);
      _groups.removeAt(from);
    });
  }

  void _splitGroup(int idx) {
    setState(() {
      final members = _groups.removeAt(idx);
      for (final m in members) {
        _groups.add([m]);
      }
    });
  }

  Future<void> _apply() async {
    setState(() => _submitting = true);
    final map = <String, String>{};
    for (final g in _groups) {
      final rep = ([...g]..sort()).first; // stable group label
      for (final m in g) {
        map[m] = rep;
      }
    }
    try {
      await apiClient.remapSpeakers(widget.entryId, groupMap: map);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('??: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('?? ??? / ??', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '?? ???? ??? ?? ?? ?? ?? ?? ??? ????. '
            '?? ???? ?? ????? ?? ?? ? ???.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.mutedText,
                ),
          ),
                    const SizedBox(height: 14),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < _groups.length; i++) _groupCard(context, i),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
                  child: const Text('??'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _apply,
                  child: _submitting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('??'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _groupCard(BuildContext context, int idx) {
    final theme = Theme.of(context);
    final members = _groups[idx];
    final merged = members.length > 1;

    final card = Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: merged
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.drag_indicator_rounded, size: 18, color: theme.colorScheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final m in members)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: theme.colorScheme.outlineVariant),
                          ),
                          child: Text(m, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    members.map((m) => _sample[m] ?? '').where((t) => t.isNotEmpty).join(' ? '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (merged)
              IconButton(
                tooltip: '??',
                icon: const Icon(Icons.call_split_rounded, size: 18),
                onPressed: _submitting ? null : () => _splitGroup(idx),
              ),
          ],
        ),
      ),
    );

    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != idx,
      onAcceptWithDetails: (d) => _merge(d.data, idx),
      builder: (context, candidate, rejected) {
        final highlighted = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: highlighted ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: LongPressDraggable<int>(
            data: idx,
            feedback: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: MediaQuery.sizeOf(context).width * 0.7,
                child: Opacity(opacity: 0.9, child: card),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: card),
            child: card,
          ),
        );
      },
    );
  }
}
