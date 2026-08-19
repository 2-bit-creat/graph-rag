import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

bool _looksLikeFailureKey(String key) {
  final k = key.toLowerCase();
  return k.contains('failure') || k.contains('error') || k.contains('rejection');
}

/// Walks every step's output + artifact content for keys that read like a
/// rejection reason (validation_failures, review_errors, ...rejections) plus
/// any step-level error, so "why did this fail" is answered in one glance
/// instead of hunting through nested JSON per step.
List<String> _collectFailureReasons(Map<String, dynamic> trace) {
  final reasons = <String>[];
  for (final raw in (trace['steps'] as List<dynamic>? ?? [])) {
    final step = raw as Map;
    final stepName = step['name']?.toString() ?? '단계';
    final err = step['error']?.toString();
    if (err != null && err.isNotEmpty) reasons.add('[$stepName] $err');

    void scan(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString();
          final value = entry.value;
          if (_looksLikeFailureKey(key)) {
            if (value is List) {
              for (final item in value) {
                final text = item?.toString() ?? '';
                if (text.isNotEmpty) reasons.add('[$stepName] $text');
              }
            } else if (value is String && value.isNotEmpty) {
              reasons.add('[$stepName] $value');
            }
          } else {
            scan(value);
          }
        }
      } else if (node is List) {
        for (final item in node) {
          scan(item);
        }
      }
    }

    scan(step['output']);
    scan(step['artifacts_content']);
  }
  // De-dupe while keeping order — a retry commonly repeats the same reason.
  final seen = <String>{};
  return [for (final r in reasons) if (seen.add(r)) r];
}

/// Step-by-step accordion view of a persisted [PipelineTracer] trace
/// (`app/pipeline_trace.py`): one card per step, each expandable to its
/// system prompt, input, output and — when the backend inlined them — the
/// full artifact files (proposed segments, validation failures, reviewed
/// output) that explain *why* a step rejected something. Shared by the KG
/// and quiz generation history tabs in DebugHubScreen.
class PipelineStepList extends StatelessWidget {
  const PipelineStepList({super.key, required this.trace, this.header});

  final Map<String, dynamic> trace;

