import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pipeline_flow_graph.dart';
import '../theme/app_theme.dart';

/// 2D DAG view driven by backend `flow_layout`.
/// Fits to screen width; full Fast + Slow Path height visible via page scroll.
class PipelineTraceCanvas extends StatefulWidget {
  const PipelineTraceCanvas({
    super.key,
    required this.trace,
    this.entryId,
    this.fetchArtifact,
    this.journalMode = false,
    this.textPipelineMode = false,
    this.quizMode = false,
  });

  final Map<String, dynamic> trace;
  final String? entryId;
  final Future<String> Function(String relativePath)? fetchArtifact;
  /// 음성 허브: Quiz Path 안내 숨김, 힌트 축약.
  final bool journalMode;
  /// precision_text 일기: Text Fast Path 레이아웃.
  final bool textPipelineMode;
  /// 문제 생성 허브: 단일 행 Quiz Path — 뷰포트·여백 최적화.
  final bool quizMode;

  static const nodeW = 108.0;
  static const nodeH = 68.0;
  static const colGap = 36.0;
  static const rowGap = 16.0;
  static const pad = 16.0;

  @override
  State<PipelineTraceCanvas> createState() => PipelineTraceCanvasState();
}

class PipelineTraceCanvasState extends State<PipelineTraceCanvas> {
  final _transform = TransformationController();
  bool _panEnabled = false;
  double _viewportH = 360;
  double? _lastLayoutWidth;
  String? _lastFitKey;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _applyFit(
    double viewportW,
    double canvasW,
    double canvasH, {
    bool quizOnly = false,
  }) {
    final scale = ((viewportW - 8) / canvasW).clamp(0.38, 1.0);
    final scaledH = canvasH * scale;
    final outerPad = quizOnly ? 40.0 : 32.0;
    final h = quizOnly
        ? math.max(168.0, scaledH + outerPad)
        : math.max(220.0, scaledH + outerPad);
    // Center content vertically when viewport is taller than scaled DAG.
    final ty = math.max(0.0, (h / scale - canvasH) / 2);
    _transform.value = Matrix4.identity()
      ..scale(scale)
      ..translate(0.0, ty);
    if ((_viewportH - h).abs() > 1 && mounted) {
      setState(() => _viewportH = h);
    }
  }

  bool _isQuizOnlyLayout(List<Map<String, dynamic>> nodes) {
    if (widget.quizMode) return true;
    if (nodes.isEmpty) return false;
    if (!nodes.every((n) => n['phase']?.toString() == 'quiz_path')) return false;
    final maxRow = nodes
        .map((n) => (n['row'] as num?)?.toDouble() ?? 0)
        .fold<double>(0, math.max);
    return maxRow <= 0.5;
  }

  /// Pan the viewport toward the Quiz Path band (lower rows in the DAG).
  void focusQuizPath() {
    final layout = widget.trace['flow_layout'] as Map<String, dynamic>?;
    if (layout == null) return;
    final nodes = layout['nodes'] as List<dynamic>? ?? [];
    final quizNodes = nodes.where((n) => (n as Map)['phase'] == 'quiz_path');
    if (quizNodes.isEmpty) return;

    double maxRow = 0;
    for (final n in quizNodes) {
      final row = (n as Map)['row'] as num? ?? 0;
      if (row > maxRow) maxRow = row.toDouble();
    }
    final scale = _transform.value.getMaxScaleOnAxis();
    final y = PipelineTraceCanvas.pad / 2 +
        maxRow * (PipelineTraceCanvas.nodeH + PipelineTraceCanvas.rowGap);
    final ty = -y * scale + 80;
    _transform.value = Matrix4.identity()
      ..scale(scale)
      ..translate(0.0, ty.clamp(-2000.0, 0.0));
  }

