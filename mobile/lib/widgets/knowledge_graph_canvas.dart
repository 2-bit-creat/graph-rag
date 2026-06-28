import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';

const _kWorldPadding = 100.0;

double _canvasSmoothstep(double x, double lo, double hi) {
  if (x <= lo) return 0;
  if (x >= hi) return 1;
  final t = (x - lo) / (hi - lo);
  return t * t * (3 - 2 * t);
}

class GraphPanModeNotification extends Notification {
  const GraphPanModeNotification({required this.enabled});
  final bool enabled;
}

class KnowledgeGraphCanvas extends StatefulWidget {
  const KnowledgeGraphCanvas({
    super.key,
    required this.nodes,
    required this.edges,
    required this.typeColors,
    this.selectedNodeId,
    this.selectedEdgeId,
    this.highlightQuery = '',
    this.typeFilter = '전체',
    this.focusMode = true,
    this.compactMode = false,
    this.onNodeTap,
    this.onEdgeTap,
    this.onBackgroundTap,
  });

  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final Map<String, Color> typeColors;
  final String? selectedNodeId;
  final String? selectedEdgeId;
  final String highlightQuery;
  final String typeFilter;
  final bool focusMode;
  final bool compactMode;
  final void Function(Map<String, dynamic> node)? onNodeTap;
  final void Function(Map<String, dynamic> edge)? onEdgeTap;
  final VoidCallback? onBackgroundTap;

  @override
  State<KnowledgeGraphCanvas> createState() => KnowledgeGraphCanvasState();
}

