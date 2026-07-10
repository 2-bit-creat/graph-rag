import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';

/// LangChain-style node → edge → node flow graph with tap-to-inspect.
class PipelineFlowGraph extends StatelessWidget {
  const PipelineFlowGraph({
    super.key,
    required this.title,
    required this.steps,
    this.subtitle,
    this.entryId,
    this.fetchArtifact,
  });

  final String title;
  final String? subtitle;
  final List<Map<String, dynamic>> steps;
  final String? entryId;
  final Future<String> Function(String relativePath)? fetchArtifact;

  static String stepDisplayName(String raw, {Map<String, dynamic>? output}) {
    if (raw == 'whisper_stt' && output != null) {
      final source = output['source']?.toString();
      if (source == 'diarization') return 'Deepgram\nSTT';
      if (source == 'whisper_fallback') return 'Whisper\n(폴백)';
    }
    const labels = {
      'semantic_chunk_ingest': 'Semantic\nChunk',
      'incremental_graph_pipeline': 'Semantic\nChunk',
      'graph_provenance': '출처\n기록',
      'speaker_person_link': '화자\n연결',
      'embedding_chunks': '청크\n임베딩',
      'apply_ontology': 'Open\nDomain',
      'slow_path_start': 'GraphRAG\n시작',
      'graph_review_apply': '검토\n·반영',
      'precision_text_ingest': '라벨링\n입력',
      'llm_triple_extraction': '트리플\n추출',
      'graph_upsert': '그래프\nupsert',
      'audio_trim': '무음\n제거',
      'speaker_diarize': '화자\n분리',
      'speaker_voice_memory': '음성\n메모리',
      'whisper_stt': 'Whisper\nSTT',
      'gpt_cleanup': 'GPT\n정제',
      'fast_path_complete': 'Fast\n완료',
      'quiz_audio_tts': 'Edge-TTS\n음성',
    };
    return labels[raw] ?? raw.replaceAll('_', '\n');
  }