  /// Quiz hub: static Transform avoids InteractiveViewer stealing mouse-wheel scroll.
  Widget _buildCanvasViewport({required Widget child, required double canvasW, required double canvasH}) {
    if (widget.quizMode && !_panEnabled) {
      return Transform(
        transform: _transform.value,
        alignment: Alignment.topLeft,
        child: child,
      );
    }
    return InteractiveViewer(
      transformationController: _transform,
      panEnabled: _panEnabled,
      scaleEnabled: _panEnabled,
      trackpadScrollCausesScale: false,
      minScale: 0.35,
      maxScale: 2.2,
      boundaryMargin: const EdgeInsets.all(48),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = widget.trace['flow_layout'] as Map<String, dynamic>?;
    if (layout == null) {
      return _LegacyLinearFallback(
        trace: widget.trace,
        entryId: widget.entryId,
        fetchArtifact: widget.fetchArtifact,
      );
    }

    final nodes = (layout['nodes'] as List<dynamic>? ?? [])
        .map((n) => Map<String, dynamic>.from(n as Map))
        .toList();
    final edges = (layout['edges'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final slowStarted = (widget.trace['steps'] as List<dynamic>? ?? []).any(
      (s) {
        final name = (s as Map)['name']?.toString() ?? '';
        return name == 'slow_path_start' || name == 'manual_graph_trigger';
      },
    );
    for (final edge in edges) {
      if (edge['source'] == 'fast_path_complete' &&
          (edge['target'] == 'slow_path_start' ||
              edge['target'] == 'manual_graph_trigger') &&
          !slowStarted) {
        edge['active'] = false;
      }
    }
    final phases = (layout['phases'] as List<dynamic>? ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();

    if (nodes.isEmpty) return const SizedBox.shrink();

    final rawPositions = {for (final n in nodes) n['id'].toString(): _pos(n)};
    final content = _contentBounds(rawPositions);
    const margin = 20.0;
    final canvasW = content.width + margin * 2;
    final canvasH = content.height + margin * 2;
    final positions = {
      for (final e in rawPositions.entries)
        e.key: Offset(
          e.value.dx - content.left + margin,
          e.value.dy - content.top + margin,
        ),
    };
    final phaseRows = phases.map((p) {
      final row = (p['row_offset'] as num?)?.toDouble() ?? 0;
      final bandY = PipelineTraceCanvas.pad / 2 +
          row * (PipelineTraceCanvas.nodeH + PipelineTraceCanvas.rowGap);
      return bandY - content.top + margin;
    }).toList();
    final hasGraphPath = nodes.any((n) => n['phase']?.toString() == 'graph_path');
    final hasQuizPath = nodes.any((n) => n['phase']?.toString() == 'quiz_path');
    final isTextLayout = widget.textPipelineMode ||
        widget.trace['entry_source']?.toString() == 'precision_text' ||
        layout['entry_source']?.toString() == 'precision_text';
    final quizOnly = _isQuizOnlyLayout(nodes);
    final graphPending = nodes.any(
      (n) =>
          n['phase']?.toString() == 'graph_path' &&
          n['status']?.toString() == 'pending',
    );
    final quizPending = nodes.any(
      (n) =>
          n['phase']?.toString() == 'quiz_path' &&
          n['status']?.toString() == 'pending',
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Pipeline Flow',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                const _LegendChip(color: Colors.green, label: '완료'),
                const SizedBox(width: 4),
                const _LegendChip(color: Colors.grey, label: 'skip'),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: _panEnabled ? '스크롤 모드' : '이동 모드',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                      _panEnabled
                          ? Icons.back_hand
                          : Icons.pan_tool_alt_outlined,
                      size: 18),
                  onPressed: () => setState(() => _panEnabled = !_panEnabled),
                ),
                IconButton(
                  tooltip: '화면에 맞추기',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.fit_screen, size: 18),
                  onPressed: () => _applyFit(
                    context.size?.width ?? 360,
                    canvasW,
                    canvasH,
                    quizOnly: quizOnly,
                  ),
                ),
              ],
            ),
            if (!widget.journalMode && !quizOnly)
              Text(
                _panEnabled
                    ? '드래그=이동 · 핀치=확대 · 노드 탭=입출력 상세'
                    : '입력(텍스트/음성) → 정제 합류 → Graph Path · Quiz Path는 하단',
                style: TextStyle(fontSize: 10, color: context.mutedText),
              ),
            if (widget.journalMode || quizOnly)
              Text(
                _panEnabled ? '드래그=이동 · 노드 탭=입출력' : '노드 탭 → 단계별 input/output 확인',
                style: TextStyle(fontSize: 10, color: context.mutedText),
              ),
            if (isTextLayout && widget.journalMode) ...[
              const SizedBox(height: 4),
              Text(
                '입력·정제 — 라벨링 또는 음성 → GPT 정제·번역 후 Graph Path로 합류',
                style: TextStyle(fontSize: 10, color: Colors.indigo[700]),
              ),
            ],
            if (hasGraphPath && widget.journalMode) ...[
              const SizedBox(height: 4),
              Text(
                'Graph Path — GraphRAG(자동) 또는 수동 추가 중 하나만 실행 · 공통: 화자→추출→검토→DB',
                style: TextStyle(fontSize: 10, color: Colors.teal[700]),
              ),
            ],
            if (hasGraphPath && graphPending) ...[
              const SizedBox(height: 4),
              Text(
                'Graph Path는 정제 완료 후 GraphRAG 또는 수동 추가 버튼으로 시작됩니다.',
                style: TextStyle(fontSize: 10, color: Colors.indigo[700]),
              ),
            ],
            if (hasQuizPath && !widget.journalMode) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '플로우 하단 Quiz Path 노드 — 생성 후 탭해서 input/output·artifacts 확인',
                      style: TextStyle(fontSize: 10, color: Colors.indigo[700]),
                    ),
                  ),
                  TextButton(
                    onPressed: focusQuizPath,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Quiz Path로 이동', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ],
            if (hasQuizPath && quizPending && !widget.journalMode) ...[
              const SizedBox(height: 4),
              Text(
                'Quiz Path 노드는 pending — 아래 퀴즈 생성 버튼으로 실행하세요.',
                style: TextStyle(fontSize: 10, color: Colors.indigo[700]),
              ),
            ],
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final fitKey =
                    '${w.toStringAsFixed(0)}:${canvasW.toStringAsFixed(0)}:${canvasH.toStringAsFixed(0)}';
                if (_lastFitKey != fitKey) {
                  _lastFitKey = fitKey;
                  _lastLayoutWidth = w;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      _applyFit(
                        w,
                        canvasW,
                        canvasH,
                        quizOnly: quizOnly,
                      );
                    }
                  });
                }
                return SizedBox(
                  height: _viewportH,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: Colors.grey.shade50,
                      child: _buildCanvasViewport(
                        canvasW: canvasW,
                        canvasH: canvasH,
                        child: SizedBox(
                          width: canvasW,
                          height: canvasH,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              CustomPaint(
                                size: Size(canvasW, canvasH),
                                painter: _FlowEdgePainter(
                                  edges: edges,
                                  positions: positions,
                                  nodeW: PipelineTraceCanvas.nodeW,
                                  nodeH: PipelineTraceCanvas.nodeH,
                                ),
                              ),
                              ...phases.asMap().entries.map(
                                (entry) => _PhaseBand(
                                  label: entry.value['label']?.toString() ?? '',
                                  top: phaseRows[entry.key],
                                  canvasW: canvasW,
                                ),
                              ),
                              ...nodes.map((n) {
                                final id = n['id'].toString();
                                final pos = positions[id]!;
                                return Positioned(
                                  left: pos.dx,
                                  top: pos.dy,
                                  width: PipelineTraceCanvas.nodeW,
                                  height: PipelineTraceCanvas.nodeH,
                                  child: _FlowNodeCard(
                                    node: n,
                                    onTap: () => _openNode(context, n),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openNode(BuildContext context, Map<String, dynamic> n) {
    final stepRaw = n['step'];
    if (stepRaw is! Map || stepRaw.isEmpty) {
      final raw = _findTraceStepForNode(n);
      if (raw != null) {
        PipelineFlowGraph.showNodeDetailModal(
          context,
          step: {
            ...Map<String, dynamic>.from(raw),
            'label': n['label']?.toString().replaceAll('\n', ' ') ??
                raw['label']?.toString(),
            'io_hint': n['io_hint'] ?? raw['io_hint'],
          },
          entryId: widget.entryId,
          fetchArtifact: widget.fetchArtifact,
        );
        return;
      }
      PipelineFlowGraph.showNodeDetailModal(
        context,
        step: {
          'name': n['id'],
          'label': n['label']?.toString().replaceAll('\n', ' '),
          'type': n['type'],
          'status': n['status'],
          'io_hint': n['io_hint'],
        },
        entryId: widget.entryId,
        fetchArtifact: widget.fetchArtifact,
      );
      return;
    }

    var step = Map<String, dynamic>.from(stepRaw);
    // Fallback artifacts from raw trace step when view has none.
    if ((step['artifacts'] as List?)?.isEmpty != false) {
      final full = _findTraceStepForNode(n);
      if (full != null && full['artifacts'] != null) {
        step['artifacts'] = full['artifacts'];
      }
    }
    if (step['label'] == null && n['label'] != null) {
      step['label'] = n['label'].toString().replaceAll('\n', ' ');
    }

    PipelineFlowGraph.showNodeDetailModal(
      context,
      step: step,
      entryId: widget.entryId,
      fetchArtifact: widget.fetchArtifact,
    );
  }

  static const _incrementalNodeIds = {
    'lightrag_extract',
    'lightrag_vector',
    'lightrag_merge',
    'lightrag_edges',
    'graph_review_apply',
  };

  Map<String, dynamic>? _findTraceStepById(String? stepId) {
    if (stepId == null) return null;
    for (final s in widget.trace['steps'] as List<dynamic>? ?? []) {
      if (s is Map && s['step_id']?.toString() == stepId) {
        return Map<String, dynamic>.from(s);
      }
    }
    return null;
  }

  Map<String, dynamic>? _findTraceStepForNode(Map<String, dynamic> n) {
    final byId = _findTraceStepById(n['step_id']?.toString());
    if (byId != null) return byId;

    final nodeId = n['id']?.toString() ?? '';
    Map<String, dynamic>? latestIncremental;
    for (final s in widget.trace['steps'] as List<dynamic>? ?? []) {
      if (s is! Map) continue;
      final name = s['name']?.toString() ?? '';
      if (name == nodeId) return Map<String, dynamic>.from(s);
      if (name == 'incremental_graph_pipeline') {
        latestIncremental = Map<String, dynamic>.from(s);
      }
    }
    if (_incrementalNodeIds.contains(nodeId)) return latestIncremental;
    return null;
  }

  Offset _pos(Map<String, dynamic> node) {
    final col = (node['col'] as num?)?.toDouble() ?? 0;
    final row = (node['row'] as num?)?.toDouble() ?? 0;
    return Offset(
      PipelineTraceCanvas.pad / 2 +
          col * (PipelineTraceCanvas.nodeW + PipelineTraceCanvas.colGap),
      PipelineTraceCanvas.pad / 2 +
          row * (PipelineTraceCanvas.nodeH + PipelineTraceCanvas.rowGap),
    );
  }

  Rect _contentBounds(Map<String, Offset> positions) {
    if (positions.isEmpty) return const Rect.fromLTWH(0, 0, 200, 120);
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = 0.0;
    var maxY = 0.0;
    for (final p in positions.values) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx + PipelineTraceCanvas.nodeW);
      maxY = math.max(maxY, p.dy + PipelineTraceCanvas.nodeH);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

class _LegacyLinearFallback extends StatelessWidget {
  const _LegacyLinearFallback({
    required this.trace,
    this.entryId,
    this.fetchArtifact,
  });

  final Map<String, dynamic> trace;
  final String? entryId;
  final Future<String> Function(String relativePath)? fetchArtifact;

  @override
  Widget build(BuildContext context) {
    final steps = (trace['steps'] as List<dynamic>? ?? [])
        .where((s) => (s as Map)['type']?.toString() != 'policy')
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();
    return PipelineFlowGraph(
      title: 'Pipeline (linear fallback)',
      subtitle: 'trace 새로고침 시 2D 레이아웃 적용',
      steps: steps,
      entryId: entryId,
      fetchArtifact: fetchArtifact,
    );
  }
}

class _PhaseBand extends StatelessWidget {
  const _PhaseBand({
    required this.label,
    required this.top,
    required this.canvasW,
  });

  final String label;
  final double top;
  final double canvasW;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 4,
      top: top - 10,
      width: canvasW - 8,
      child: IgnorePointer(
        child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: context.subtleText)),
          const SizedBox(width: 6),
          Expanded(child: Divider(color: Colors.grey.shade300, height: 1)),
        ],
        ),
      ),
    );
  }
}

class _FlowNodeCard extends StatelessWidget {
  const _FlowNodeCard({required this.node, required this.onTap});

  final Map<String, dynamic> node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = node['status']?.toString() ?? 'pending';
    final type = node['type']?.toString() ?? '';
    final color = _statusColor(status, type);
    final label = node['label']?.toString().replaceAll('\n', ' ') ?? '';
    final ioHint = node['io_hint']?.toString() ?? '';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            height: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: color, width: status == 'skipped' ? 1 : 1.5),
              color:
                  color.withValues(alpha: status == 'skipped' ? 0.05 : 0.12),
            ),
            child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(_typeIcon(type), size: 11, color: color),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          height: 1.05,
                          color: color,
                        ),
                      ),
                    ),
                    _StatusIcon(status: status, color: color),
                  ],
                ),
                if (ioHint.isNotEmpty)
                  Text(
                    ioHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 6.5, color: context.subtleText, height: 1.05),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }

  Color _statusColor(String status, String type) {
    if (status == 'error') return Colors.red.shade700;
    if (status == 'waiting_user') return Colors.amber.shade800;
    if (status == 'skipped' || status == 'pending') return Colors.grey.shade600;
    return _typeAccent(type);
  }

  Color _typeAccent(String type) {
    switch (type) {
      case 'llm':
        return Colors.purple.shade700;
      case 'api':
        return Colors.blue.shade700;
      case 'graph':
        return Colors.green.shade700;
      case 'embed':
        return Colors.orange.shade800;
      case 'storage':
        return Colors.brown.shade700;
      case 'transform':
        return Colors.teal.shade700;
      case 'policy':
        return Colors.blueGrey.shade700;
      default:
        return Colors.indigo.shade700;
    }
  }

  IconData _typeIcon(String type) {
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

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'completed':
        return Icon(Icons.check_circle, size: 11, color: color);
      case 'error':
        return Icon(Icons.error, size: 11, color: color);
      case 'skipped':
        return Icon(Icons.remove_circle_outline, size: 11, color: Colors.grey);
      case 'waiting_user':
        return Icon(Icons.touch_app, size: 11, color: color);
      default:
        return Icon(Icons.radio_button_unchecked,
            size: 10, color: Colors.grey.shade400);
    }
  }
}