class KnowledgeGraphCanvasState extends State<KnowledgeGraphCanvas> {
  GraphLayoutEngine? _layout;
  String? _draggingId;
  String? _hoveredNodeId;
  double? _dragAdaptiveScale;
  String? _hubId;
  final _transformationController = TransformationController();
  Size _lastViewport = Size.zero;
  bool _fitted = false;
  Size _worldSize = Size.zero;
  Offset _worldTranslate = Offset.zero;
  bool _showNodeLabels = true;
  bool _showEdgeLabels = true;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_onTransformChanged);
    _rebuildLayout();
  }

  void _onTransformChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant KnowledgeGraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes.length != widget.nodes.length ||
        oldWidget.edges.length != widget.edges.length ||
        !_sameIds(oldWidget.nodes, widget.nodes)) {
      _fitted = false;
      _rebuildLayout();
    }
  }

  bool _sameIds(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i]['id']?.toString() != b[i]['id']?.toString()) return false;
    }
    return true;
  }

  Map<String, double> _buildLayoutRadii(
    List<Map<String, dynamic>> nodes,
    Map<String, int> degrees,
    int maxDegree,
  ) {
    final n = nodes.length;
    return {
      for (final node in nodes)
        node['id'].toString(): graphLayoutRadiusForNode(
          degree: degrees[node['id'].toString()] ?? 0,
          maxDegree: maxDegree,
          name: nodeDisplayLabel(node),
          totalNodes: n,
        ),
    };
  }

  void _rebuildLayout() {
    if (widget.nodes.isEmpty) {
      _layout = null;
      _hubId = null;
      return;
    }
    final degrees = degreeByNodeId(widget.edges);
    final maxDegree = degrees.values.fold<int>(0, (m, v) => math.max(m, v));
    final radii = _buildLayoutRadii(widget.nodes, degrees, maxDegree);
    final ids = widget.nodes.map((n) => n['id'].toString()).toList();
    final types = {
      for (final n in widget.nodes)
        n['id'].toString(): n['type']?.toString() ?? '',
    };
    final edgePairs = widget.edges
        .map((e) => (source: e['source_id'].toString(), target: e['target_id'].toString()))
        .toList();
    _layout = GraphLayoutEngine(
      nodeIds: ids,
      edges: edgePairs,
      nodeRadii: radii,
      nodeTypes: types,
    );
    _hubId = ids.reduce((a, b) {
      final da = degrees[a] ?? 0;
      final db = degrees[b] ?? 0;
      if (da > db) return a;
      if (db > da) return b;
      return a.compareTo(b) < 0 ? a : b;
    });
    _syncWorldFrame();
  }

  void _syncWorldFrame({Size? viewport, bool preserveOrigin = false}) {
    final layout = _layout;
    if (layout == null) return;
    final vp = viewport ?? _lastViewport;
    if (vp == Size.zero) return;
    final bounds = layout.boundingRect(padding: 48);
    final newSize = _worldSizeFor(bounds, vp);
    if (preserveOrigin) {
      _worldSize = Size(
        math.max(_worldSize.width, newSize.width),
        math.max(_worldSize.height, newSize.height),
      );
      return;
    }
    _worldSize = newSize;
    final contentShift = Offset(
      (_worldSize.width - bounds.width) / 2,
      (_worldSize.height - bounds.height) / 2,
    );
    _worldTranslate = contentShift - bounds.topLeft;
  }

  void relayout() {
    setState(() {
      _rebuildLayout();
      _fitted = false;
    });
  }

  void _fitToView(Size viewport) {
    if (_layout == null || viewport.width <= 0 || viewport.height <= 0) return;

    _syncWorldFrame(viewport: viewport);
    final bounds = _layout!.boundingRect(padding: 48);
    final graphRect = Rect.fromLTWH(
      _worldTranslate.dx,
      _worldTranslate.dy,
      bounds.width,
      bounds.height,
    );
    const pad = 32.0;
    final scale = math.min(
      (viewport.width - pad * 2) / graphRect.width,
      (viewport.height - pad * 2) / graphRect.height,
    ).clamp(0.08, 4.0);
    final dx = (viewport.width - graphRect.width * scale) / 2 - graphRect.left * scale;
    final dy = (viewport.height - graphRect.height * scale) / 2 - graphRect.top * scale;

    _transformationController.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _fitted = true;
    _lastViewport = viewport;
  }

  Size _worldSizeFor(Rect contentBounds, Size viewport) {
    return Size(
      contentBounds.width + _kWorldPadding * 2,
      contentBounds.height + _kWorldPadding * 2,
    );
  }

  Rect get _layoutBounds =>
      _layout?.boundingRect(padding: 32) ?? const Rect.fromLTWH(0, 0, 400, 300);

  void _clampNodeToBounds(String id) {
    final layout = _layout;
    if (layout == null) return;
    final b = _layoutBounds;
    final p = layout.positions[id]!;
    layout.positions[id] = Offset(
      p.dx.clamp(b.left, b.right),
      p.dy.clamp(b.top, b.bottom),
    );
  }

  /// Keep the graph content from drifting completely off-screen.
  /// When the graph fits in the viewport, panning is left free.
  void _clampTransformToViewport(Size viewport, {bool recenterIfFits = false}) {
    if (_layout == null || viewport == Size.zero) return;

    final m = Matrix4.copy(_transformationController.value);
    final bounds = _layoutBounds;
    final contentRect = bounds.shift(_worldTranslate);

    final tl = MatrixUtils.transformPoint(m, contentRect.topLeft);
    final br = MatrixUtils.transformPoint(m, contentRect.bottomRight);
    final graphW = br.dx - tl.dx;
    final graphH = br.dy - tl.dy;

    const pad = 48.0;
    var dx = 0.0;
    var dy = 0.0;

    if (graphW <= viewport.width - pad * 2) {
      if (recenterIfFits) {
        dx = (viewport.width - graphW) / 2 - tl.dx;
      }
    } else {
      if (tl.dx > pad) dx = pad - tl.dx;
      if (br.dx < viewport.width - pad) dx = viewport.width - pad - br.dx;
    }

    if (graphH <= viewport.height - pad * 2) {
      if (recenterIfFits) {
        dy = (viewport.height - graphH) / 2 - tl.dy;
      }
    } else {
      if (tl.dy > pad) dy = pad - tl.dy;
      if (br.dy < viewport.height - pad) dy = viewport.height - pad - br.dy;
    }

    if (dx.abs() > 0.5 || dy.abs() > 0.5) {
      m.translateByDouble(dx, dy, 0, 1);
      _transformationController.value = m;
    }
  }

  void refit() {
    _fitted = false;
    if (_lastViewport != Size.zero) {
      _fitToView(_lastViewport);
    }
  }

  void _zoomBy(double factor) {
    if (_lastViewport == Size.zero) return;
    final center = Offset(_lastViewport.width / 2, _lastViewport.height / 2);
    final m = Matrix4.copy(_transformationController.value);
    m.translateByDouble(center.dx, center.dy, 0, 1);
    m.scaleByDouble(factor, factor, 1, 1);
    m.translateByDouble(-center.dx, -center.dy, 0, 1);
    _transformationController.value = m;
    _clampTransformToViewport(_lastViewport);
  }

  void _zoomAt(Offset focal, double factor) {
    final m = Matrix4.copy(_transformationController.value);
    m.translateByDouble(focal.dx, focal.dy, 0, 1);
    m.scaleByDouble(factor, factor, 1, 1);
    m.translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _transformationController.value = m;
    if (_lastViewport != Size.zero) _clampTransformToViewport(_lastViewport);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final delta = event.scrollDelta.dy;
      if (delta == 0) return;
      _zoomAt(event.localPosition, delta > 0 ? 0.92 : 1.08);
    }
  }

  void _notifyGraphPan(bool active) {
    if (widget.compactMode) {
      GraphPanModeNotification(enabled: active).dispatch(context);
    }
  }

  double get _currentScale => _transformationController.value.getMaxScaleOnAxis();

  bool _nodeMatchesFilter(Map<String, dynamic> node) {
    if (!entityTypeMatches(node['type']?.toString(), widget.typeFilter)) {
      return false;
    }
    final q = widget.highlightQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    final name = node['name']?.toString().toLowerCase() ?? '';
    final desc = node['description']?.toString().toLowerCase() ?? '';
    return name.contains(q) || desc.contains(q);
  }

  Set<String>? get _focusIds {
    if (!widget.focusMode || widget.selectedNodeId == null) return null;
    return neighborIds(widget.selectedNodeId!, widget.edges);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.isEmpty || _layout == null) {
      return const ColoredBox(
        color: AppColors.graphBgDark,
        child: Center(
          child: Text('노드 없음', style: TextStyle(color: AppColors.textMuted)),
        ),
      );
    }

    final layout = _layout!;
    final visibleNodes = widget.nodes.where(_nodeMatchesFilter).toList();
    final visibleIds = visibleNodes.map((n) => n['id'].toString()).toSet();
    final visibleEdges = widget.edges.where((e) {
      return visibleIds.contains(e['source_id'].toString()) &&
          visibleIds.contains(e['target_id'].toString());
    }).toList();

    final focusIds = _focusIds;
    final worldSize = _worldSize;
    final worldTranslate = _worldTranslate;

    final nodeColors = {
      for (final n in visibleNodes)
        n['id'].toString(): colorForType(
          n['type']?.toString() ?? '',
          widget.typeColors,
        ),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_fitted || _lastViewport != viewport) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitToView(viewport);
          });
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: AppColors.graphBgDark),
            Listener(
              onPointerSignal: _onPointerSignal,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    InteractiveViewer(
                      transformationController: _transformationController,
                      clipBehavior: Clip.hardEdge,
                      minScale: 0.25,
                      maxScale: 3.5,
                      boundaryMargin: const EdgeInsets.all(double.infinity),
                      panEnabled: _draggingId == null,
                      scaleEnabled: _draggingId == null,
                      trackpadScrollCausesScale: true,
                      onInteractionStart: (_) => _notifyGraphPan(true),
                      onInteractionEnd: (_) {
                        _notifyGraphPan(false);
                        _clampTransformToViewport(viewport);
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: widget.onBackgroundTap,
                        child: SizedBox(
                          width: math.max(worldSize.width, viewport.width),
                          height: math.max(worldSize.height, viewport.height),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _transformationController,
                      builder: (context, _) {
                        final matrix = _transformationController.value;
                        final scale = _currentScale;
                        final nodeIds =
                            visibleNodes.map((n) => n['id'].toString()).toList();
                        final computedAdaptiveScale = _computeZoomAdaptiveNodeScale(
                          nodeIds: nodeIds,
                          worldPositions: layout.positions,
                          worldRadii: layout.nodeRadii,
                          worldTranslate: worldTranslate,
                          matrix: matrix,
                        );
                        final adaptiveScale = _draggingId != null && _dragAdaptiveScale != null
                            ? _dragAdaptiveScale!
                            : computedAdaptiveScale;
                        final effectiveZoom = scale * adaptiveScale;
                        final nameAlpha = graphNameTextOpacity(scale) *
                            _canvasSmoothstep(adaptiveScale, 0.35, 0.75);
                        final nodeNameAlpha = _showNodeLabels ? nameAlpha : 0.0;

                        Offset toScreen(Offset world) =>
                            MatrixUtils.transformPoint(matrix, world);

                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Layer 1: curved colored edges.
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _CurvedEdgesPainter(
                                    edges: visibleEdges,
                                    positions: layout.positions,
                                    nodeRadii: layout.nodeRadii,
                                    radiusVisualScale: adaptiveScale,
                                    nodeColors: nodeColors,
                                    worldTranslate: worldTranslate,
                                    toScreen: toScreen,
                                    selectedNodeId: widget.selectedNodeId,
                                    selectedEdgeId: widget.selectedEdgeId,
                                    hoveredNodeId: _hoveredNodeId,
                                    focusIds: focusIds,
                                  ),
                                ),
                              ),
                            ),
                            // Layer 2: nodes (circle + label below).
                            ...visibleNodes.map((node) {
                              final id = node['id'].toString();
                              final screenPos =
                                  toScreen(layout.positions[id]! + worldTranslate);
                              final color = nodeColors[id]!;
                              final selected = id == widget.selectedNodeId;
                              final dimmed =
                                  focusIds != null && !focusIds.contains(id);
                              final worldR = layout.nodeRadii[id] ?? kGraphNodeRadius;
                              final screenR = graphScreenRadius(
                                worldR,
                                scale,
                                adaptiveScale: adaptiveScale,
                              );
                              final isHub = id == _hubId;
                              final isHovered = _hoveredNodeId == id;
                              final fillOpacity = graphNodeFillOpacity(
                                isHub: isHub,
                                dimmed: dimmed,
                                selected: selected,
                                hovered: isHovered,
                              );
                              final label = graphShortLabel(
                                nodeDisplayLabel(node),
                                screenR,
                                zoom: effectiveZoom,
                              );
                              final labelSize = (screenR * 0.34).clamp(8.0, 13.0);

                              void onNodePanEnd() {
                                _clampNodeToBounds(id);
                                layout.resolveCollisionsAround(id);
                                setState(() {
                                  _draggingId = null;
                                  _dragAdaptiveScale = null;
                                });
                                if (_lastViewport != Size.zero) {
                                  _syncWorldFrame(
                                    viewport: _lastViewport,
                                    preserveOrigin: true,
                                  );
                                }
                              }

                              final labelH =
                                  nodeNameAlpha > 0.02 ? labelSize * 1.5 : 0.0;
                              final totalH = screenR * 2 + labelH + 4;
                              final hitW = math.max(screenR * 2, kGraphMinHitDiameter);

                              return Positioned(
                                left: screenPos.dx - hitW / 2,
                                top: screenPos.dy - totalH / 2,
                                child: _GraphNode(
                                  label: label,
                                  color: color,
                                  screenRadius: screenR,
                                  labelSize: labelSize,
                                  fillOpacity: fillOpacity,
                                  selected: selected,
                                  isHub: isHub,
                                  dimmed: dimmed,
                                  nameOpacity: nodeNameAlpha,
                                  draggable: true,
                                  panScale: scale,
                                  onTap: () => widget.onNodeTap?.call(node),
                                  onHoverChanged: (h) =>
                                      setState(() => _hoveredNodeId = h ? id : null),
                                  onPanStart: () => setState(() {
                                    _dragAdaptiveScale = computedAdaptiveScale;
                                    _draggingId = id;
                                  }),
                                  onPanUpdate: (delta) {
                                    setState(() {
                                      layout.positions[id] =
                                          layout.positions[id]! + delta;
                                    });
                                  },
                                  onPanEnd: onNodePanEnd,
                                  dragging: _draggingId == id,
                                ),
                              );
                            }),
                            // Layer 3: minimal relation text on edges.
                            if (_showEdgeLabels)
                              ...visibleEdges.map((edge) {
                              final srcId = edge['source_id'].toString();
                              final tgtId = edge['target_id'].toString();
                              final src = layout.positions[srcId];
                              final tgt = layout.positions[tgtId];
                              if (src == null || tgt == null) {
                                return const SizedBox.shrink();
                              }

                              final rawRelation = edge['relation']?.toString() ?? '';
                              final label = graphRelationDisplayLabel(rawRelation);
                              if (label.isEmpty) return const SizedBox.shrink();

                              final edgeId = edge['id'].toString();
                              final selected = edgeId == widget.selectedEdgeId;
                              final nodeHit = widget.selectedNodeId != null &&
                                  (srcId == widget.selectedNodeId ||
                                      tgtId == widget.selectedNodeId);
                              final hoverHit = _hoveredNodeId != null &&
                                  (srcId == _hoveredNodeId || tgtId == _hoveredNodeId);
                              final connectedToFocus = focusIds != null &&
                                  focusIds.contains(srcId) &&
                                  focusIds.contains(tgtId);
                              final highlighted =
                                  selected || nodeHit || hoverHit || connectedToFocus;
                              final dimmed =
                                  focusIds != null && !connectedToFocus;

                              final labelOpacity = graphEdgeLabelOpacity(
                                scale,
                                highlighted: highlighted,
                              );
                              if (labelOpacity < 0.06 && !highlighted) {
                                return const SizedBox.shrink();
                              }

                              final srcR = (layout.nodeRadii[srcId] ?? kGraphNodeRadius) *
                                  adaptiveScale;
                              final tgtR = (layout.nodeRadii[tgtId] ?? kGraphNodeRadius) *
                                  adaptiveScale;
                              final a = toScreen(
                                _rimPoint(src, tgt, srcR) + worldTranslate,
                              );
                              final b = toScreen(
                                _rimPoint(tgt, src, tgtR) + worldTranslate,
                              );
                              final ctrl = graphCurvedEdgeControl(a, b);
                              final anchor = quadraticBezierPoint(a, ctrl, b, 0.5);
                              final side = edgeId.hashCode.isEven ? 1.0 : -1.0;
                              final nudge = graphEdgeLabelOffset(
                                a,
                                b,
                                magnitude: 6 * side,
                              );

                              final srcColor = nodeColors[srcId] ?? const Color(0xFF888888);
                              final tgtColor = nodeColors[tgtId] ?? srcColor;
                              final edgeTint = Color.lerp(srcColor, tgtColor, 0.4)!;

                              return Positioned(
                                left: anchor.dx + nudge.dx,
                                top: anchor.dy + nudge.dy,
                                child: _EdgeRelationLabel(
                                  label: label,
                                  edgeTint: edgeTint,
                                  fontSize: graphEdgeLabelFontSize(scale),
                                  opacity: dimmed ? labelOpacity * 0.35 : labelOpacity,
                                  highlighted: highlighted,
                                  selected: selected,
                                  onTap: () => widget.onEdgeTap?.call(edge),
                                ),
                              );
                            }),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            ),
            if (widget.compactMode)
              const Positioned(
                left: 10,
                top: 8,
                right: 56,
                child: IgnorePointer(
                  child: Text(
                    '빈 곳 드래그=이동 · 노드 드래그=개별 이동 · 휠=확대',
                    style: TextStyle(fontSize: 10, color: Color(0xFF6B7280)),
                  ),
                ),
              ),
            Positioned(
              right: 12,
              bottom: 12,
              child: _ZoomControls(
                scalePercent: (_currentScale * 100).round(),
                showNodeLabels: _showNodeLabels,
                showEdgeLabels: _showEdgeLabels,
                onZoomIn: () => _zoomBy(1.25),
                onZoomOut: () => _zoomBy(0.8),
                onFit: () {
                  _fitted = false;
                  _fitToView(viewport);
                },
                onRelayout: relayout,
                onToggleNodeLabels: () =>
                    setState(() => _showNodeLabels = !_showNodeLabels),
                onToggleEdgeLabels: () =>
                    setState(() => _showEdgeLabels = !_showEdgeLabels),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }
}

Offset _rimPoint(Offset from, Offset to, double radius) {
  final delta = to - from;
  final dist = delta.distance;
  if (dist < 1e-3) return from;
  return from + delta / dist * radius;
}

/// Largest uniform scale so circles never overlap at the current zoom.
double _computeZoomAdaptiveNodeScale({
  required List<String> nodeIds,
  required Map<String, Offset> worldPositions,
  required Map<String, double> worldRadii,
  required Offset worldTranslate,
  required Matrix4 matrix,
  double screenGap = 5.0,
  double minScale = 0.55,
}) {
  if (nodeIds.length < 2) return 1.0;

  final zoom = matrix.getMaxScaleOnAxis();
  final screenPos = <String, Offset>{};
  final baseR = <String, double>{};

  for (final id in nodeIds) {
    final wp = worldPositions[id];
    if (wp == null) continue;
    screenPos[id] = MatrixUtils.transformPoint(matrix, wp + worldTranslate);
    baseR[id] = (worldRadii[id] ?? kGraphNodeRadius) * zoom;
  }

  final ids = screenPos.keys.toList();
  if (ids.length < 2) return 1.0;

  bool overlaps(double scale) {
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final a = ids[i];
        final b = ids[j];
        final dist = (screenPos[a]! - screenPos[b]!).distance;
        final need = baseR[a]! * scale + baseR[b]! * scale + screenGap;
        if (dist < need - 0.5) return true;
      }
    }
    return false;
  }

  if (!overlaps(1.0)) return 1.0;
  if (overlaps(minScale)) return minScale;

  var lo = minScale;
  var hi = 1.0;
  for (var i = 0; i < 28; i++) {
    final mid = (lo + hi) / 2;
    if (overlaps(mid)) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return lo;
}