  static String prettyJson(dynamic value) {
    if (value == null) return '(없음)';
    try {
      if (value is String) return value;
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  static bool _hasPayload(dynamic value) {
    if (value == null) return false;
    if (value is Map) return value.isNotEmpty;
    if (value is List) return value.isNotEmpty;
    if (value is String) return value.trim().isNotEmpty;
    return true;
  }

  static void showEdgeOutputModal(
    BuildContext context, {
    required Map<String, dynamic> fromStep,
    required Map<String, dynamic> toStep,
    String? entryId,
    Future<String> Function(String relativePath)? fetchArtifact,
  }) {
    final fromName = fromStep['name']?.toString() ?? '?';
    final toName = toStep['name']?.toString() ?? '?';
    final output = fromStep['output'];
    final latency = fromStep['latency_ms'];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$fromName → $toName'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Edge payload (output of $fromName)',
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
                if (latency != null) ...[
                  const SizedBox(height: 4),
                  Text('${latency}ms', style: const TextStyle(fontSize: 11)),
                ],
                const SizedBox(height: 8),
                SelectableText(
                  prettyJson(output),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              showNodeDetailModal(
                context,
                step: fromStep,
                entryId: entryId,
                fetchArtifact: fetchArtifact,
              );
            },
            child: const Text('노드 전체 보기'),
          ),
        ],
      ),
    );
  }

  static void showNodeDetailModal(
    BuildContext context, {
    required Map<String, dynamic> step,
    String? entryId,
    Future<String> Function(String relativePath)? fetchArtifact,
  }) {
    final title = step['label']?.toString() ??
        stepDisplayName(
          step['name']?.toString() ?? 'step',
          output: step['output'] is Map
              ? Map<String, dynamic>.from(step['output'] as Map)
              : null,
        );
    final type = step['type']?.toString() ?? '';
    final status = step['status']?.toString();
    final hasInput = _hasPayload(step['input']);
    final hasOutput = _hasPayload(step['output']);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'type: $type · ${step['latency_ms'] ?? '?'}ms'
                  '${status != null ? ' · $status' : ''}',
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
                if (step['io_hint'] != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    step['io_hint'].toString(),
                    style: TextStyle(fontSize: 11, color: context.subtleText),
                  ),
                ],
                if (step['system_prompt'] != null) ...[
                  const SizedBox(height: 12),
                  const Text('System Prompt',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  SelectableText(
                    step['system_prompt'].toString(),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ],
                if (hasInput) ...[
                  const SizedBox(height: 12),
                  const Text('Input',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  SelectableText(
                    prettyJson(step['input']),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ],
                if (hasOutput) ...[
                  const SizedBox(height: 12),
                  const Text('Output',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  SelectableText(
                    prettyJson(step['output']),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ],
                if (!hasInput && !hasOutput && status == 'skipped') ...[
                  const SizedBox(height: 12),
                  Text(
                    '이 분기는 실행되지 않았습니다 (skip).',
                    style: TextStyle(fontSize: 12, color: context.subtleText),
                  ),
                ],
                if (!hasInput && !hasOutput && status == 'pending') ...[
                  const SizedBox(height: 12),
                  Text(
                    '아직 실행되지 않음 — 아래 퀴즈 생성 버튼을 누르세요.',
                    style: TextStyle(fontSize: 12, color: Colors.indigo[700]),
                  ),
                ],
                if (step['error'] != null) ...[
                  const SizedBox(height: 12),
                  Text('Error: ${step['error']}',
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ],
                if (step['artifacts'] != null && fetchArtifact != null) ...[
                  const SizedBox(height: 12),
                  const Text('Artifacts',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  ...((step['artifacts'] as List<dynamic>).map((a) {
                    final art = a as Map<String, dynamic>;
                    final rel = art['relative_path']?.toString() ?? '';
                    final media = art['media_type']?.toString() ?? '';
                    final isAudio = media.startsWith('audio');
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(art['name']?.toString() ?? rel,
                          style: const TextStyle(fontSize: 12)),
                      subtitle: Text(rel, style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
                      trailing: isAudio && entryId != null
                          ? IconButton(
                              icon: const Icon(Icons.link, size: 18),
                              onPressed: () {
                                final url = apiClient.artifactUrl(entryId, rel);
                                showDialog(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    title: const Text('Audio URL'),
                                    content: SelectableText(url),
                                    actions: [
                                      TextButton(
                                          onPressed: () => Navigator.pop(dctx),
                                          child: const Text('닫기')),
                                    ],
                                  ),
                                );
                              },
                            )
                          : TextButton(
                              child: const Text('보기'),
                              onPressed: () async {
                                try {
                                  final text = await fetchArtifact(rel);
                                  if (!ctx.mounted) return;
                                  showDialog(
                                    context: ctx,
                                    builder: (dctx) => AlertDialog(
                                      title: Text(art['name']?.toString() ?? 'Artifact'),
                                      content: SingleChildScrollView(
                                        child: SelectableText(
                                          text,
                                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                            onPressed: () => Navigator.pop(dctx),
                                            child: const Text('닫기')),
                                      ],
                                    ),
                                  );
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  final msg = e.toString().contains('404')
                                      ? '산출물이 아직 없습니다 — 단계가 실행되면 생성됩니다.'
                                      : '산출물을 불러오지 못했습니다: $e';
                                  showDialog(
                                    context: ctx,
                                    builder: (dctx) => AlertDialog(
                                      title: const Text('Artifact'),
                                      content: Text(msg, style: const TextStyle(fontSize: 12)),
                                      actions: [
                                        TextButton(
                                            onPressed: () => Navigator.pop(dctx),
                                            child: const Text('닫기')),
                                      ],
                                    ),
                                  );
                                }
                              },
                            ),
                    );
                  })),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
        ],
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'llm':
        return Colors.purple;
      case 'api':
        return Colors.blue;
      case 'graph':
        return Colors.green;
      case 'embed':
        return Colors.orange;
      case 'storage':
        return Colors.brown;
      case 'transform':
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(subtitle!, style: TextStyle(fontSize: 11, color: context.mutedText)),
              ),
            const SizedBox(height: 4),
            Text(
              '노드 탭 = 상세 · 화살표(엣지) 탭 = output payload',
              style: TextStyle(fontSize: 10, color: context.mutedText),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: _buildChain(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildChain(BuildContext context) {
    final widgets = <Widget>[];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      widgets.add(_FlowNode(
        step: step,
        color: _typeColor(step['type']?.toString() ?? ''),
        onTap: () => showNodeDetailModal(
          context,
          step: step,
          entryId: entryId,
          fetchArtifact: fetchArtifact,
        ),
      ));
      if (i < steps.length - 1) {
        widgets.add(_FlowEdge(
          fromStep: step,
          toStep: steps[i + 1],
          onTap: () => showEdgeOutputModal(
            context,
            fromStep: step,
            toStep: steps[i + 1],
            entryId: entryId,
            fetchArtifact: fetchArtifact,
          ),
        ));
      }
    }
    return widgets;
  }
}

class _FlowNode extends StatelessWidget {
  const _FlowNode({
    required this.step,
    required this.color,
    required this.onTap,
  });

  final Map<String, dynamic> step;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = PipelineFlowGraph.stepDisplayName(
      step['name']?.toString() ?? '',
      output: step['output'] is Map ? Map<String, dynamic>.from(step['output'] as Map) : null,
    );
    final status = step['status']?.toString() ?? '';
    final isError = status == 'error';
    final ms = step['latency_ms'];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 108,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isError ? Colors.red : color.withValues(alpha: 0.6),
              width: 2,
            ),
            color: color.withValues(alpha: 0.08),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _iconForType(step['type']?.toString() ?? ''),
                size: 22,
                color: isError ? Colors.red : color,
              ),
              const SizedBox(height: 6),
              Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
              ),
              if (ms != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${ms}ms', style: TextStyle(fontSize: 9, color: context.mutedText)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'llm':
        return Icons.psychology_outlined;
      case 'api':
        return Icons.cloud_outlined;
      case 'graph':
        return Icons.hub_outlined;
      case 'embed':
        return Icons.layers_outlined;
      case 'storage':
        return Icons.folder_outlined;
      case 'transform':
        return Icons.content_cut;
      default:
        return Icons.settings_outlined;
    }
  }
}

class _FlowEdge extends StatelessWidget {
  const _FlowEdge({
    required this.fromStep,
    required this.toStep,
    required this.onTap,
  });

  final Map<String, dynamic> fromStep;
  final Map<String, dynamic> toStep;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasOutput = fromStep['output'] != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Tooltip(
          message: '엣지 output 보기',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 3,
                      decoration: BoxDecoration(
                        color: hasOutput
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward,
                      size: 16,
                      color: hasOutput
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.shade400,
                    ),
                    Container(
                      width: 28,
                      height: 3,
                      decoration: BoxDecoration(
                        color: hasOutput
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'output',
                  style: TextStyle(
                    fontSize: 8,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Labels of speakers that still need human confirmation before GraphRAG.
List<String> pendingSpeakerLabels(List<dynamic> speakerSummaries) {
  final pending = <String>[];
  for (final raw in speakerSummaries) {
    if (raw is! Map) continue;
    if (raw['needs_confirmation'] == false) continue;
    final label = raw['session_label']?.toString();
    // '나' is always the diary author — no confirmation needed
    if (label == null || label.isEmpty || label == '나') continue;
    pending.add(label);
  }
  return pending;
}

/// Slow Path action area between Fast and Slow chains.
class SlowPathActionCard extends StatelessWidget {
  const SlowPathActionCard({
    super.key,
    required this.status,
    required this.onBuildGraph,
    this.building = false,
    this.onViewGraph,
    this.onForceRebuild,
    this.onRefreshStatus,
    this.pendingSpeakerLabels = const [],
  });

  final String status;
  final VoidCallback onBuildGraph;
  final bool building;
  final VoidCallback? onViewGraph;
  final VoidCallback? onForceRebuild;
  final VoidCallback? onRefreshStatus;
  final List<String> pendingSpeakerLabels;

  bool get _canBuild => status == 'graph_failed';
  bool get _processing => status == 'graph_processing';
  bool get _autoQueued => status == 'ready' || status == 'ready_no_graph';
  bool get _ready => status == 'graph_ready';
  bool get _failed => status == 'graph_failed';
  bool get _speakersBlocking => pendingSpeakerLabels.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _ready
                      ? Icons.check_circle
                      : _processing
                          ? Icons.hourglass_top
                          : _failed
                              ? Icons.error_outline
                              : Icons.hub_outlined,
                  color: _ready
                      ? Colors.green
                      : _failed
                          ? Colors.red.shade700
                          : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Slow Path — Semantic Chunk ingest',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        _ready
                            ? '완료 · Chunk · Speaker · Vocab · Concept'
                            : _processing
                                ? '백그라운드 실행 중…'
                                : _failed
                                    ? '생성 실패 — 아래 버튼으로 재시도하세요'
                                    : _autoQueued
                                        ? '자동 처리 대기 중'
                                        : 'Slow Path 대기',
                        style: TextStyle(
                          fontSize: 12,
                          color: _failed ? Colors.red.shade700 : context.subtleText,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_speakersBlocking) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.record_voice_over, color: Colors.orange[800], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'GraphRAG 실행 전에 번역 탭에서 화자를 확인해 주세요.\n'
                        '미확인: ${pendingSpeakerLabels.join(', ')}',
                        style: TextStyle(fontSize: 12, color: Colors.orange[900]),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (_canBuild && !_speakersBlocking) ...[
              FilledButton.icon(
                onPressed: building ? null : onBuildGraph,
                icon: building
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.replay),
                label: Text(building ? '재시도 중…' : '지식 그래프 재시도'),
              ),
            ] else if (_processing) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
              Text(
                '백그라운드 실행 중… 완료되면 자동으로 갱신됩니다.',
                style: TextStyle(fontSize: 11, color: context.subtleText),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (onRefreshStatus != null)
                    TextButton.icon(
                      onPressed: onRefreshStatus,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('상태 새로고침'),
                    ),
                  if (onForceRebuild != null) ...[
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: building ? null : onForceRebuild,
                      icon: const Icon(Icons.replay, size: 18),
                      label: const Text('강제 재시작'),
                    ),
                  ],
                ],
              ),
            ]
            else if (_ready && onViewGraph != null)
              OutlinedButton.icon(
                onPressed: onViewGraph,
                icon: const Icon(Icons.hub),
                label: const Text('지식 그래프 탭에서 보기'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Progress stepper for the full journal pipeline.
class PipelineProgressStepper extends StatelessWidget {
  const PipelineProgressStepper({
    super.key,
    required this.status,
    this.hasTranslation = false,
    this.compact = false,
  });

  final String status;
  final bool hasTranslation;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fastDone = hasTranslation ||
        status == 'ready' ||
        status == 'ready_no_graph' ||
        status == 'graph_processing' ||
        status == 'graph_ready' ||
        status == 'graph_failed';
    final graphDone = status == 'graph_ready';
    final graphRunning = status == 'graph_processing';
    final graphFailed = status == 'graph_failed';

    final dotSize = compact ? 22.0 : 28.0;
    final vPad = compact ? 8.0 : 16.0;
    final hPad = compact ? 10.0 : 12.0;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(compact ? 10 : 12),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        child: Row(
          children: [
            _StepDot(
              label: '녹음',
              done: true,
              active: false,
              size: dotSize,
              compact: compact,
            ),
            _StepLine(done: fastDone),
            _StepDot(
              label: compact ? 'Fast' : 'Fast\nPath',
              done: fastDone,
              active: !fastDone,
              size: dotSize,
              compact: compact,
            ),
            _StepLine(done: graphDone || graphRunning),
            _StepDot(
              label: compact ? 'Graph' : 'Graph\nRAG',
              done: graphDone,
              failed: graphFailed,
              active: !graphFailed && graphRunning,
              size: dotSize,
              compact: compact,
            ),
          ],
        ),
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.label,
    required this.done,
    required this.active,
    this.failed = false,
    this.size = 28,
    this.compact = false,
  });

  final String label;
  final bool done;
  final bool active;
  final bool failed;
  final double size;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = done
        ? Colors.green
        : failed
            ? Colors.red.shade600
            : active
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade400;
    return Expanded(
      child: Column(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done || active || failed
                  ? color.withValues(alpha: 0.15)
                  : Colors.grey.shade100,
              border: Border.all(color: color, width: compact ? 1.5 : 2),
            ),
            child: done
                ? Icon(Icons.check, size: compact ? 13 : 16, color: color)
                : failed
                    ? Icon(Icons.close, size: compact ? 13 : 16, color: color)
                    : active
                        ? Padding(
                            padding: const EdgeInsets.all(4),
                            child: CircularProgressIndicator(strokeWidth: 2, color: color),
                          )
                        : null,
          ),
          SizedBox(height: compact ? 2 : 4),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(fontSize: compact ? 8 : 9, height: 1.05),
          ),
        ],
      ),
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 2,
        color: done ? Colors.green : Colors.grey.shade300,
      ),
    );
  }
}

/// Vertical connector between Fast and Slow path chains.
class PipelinePhaseConnector extends StatelessWidget {
  const PipelinePhaseConnector({super.key, this.label = '수동 GraphRAG'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: Colors.grey.shade400)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label, style: TextStyle(fontSize: 11, color: context.mutedText)),
          ),
          Expanded(child: Divider(color: Colors.grey.shade400)),
        ],
      ),
    );
  }
}