class _FlowEdgePainter extends CustomPainter {
  _FlowEdgePainter({
    required this.edges,
    required this.positions,
    required this.nodeW,
    required this.nodeH,
  });

  final List<Map<String, dynamic>> edges;
  final Map<String, Offset> positions;
  final double nodeW;
  final double nodeH;

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in edges) {
      if (edge['active'] == false) continue;

      final srcId = edge['source']?.toString();
      final tgtId = edge['target']?.toString();
      if (srcId == null || tgtId == null) continue;
      final src = positions[srcId];
      final tgt = positions[tgtId];
      if (src == null || tgt == null) continue;

      final paint = Paint()
        ..color = const Color(0xFF6366F1)
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final (start, end) = _ports(src, tgt);
      final path = Path()..moveTo(start.dx, start.dy);
      final midX = start.dx + (end.dx - start.dx) * 0.45;
      path.cubicTo(midX, start.dy, midX, end.dy, end.dx, end.dy);
      canvas.drawPath(path, paint);

      _drawArrow(canvas, end, end.dx >= start.dx);

      final label = edge['label']?.toString() ?? '';
      if (label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
                color: Color(0xFF6366F1),
                fontSize: 7,
                fontWeight: FontWeight.w600),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 48);
        tp.paint(
          canvas,
          Offset((start.dx + end.dx) / 2 - tp.width / 2,
              (start.dy + end.dy) / 2 - 10),
        );
      }
    }
  }

  (Offset, Offset) _ports(Offset src, Offset tgt) {
    final srcCx = src.dx + nodeW / 2;
    final srcCy = src.dy + nodeH / 2;
    final tgtCx = tgt.dx + nodeW / 2;
    final tgtCy = tgt.dy + nodeH / 2;

    if (tgtCx > srcCx + 8) {
      return (Offset(src.dx + nodeW, srcCy), Offset(tgt.dx, tgtCy));
    }
    if (tgtCy < srcCy - 4) {
      return (Offset(srcCx, src.dy), Offset(tgtCx, tgt.dy + nodeH));
    }
    if (tgtCy > srcCy + 4) {
      return (Offset(srcCx, src.dy + nodeH), Offset(tgtCx, tgt.dy));
    }
    return (Offset(src.dx + nodeW, srcCy), Offset(tgt.dx, tgtCy));
  }

  void _drawArrow(Canvas canvas, Offset tip, bool pointsRight) {
    const len = 6.0;
    const half = 3.5;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(-len, -half)
      ..lineTo(-len, half)
      ..close();
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    if (!pointsRight) canvas.rotate(math.pi);
    canvas.drawPath(path, Paint()..color = const Color(0xFF6366F1));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FlowEdgePainter oldDelegate) =>
      oldDelegate.edges != edges || oldDelegate.positions != positions;
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 2),
        Text(label, style: const TextStyle(fontSize: 8)),
      ],
    );
  }
}