/// Curved, cluster-colored edges — reference graph style.
class _CurvedEdgesPainter extends CustomPainter {
  _CurvedEdgesPainter({
    required this.edges,
    required this.positions,
    required this.nodeRadii,
    required this.radiusVisualScale,
    required this.nodeColors,
    required this.worldTranslate,
    required this.toScreen,
    this.selectedNodeId,
    this.selectedEdgeId,
    this.hoveredNodeId,
    this.focusIds,
  });

  final List<Map<String, dynamic>> edges;
  final Map<String, Offset> positions;
  final Map<String, double> nodeRadii;
  final double radiusVisualScale;
  final Map<String, Color> nodeColors;
  final Offset worldTranslate;
  final Offset Function(Offset world) toScreen;
  final String? selectedNodeId;
  final String? selectedEdgeId;
  final String? hoveredNodeId;
  final Set<String>? focusIds;

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in edges) {
      final srcId = edge['source_id'].toString();
      final tgtId = edge['target_id'].toString();
      final src = positions[srcId];
      final tgt = positions[tgtId];
      if (src == null || tgt == null) continue;

      final srcR = (nodeRadii[srcId] ?? kGraphNodeRadius) * radiusVisualScale;
      final tgtR = (nodeRadii[tgtId] ?? kGraphNodeRadius) * radiusVisualScale;
      final a = toScreen(_rimPoint(src, tgt, srcR) + worldTranslate);
      final b = toScreen(_rimPoint(tgt, src, tgtR) + worldTranslate);
      final ctrl = graphCurvedEdgeControl(a, b, bend: 0.2);

      final edgeId = edge['id'].toString();
      final nodeHit = selectedNodeId != null &&
          (srcId == selectedNodeId || tgtId == selectedNodeId);
      final hoverHit = hoveredNodeId != null &&
          (srcId == hoveredNodeId || tgtId == hoveredNodeId);
      final edgeHit = edgeId == selectedEdgeId;
      final connectedToFocus =
          focusIds != null && focusIds!.contains(srcId) && focusIds!.contains(tgtId);
      final highlighted = nodeHit || edgeHit || connectedToFocus || hoverHit;
      final dimmed = focusIds != null && !connectedToFocus;

      final srcColor = nodeColors[srcId] ?? const Color(0xFF888888);
      final tgtColor = nodeColors[tgtId] ?? srcColor;
      final blended = Color.lerp(srcColor, tgtColor, 0.4)!;
      final color = graphEdgeTintColor(
        blended,
        highlighted: highlighted,
        dimmed: dimmed,
      );

      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);

      // Soft glow underlay.
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: highlighted ? 0.28 : 0.12)
          ..strokeWidth = highlighted ? 4.0 : 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );

      // Crisp edge line.
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = highlighted ? 1.5 : 1.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CurvedEdgesPainter oldDelegate) => true;
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.scalePercent,
    required this.showNodeLabels,
    required this.showEdgeLabels,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onRelayout,
    required this.onToggleNodeLabels,
    required this.onToggleEdgeLabels,
  });

  final int scalePercent;
  final bool showNodeLabels;
  final bool showEdgeLabels;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onRelayout;
  final VoidCallback onToggleNodeLabels;
  final VoidCallback onToggleEdgeLabels;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '$scalePercent%',
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF9CA3AF),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        _ZoomBtn(icon: Icons.add, tooltip: '확대', onTap: onZoomIn),
        _ZoomBtn(icon: Icons.remove, tooltip: '축소', onTap: onZoomOut),
        _ZoomBtn(icon: Icons.fit_screen, tooltip: '전체 보기', onTap: onFit),
        _ZoomBtn(icon: Icons.auto_awesome, tooltip: '레이아웃 재정렬', onTap: onRelayout),
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 2),
          child: SizedBox(width: 38, child: Divider(height: 1, color: Color(0xFF2D2D38))),
        ),
        _ZoomBtn(
          icon: showNodeLabels ? Icons.label : Icons.label_off_outlined,
          tooltip: showNodeLabels ? '노드 이름 숨기기' : '노드 이름 보기',
          active: showNodeLabels,
          onTap: onToggleNodeLabels,
        ),
        _ZoomBtn(
          icon: showEdgeLabels ? Icons.link : Icons.link_off,
          tooltip: showEdgeLabels ? '관계 라벨 숨기기' : '관계 라벨 보기',
          active: showEdgeLabels,
          onTap: onToggleEdgeLabels,
        ),
      ],
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  const _ZoomBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: active ? const Color(0xFF252532) : const Color(0xFF1A1A22),
        elevation: 0,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Tooltip(
            message: tooltip,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: active ? const Color(0xFF5B5FEF) : const Color(0xFF2D2D38),
                ),
              ),
              child: Icon(
                icon,
                color: active ? const Color(0xFFE8E8F0) : const Color(0xFF9CA3AF),
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimal relation text floating on an edge — no box or border.
class _EdgeRelationLabel extends StatelessWidget {
  const _EdgeRelationLabel({
    required this.label,
    required this.edgeTint,
    required this.fontSize,
    required this.opacity,
    required this.highlighted,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color edgeTint;
  final double fontSize;
  final double opacity;
  final bool highlighted;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textColor = highlighted || selected
        ? Colors.white.withValues(alpha: 0.95)
        : edgeTint.withValues(alpha: 0.7);

    return Transform.translate(
      offset: Offset(-label.length * fontSize * 0.27, -fontSize * 0.5),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: opacity,
          child: Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.0,
              letterSpacing: 0.1,
              fontWeight: highlighted ? FontWeight.w600 : FontWeight.w400,
              fontStyle: FontStyle.italic,
              color: textColor,
              shadows: const [
                Shadow(
                  color: Color(0xF0000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
                Shadow(
                  color: Color(0xC0000000),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Professional node: glowing circle + label below.
class _GraphNode extends StatefulWidget {
  const _GraphNode({
    required this.label,
    required this.color,
    required this.screenRadius,
    required this.labelSize,
    required this.fillOpacity,
    required this.selected,
    required this.isHub,
    required this.dimmed,
    required this.nameOpacity,
    required this.draggable,
    required this.panScale,
    required this.onTap,
    this.onHoverChanged,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    required this.dragging,
  });

  final String label;
  final Color color;
  final double screenRadius;
  final double labelSize;
  final double fillOpacity;
  final bool selected;
  final bool isHub;
  final bool dimmed;
  final double nameOpacity;
  final bool draggable;
  final double panScale;
  final VoidCallback onTap;
  final ValueChanged<bool>? onHoverChanged;
  final VoidCallback? onPanStart;
  final ValueChanged<Offset>? onPanUpdate;
  final VoidCallback? onPanEnd;
  final bool dragging;

  @override
  State<_GraphNode> createState() => _GraphNodeState();
}

class _GraphNodeState extends State<_GraphNode> {
  bool _pointerMoved = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.screenRadius;
    final d = r * 2;
    final hitW = math.max(d, kGraphMinHitDiameter);
    final showLabel = widget.nameOpacity > 0.02;
    final active = widget.selected || _hovered || widget.dragging;
    final scale = active ? 1.1 : 1.0;

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHoverChanged?.call(true);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHoverChanged?.call(false);
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _pointerMoved = false,
        onPointerMove: (event) {
          if (!widget.draggable || widget.onPanUpdate == null) return;
          if (event.delta.distanceSquared <= 1) return;
          if (!_pointerMoved) {
            _pointerMoved = true;
            widget.onPanStart?.call();
          }
          widget.onPanUpdate!(event.delta / widget.panScale);
        },
        onPointerUp: (_) {
          if (!_pointerMoved) widget.onTap();
          if (_pointerMoved && widget.draggable) widget.onPanEnd?.call();
          _pointerMoved = false;
        },
        onPointerCancel: (_) {
          if (_pointerMoved && widget.draggable) widget.onPanEnd?.call();
          _pointerMoved = false;
        },
        child: SizedBox(
          width: hitW,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: AnimatedContainer(
                  duration: widget.dragging ? Duration.zero : const Duration(milliseconds: 200),
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: widget.fillOpacity),
                    border: widget.selected
                        ? Border.all(color: Colors.white, width: 2.5)
                        : _hovered
                            ? Border.all(
                                color: Colors.white.withValues(alpha: 0.75),
                                width: 1.5,
                              )
                            : null,
                    boxShadow: [
                      if (widget.isHub || active)
                        BoxShadow(
                          color: widget.color.withValues(alpha: active ? 0.45 : 0.3),
                          blurRadius: active ? 12 : 8,
                          spreadRadius: 0,
                        ),
                    ],
                  ),
                ),
              ),
              if (showLabel) ...[
                const SizedBox(height: 4),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: widget.dimmed ? widget.nameOpacity * 0.6 : widget.nameOpacity,
                  child: Text(
                    widget.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active
                          ? Colors.white
                          : AppColors.graphLabelLight,
                      fontSize: widget.labelSize,
                      fontWeight: widget.isHub || active ? FontWeight.w700 : FontWeight.w500,
                      height: 1.15,
                      letterSpacing: 0.1,
                      shadows: const [
                        Shadow(
                          color: Color(0xE6000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class OntologyLegendBar extends StatelessWidget {
  const OntologyLegendBar({
    super.key,
    required this.entityTypes,
    required this.typeColors,
    required this.selectedType,
    required this.onTypeSelected,
  });

  final List<Map<String, dynamic>> entityTypes;
  final Map<String, Color> typeColors;
  final String selectedType;
  final ValueChanged<String> onTypeSelected;

  @override
  Widget build(BuildContext context) {
    if (entityTypes.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _LegendChip(
            label: '전체',
            color: AppColors.textMuted,
            selected: selectedType == '전체',
            onTap: () => onTypeSelected('전체'),
          ),
          ...entityTypes.map((et) {
            final name = et['name']?.toString() ?? '';
            final color = typeColors[name] ?? parseHexColor('#64748b');
            return _LegendChip(
              label: name,
              color: color,
              selected: selectedType == name,
              onTap: () => onTypeSelected(name),
            );
          }),
        ],
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isAll = label == '전체';
    final bg = selected
        ? (isAll ? const Color(0xFF2A2A34) : color.withValues(alpha: 0.18))
        : const Color(0xFF14141C);
    final border = selected
        ? (isAll ? const Color(0xFF6B7280) : color)
        : const Color(0xFF2D2D38);
    final textColor = selected ? AppColors.graphLabelLight : const Color(0xFF9CA3AF);

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border, width: selected ? 1.5 : 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: isAll ? const Color(0xFF6B7280) : color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: textColor,
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