  /// Extra content shown above the step list (e.g. a selected-item summary).
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final steps = (trace['steps'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((step) => Map<String, dynamic>.from(step))
        .toList();
    final completed = trace['status'] == 'completed';
    final failureReasons = _collectFailureReasons(trace);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (header != null) ...[header!, const SizedBox(height: AppSpacing.lg)],
        PipelineMetaChip(
          icon: completed ? Icons.check_circle_outline : Icons.pending_outlined,
          label: completed ? '완료' : trace['status']?.toString() ?? '진행 중',
          color: completed ? AppColors.accent : AppColors.textMuted,
        ),
        if (failureReasons.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _FailureSummaryCard(reasons: failureReasons),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text('실행 단계 (${steps.length})',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        if (steps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Text('단계 기록이 없습니다',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ),
        for (final step in steps)
          _StepCard(
            step: step,
            // The step that actually produced a rejection reason opens by
            // default — that's the one worth reading first.
            initiallyExpanded: _stepHasFailureSignal(step),
          ),
      ],
    );
  }

  bool _stepHasFailureSignal(Map<String, dynamic> step) {
    if ((step['error']?.toString() ?? '').isNotEmpty) return true;
    if (step['status'] == 'error') return true;
    return _collectFailureReasons({
      'steps': [step]
    }).isNotEmpty;
  }
}

class _FailureSummaryCard extends StatelessWidget {
  const _FailureSummaryCard({required this.reasons});
  final List<String> reasons;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.redAccent),
              const SizedBox(width: 6),
              Text('왜 실패했는가',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Colors.redAccent, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final reason in reasons)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SelectableText('• $reason',
                  style: const TextStyle(fontSize: 12.5, height: 1.4)),
            ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.step, this.initiallyExpanded = false});
  final Map<String, dynamic> step;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final systemPrompt = step['system_prompt']?.toString() ?? '';
    final error = step['error']?.toString() ?? '';
    final artifacts = step['artifacts_content'];
    return Card(
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: Icon(
          step['status'] == 'completed'
              ? Icons.check_circle_outline
              : step['status'] == 'error'
                  ? Icons.error_outline
                  : Icons.pending_outlined,
          color: step['status'] == 'error' ? Colors.redAccent : null,
        ),
        title: Text(step['name']?.toString() ?? '단계'),
        subtitle: Text(
          [
            if ((step['phase']?.toString() ?? '').isNotEmpty) step['phase'],
            if (step['model'] != null) step['model'],
            '${step['latency_ms'] ?? '?'}ms',
          ].join(' · '),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SelectableText('오류: $error',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          // Artifacts hold the actual attempted content (proposed segments,
          // validation failures, the reviewed plan) — the most useful part
          // for "why", so they come before the terser input/output summary.
          if (artifacts is Map && artifacts.isNotEmpty)
            for (final entry in artifacts.entries) ...[
              Text(entry.key, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              JsonTree(data: entry.value),
              const SizedBox(height: AppSpacing.sm),
            ],
          if (step['input'] is Map && (step['input'] as Map).isNotEmpty) ...[
            Text('Input', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            JsonTree(data: step['input']),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (step['output'] is Map && (step['output'] as Map).isNotEmpty) ...[
            Text('Output', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            JsonTree(data: step['output']),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (systemPrompt.isNotEmpty) _CodeSection(title: 'System Prompt', text: systemPrompt),
        ],
      ),
    );
  }
}

/// Collapsed by default — a raw system prompt runs long and isn't what most
/// taps are looking for; input/output above are shown open instead.
class _CodeSection extends StatelessWidget {
  const _CodeSection({required this.title, required this.text});
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: false,
        title: Text(title, style: Theme.of(context).textTheme.labelLarge),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Readable renderer for a step's `input`/`output`/artifact JSON. Generic
/// deep-indent for arbitrary shapes, but a list of strings or a list of
/// "text-ish" objects (the common shape for proposed segments, reviewed
/// segments, rejection reasons) gets a flat, scannable card layout instead
/// of nested bullet trees — and any key that reads like a failure reason is
/// tinted red so it doesn't blend into ordinary fields.
class JsonTree extends StatelessWidget {
  const JsonTree({super.key, required this.data, this.indent = 0, this.failureContext = false});
  final dynamic data;
  final int indent;
  final bool failureContext;

  static const _headlineKeys = ['source_text', 'text', 'prompt_native', 'name', 'title'];

  @override
  Widget build(BuildContext context) {
    if (data is Map<String, dynamic>) {
      final map = data as Map<String, dynamic>;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: map.entries.map((e) {
          final isFailureKey = _looksLikeFailureKey(e.key);
          return Padding(
            padding: EdgeInsets.only(left: indent * 12.0, bottom: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '▸ ${e.key}:',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isFailureKey ? Colors.redAccent : AppColors.primary,
                  ),
                ),
                JsonTree(data: e.value, indent: indent + 1, failureContext: isFailureKey),
              ],
            ),
          );
        }).toList(),
      );
    } else if (data is List) {
      final list = data as List;
      if (list.isEmpty) {
        return Padding(
          padding: EdgeInsets.only(left: indent * 12.0),
          child: Text('(없음)',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
        );
      }
      final allStrings = list.every((e) => e is String);
      if (allStrings) {
        return Padding(
          padding: EdgeInsets.only(left: indent * 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: list
                .map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: SelectableText(
                        '• $e',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: failureContext ? Colors.redAccent : null,
                        ),
                      ),
                    ))
                .toList(),
          ),
        );
      }
      final allMaps = list.every((e) => e is Map);
      if (allMaps) {
        return Padding(
          padding: EdgeInsets.only(left: indent * 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: list.asMap().entries.map((e) {
              return _ItemCard(index: e.key, item: Map<String, dynamic>.from(e.value as Map));
            }).toList(),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: list.asMap().entries.map((e) {
          return Padding(
            padding: EdgeInsets.only(left: indent * 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('[${e.key}] ',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                Expanded(child: JsonTree(data: e.value, indent: 0)),
              ],
            ),
          );
        }).toList(),
      );
    } else {
      return Padding(
        padding: EdgeInsets.only(left: indent * 12.0, bottom: 2),
        child: SelectableText(
          data?.toString() ?? 'null',
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: failureContext ? Colors.redAccent : null,
          ),
        ),
      );
    }
  }
}

/// One entry of a list-of-objects (a proposed/reviewed segment, an
/// expression candidate, ...): the first text-ish field found is shown as
/// the headline, everything else follows as a compact key/value block.
class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.index, required this.item});
  final int index;
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    String? headlineKey;
    for (final key in JsonTree._headlineKeys) {
      if (item[key] is String && (item[key] as String).isNotEmpty) {
        headlineKey = key;
        break;
      }
    }
    final rest = Map<String, dynamic>.from(item)..remove(headlineKey);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('#$index ',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              if (headlineKey != null)
                Expanded(
                  child: SelectableText(
                    item[headlineKey] as String,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: 4),
            JsonTree(data: rest, indent: 0),
          ],
        ],
      ),
    );
  }
}

class PipelineMetaChip extends StatelessWidget {
  const PipelineMetaChip(
      {super.key, required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: color, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
