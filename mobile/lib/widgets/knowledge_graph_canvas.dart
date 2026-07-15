import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';

const _kWorldPadding = 100.0;

/// Below this effective zoom the painter drops blurs, edge glow and edge
/// labels (LOD far-zoom cut).
const _kLodFancyZoom = 0.35;

/// Above this node count the O(n²) physics ticks at 30Hz (every other frame)
/// while rendering stays at full frame rate.
const _kLiveSimMaxNodes = 450;

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
    this.hideHeadNodes = false,
    this.glowNodeIds = const {},
    this.glowSeq = 0,
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

  /// 화자 숨김(Speaker-to-Color) 모드: head(화자·출처) 노드와 그 귀속 엣지를
  /// 물리 엔진 데이터에서 통째로 제거하고, Statement를 화자색으로 인코딩한다.
  /// 시각적 숨김만 하면 보이지 않는 스프링이 성게 뭉침을 유지하므로 반드시
  /// 데이터 레벨에서 제거해야 한다.
  final bool hideHeadNodes;

  /// 그래프 대화 스파크: AI 답변이 참조한 노드들. [glowSeq]가 증가할 때마다
  /// 해당 노드들 위에서 펄스 링 + 스파크 파티클 애니메이션이 1회 재생된다.
  final Set<String> glowNodeIds;
  final int glowSeq;
  final void Function(Map<String, dynamic> node)? onNodeTap;
  final void Function(Map<String, dynamic> edge)? onEdgeTap;
  final VoidCallback? onBackgroundTap;

  @override
  State<KnowledgeGraphCanvas> createState() => KnowledgeGraphCanvasState();
}

class KnowledgeGraphCanvasState extends State<KnowledgeGraphCanvas>
    with TickerProviderStateMixin {
  GraphLayoutEngine? _layout;
  String? _draggingId;
  String? _hoveredNodeId;
  String? _hubId;
  final _transformationController = TransformationController();
  Size _lastViewport = Size.zero;
  bool _fitted = false;
  Size _worldSize = Size.zero;
  Offset _worldTranslate = Offset.zero;
  bool _showNodeLabels = true;
  bool _showEdgeLabels = true;

  /// Canvas brightness, refreshed in [build]. Node labels, selection rings and
  /// the nebula backdrop pick their colors from this so the scene reads on both
  /// the dark and light shell backgrounds.
  bool _darkCanvas = true;
  Color get _canvasBackground =>
      _darkCanvas ? AppColors.graphBgDark : const Color(0xFFEEF1F7);

  // Live simulation: the ticker drives GraphLayoutEngine.tick and stops when
  // the sim settles, so an untouched graph costs zero CPU.
  late final Ticker _ticker;
  Duration _lastTickTime = Duration.zero;
  final _frameNotifier = ValueNotifier<int>(0);

  // Animated focus dim (neighbor highlight). The controller also doubles as
  // the repaint clock for the per-node active-scale easing.
  late final AnimationController _focusAnim;
  late final Listenable _repaint;
  Set<String>? _focusIds;
  String? _focusTarget;

  // Smooth camera pan toward a selected node.
  late final AnimationController _cameraAnim;
  Matrix4? _cameraBegin;
  Matrix4? _cameraEnd;

  // One-shot spark/glow animation over referenced nodes (graph chat).
  // Pure function of the controller value — no per-particle state.
  late final AnimationController _glowAnim;

  // Per-node hover/selection scale progress, eased in the paint loop.
  final _activeT = <String, double>{};

  // Per-build derived data read by the painter and hit tests.
  List<Map<String, dynamic>> _visibleNodes = const [];
  List<Map<String, dynamic>> _visibleEdges = const [];
  List<Map<String, dynamic>> _paintNodes = const [];
  Map<String, Color> _nodeColors = const {};
  // 숨김 모드에서 엣지가 하나도 없는 노드(Concept 없는 Statement 등):
  // 링크 포스를 잃고 밖으로 밀려나므로 배경처럼 디밍한다.
  Set<String> _dimmedIds = const {};
  Map<String, String> _typeById = const {};
  Map<String, int> _degrees = const {};
  int _maxDegree = 0;
  int _maxImportance = 0;

  // Cached Korean text layouts — TextPainter.layout is the expensive part,
  // paint is cheap. World-space font sizes keep keys zoom-independent.
  final _labelCache = <String, TextPainter>{};

  // Edge-label rects (world coords) recorded during paint for hit testing.
  final _edgeLabelHits = <({Rect rect, Map<String, dynamic> edge})>[];

  // Adaptive node-scale memo: the O(n²) binary search only reruns when the
  // zoom bucket or layout epoch changes, and is frozen while the sim runs.
  double _cachedAdaptiveScale = 1.0;
  int _adaptiveEpoch = -1;
  int _adaptiveBucket = -1;
  int _layoutEpoch = 0;

  // Drag state for tap-vs-drag discrimination and release inertia.
  String? _downNodeId;
  Map<String, dynamic>? _downEdge;
  Offset _downPos = Offset.zero;
  bool _surfaceMoved = false;
  final _dragSamples = <({Duration t, Offset p})>[];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _focusAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _cameraAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    )..addListener(_onCameraTick);
    _glowAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _repaint = Listenable.merge([
      _transformationController,
      _frameNotifier,
      _focusAnim,
      _glowAnim,
    ]);
    _rebuildLayout();
  }

  void _onCameraTick() {
    final begin = _cameraBegin;
    final end = _cameraEnd;
    if (begin == null || end == null) return;
    final t = Curves.easeOutCubic.transform(_cameraAnim.value);
    _transformationController.value =
        Matrix4Tween(begin: begin, end: end).lerp(t);
  }

  /// Glides the camera so [nodeId] lands near the viewport center. Keeps the
  /// current zoom (bumped up to [minZoom] when zoomed far out). [verticalBias]
  /// < 0.5 leaves room for an info card at the bottom of the screen.
  void centerOnNode(String nodeId, {double minZoom = 0.9, double verticalBias = 0.42}) {
    final layout = _layout;
    if (layout == null || _lastViewport == Size.zero) return;
    final wp = layout.positions[nodeId];
    if (wp == null) return;
    final zoom = _currentScale < minZoom ? minZoom : _currentScale;
    final world = wp + _worldTranslate;
    final vp = _lastViewport;
    _cameraBegin = Matrix4.copy(_transformationController.value);
    _cameraEnd = Matrix4.identity()
      ..translateByDouble(
        vp.width / 2 - world.dx * zoom,
        vp.height * verticalBias - world.dy * zoom,
        0,
        1,
      )
      ..scaleByDouble(zoom, zoom, 1, 1);
    _cameraAnim.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant KnowledgeGraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes.length != widget.nodes.length ||
        oldWidget.edges.length != widget.edges.length ||
        oldWidget.hideHeadNodes != widget.hideHeadNodes ||
        !_sameIds(oldWidget.nodes, widget.nodes)) {
      // 모드 토글도 여기로 온다: 살아남는 노드가 위치를 승계(incremental seed)
      // 하고 reheat만 받으므로, 전체 재배치 없이 부드럽게 재클러스터링된다.
      _rebuildLayout();
      if (!(_layout?.seededIncrementally ?? false)) _fitted = false;
    }
    if (oldWidget.typeFilter != widget.typeFilter ||
        oldWidget.highlightQuery != widget.highlightQuery) {
      _layoutEpoch++; // adaptive scale depends on the visible node set
    }
    if (oldWidget.selectedNodeId != widget.selectedNodeId ||
        oldWidget.focusMode != widget.focusMode ||
        oldWidget.highlightQuery != widget.highlightQuery) {
      _syncFocus();
    }
    if (oldWidget.glowSeq != widget.glowSeq && widget.glowNodeIds.isNotEmpty) {
      _glowAnim.forward(from: 0);
    }
  }

  /// 카메라를 [nodeIds]의 바운딩 박스로 글라이드 (그래프 대화 스파크용).
  void focusOnNodes(Set<String> nodeIds) {
    final layout = _layout;
    if (layout == null || nodeIds.isEmpty || _lastViewport == Size.zero) return;
    Rect? bounds;
    for (final id in nodeIds) {
      final wp = layout.positions[id];
      if (wp == null) continue;
      final r = Rect.fromCircle(center: wp, radius: kGraphNodeRadius * 3);
      bounds = bounds == null ? r : bounds.expandToInclude(r);
    }
    if (bounds == null) return;
    final vp = _lastViewport;
    final fit = math.min(vp.width / (bounds.width + 120),
            vp.height / (bounds.height + 120))
        .clamp(0.3, 1.4);
    final world = bounds.center + _worldTranslate;
    _cameraBegin = Matrix4.copy(_transformationController.value);
    _cameraEnd = Matrix4.identity()
      ..translateByDouble(
        vp.width / 2 - world.dx * fit,
        vp.height / 2 - world.dy * fit,
        0,
        1,
      )
      ..scaleByDouble(fit, fit, 1, 1);
    _cameraAnim.forward(from: 0);
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
          type: node['type']?.toString(),
        ),
    };
  }

  // Physics data set for the current mode. In head-hide mode the head nodes
  // and every edge touching them are gone from these lists entirely — the
  // layout engine, focus logic and painter all operate on this filtered view.
  List<Map<String, dynamic>> get _effectiveNodes => !widget.hideHeadNodes
      ? widget.nodes
      : [
          for (final n in widget.nodes)
            if (!isStatementHeadType(n['type']?.toString())) n,
        ];

  List<Map<String, dynamic>> get _effectiveEdges {
    if (!widget.hideHeadNodes) return widget.edges;
    final ids = {for (final n in _effectiveNodes) n['id'].toString()};
    return [
      for (final e in widget.edges)
        if (ids.contains(e['source_id'].toString()) &&
            ids.contains(e['target_id'].toString()))
          e,
    ];
  }

  void _rebuildLayout({bool fullReset = false}) {
    _layoutEpoch++;
    _clearLabelCache();
    _edgeLabelHits.clear();
    _activeT.clear();
    final effNodes = _effectiveNodes;
    final effEdges = _effectiveEdges;
    if (effNodes.isEmpty) {
      _layout = null;
      _hubId = null;
      _typeById = const {};
      return;
    }
    final degrees = degreeByNodeId(effEdges);
    final maxDegree = degrees.values.fold<int>(0, (m, v) => math.max(m, v));
    final radii = _buildLayoutRadii(effNodes, degrees, maxDegree);
    final ids = effNodes.map((n) => n['id'].toString()).toList();
    final types = {
      for (final n in effNodes)
        n['id'].toString(): n['type']?.toString() ?? '',
    };
    final edgePairs = effEdges
        .map((e) => (source: e['source_id'].toString(), target: e['target_id'].toString()))
        .toList();
    final old = _layout;
    final initialPositions = !fullReset && old != null
        ? Map<String, Offset>.from(old.positions)
        : null;
    _layout = GraphLayoutEngine(
      nodeIds: ids,
      edges: edgePairs,
      nodeRadii: radii,
      nodeTypes: types,
      initialPositions: initialPositions,
    );
    _typeById = types;
    _degrees = degrees;
    _maxDegree = maxDegree;
    _hubId = ids.reduce((a, b) {
      final da = degrees[a] ?? 0;
      final db = degrees[b] ?? 0;
      if (da > db) return a;
      if (db > da) return b;
      return a.compareTo(b) < 0 ? a : b;
    });
    _syncWorldFrame();
    if (_layout!.seededIncrementally) {
      // Data refresh (e.g. inspector edit): keep positions, settle gently.
      _layout!.reheat(0.5);
      _ensureTicking();
    }
    _syncFocus();
  }

  void _clearLabelCache() {
    for (final p in _labelCache.values) {
      p.dispose();
    }
    _labelCache.clear();
  }

  // ---------------------------------------------------------------------
  // Live simulation ticker
  // ---------------------------------------------------------------------

  int _tickParity = 0;

  void _onTick(Duration elapsed) {
    final layout = _layout;
    if (layout == null) {
      _ticker.stop();
      return;
    }
    // Large graphs: physics at 30Hz, rendering stays at frame rate.
    _tickParity ^= 1;
    if (layout.nodeIds.length > _kLiveSimMaxNodes && _tickParity == 0) {
      _frameNotifier.value++;
      return;
    }
    var dt = _lastTickTime == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTickTime).inMicroseconds / 1e6;
    _lastTickTime = elapsed;
    dt = dt.clamp(0.001, 1 / 30);
    final active = layout.tick(dt);
    _frameNotifier.value++;
    if (!active && _draggingId == null) {
      _ticker.stop();
      _lastTickTime = Duration.zero;
      _layoutEpoch++; // graph is at rest — allow adaptive-scale recompute
      if (_lastViewport != Size.zero) {
        _syncWorldFrame(viewport: _lastViewport, preserveOrigin: true);
      }
    }
  }

  void _ensureTicking() {
    if (!_ticker.isActive) {
      _lastTickTime = Duration.zero;
      _ticker.start();
    }
  }

  // ---------------------------------------------------------------------
  // Focus (neighbor highlight) handling
  // ---------------------------------------------------------------------

  void _syncFocus() {
    final target = widget.selectedNodeId ?? _hoveredNodeId;
    final valid =
        target != null && (_layout?.positions.containsKey(target) ?? false);
    if (valid) {
      if (target == _focusTarget) return;
      _focusTarget = target;
      // Effective edges: 숨김 모드에서는 head 경유 2-hop이 자연히 1-hop으로
      // 강등된다 (far tier가 데이터에 없으므로).
      _focusIds = tierFocusIds(target, _typeById, _effectiveEdges);
      _focusAnim.forward(from: _focusAnim.value > 0.6 ? 0.35 : _focusAnim.value);
      return;
    }
    // No selection/hover: an active search query drives the same dim path,
    // spotlighting matches without hiding the rest of the graph.
    final queryMatches = _queryMatchIds();
    if (queryMatches.isNotEmpty) {
      final queryKey = 'q:${widget.highlightQuery.trim().toLowerCase()}';
      if (queryKey == _focusTarget) return;
      _focusTarget = queryKey;
      _focusIds = queryMatches;
      _focusAnim.forward(from: _focusAnim.value > 0.6 ? 0.35 : _focusAnim.value);
      return;
    }
    if (_focusTarget == null && _focusAnim.isDismissed) return;
    _focusTarget = null;
    _focusAnim.reverse();
  }

  // ---------------------------------------------------------------------
  // World frame / viewport helpers (unchanged math)
  // ---------------------------------------------------------------------

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
      _rebuildLayout(fullReset: true);
      _fitted = false;
    });
  }

  void _fitToView(Size viewport) {
    if (_layout == null || viewport.width <= 0 || viewport.height <= 0) return;

    _syncWorldFrame(viewport: viewport);
    final bounds = _layout!.boundingRect(padding: 48);
    // _worldTranslate is an offset relative to bounds.topLeft (see
    // _syncWorldFrame), not an absolute position — shift the bounds by it
    // rather than replacing its origin, or the fit frames the wrong region
    // whenever the layout isn't centered near (0, 0).
    final graphRect = bounds.shift(_worldTranslate);
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

  // Type filter hides nodes; the search query does NOT — matching nodes are
  // highlighted and the rest dimmed, so the graph context stays visible.
  bool _nodeMatchesFilter(Map<String, dynamic> node) {
    return entityTypeMatches(node['type']?.toString(), widget.typeFilter);
  }

  bool _nodeMatchesQuery(Map<String, dynamic> node, String q) {
    final name = node['name']?.toString().toLowerCase() ?? '';
    final desc = node['description']?.toString().toLowerCase() ?? '';
    return name.contains(q) || desc.contains(q);
  }

  Set<String> _queryMatchIds() {
    final q = widget.highlightQuery.trim().toLowerCase();
    if (q.isEmpty) return const {};
    return {
      for (final n in _effectiveNodes)
        if (_nodeMatchesFilter(n) && _nodeMatchesQuery(n, q)) n['id'].toString(),
    };
  }

  // ---------------------------------------------------------------------
  // Hit testing (world-space, replaces the per-node widget overlay)
  // ---------------------------------------------------------------------

  Offset? _toWorld(Offset local) {
    final inv = Matrix4.tryInvert(_transformationController.value);
    if (inv == null) return null;
    return MatrixUtils.transformPoint(inv, local) - _worldTranslate;
  }

  double _adaptiveScaleFor(Matrix4 matrix) {
    final layout = _layout;
    if (layout == null) return 1.0;
    final zoom = matrix.getMaxScaleOnAxis();
    final bucket = (zoom / 0.05).round();
    final simActive = _ticker.isActive;
    if (_adaptiveEpoch == _layoutEpoch &&
        (simActive || bucket == _adaptiveBucket)) {
      return _cachedAdaptiveScale;
    }
    _cachedAdaptiveScale = _computeZoomAdaptiveNodeScale(
      nodeIds: _visibleNodes.map((n) => n['id'].toString()).toList(),
      worldPositions: layout.positions,
      worldRadii: layout.nodeRadii,
      worldTranslate: _worldTranslate,
      matrix: matrix,
    );
    _adaptiveEpoch = _layoutEpoch;
    _adaptiveBucket = bucket;
    return _cachedAdaptiveScale;
  }

  /// Topmost node under a screen-space point (reverse paint order).
  String? _hitNodeAt(Offset local) {
    final layout = _layout;
    if (layout == null) return null;
    final matrix = _transformationController.value;
    final zoom = matrix.getMaxScaleOnAxis();
    final adaptive = _adaptiveScaleFor(matrix);
    for (final node in _paintNodes.reversed) {
      final id = node['id'].toString();
      final wp = layout.positions[id];
      if (wp == null) continue;
      final sp = MatrixUtils.transformPoint(matrix, wp + _worldTranslate);
      final screenR = math.max(
        (layout.nodeRadii[id] ?? kGraphNodeRadius) * zoom * adaptive,
        kGraphMinHitDiameter / 2,
      );
      if ((sp - local).distance <= screenR + 2) return id;
    }
    return null;
  }

  Map<String, dynamic>? _hitEdgeLabelAt(Offset local) {
    if (!_showEdgeLabels || _edgeLabelHits.isEmpty) return null;
    final world = _toWorld(local);
    if (world == null) return null;
    final zoom = _currentScale.clamp(1e-3, 100.0);
    final pad = 6 / zoom;
    for (final h in _edgeLabelHits.reversed) {
      if (h.rect.inflate(pad).contains(world)) return h.edge;
    }
    return null;
  }

  bool _hitPredicate(Offset local) =>
      _hitNodeAt(local) != null || _hitEdgeLabelAt(local) != null;

  Map<String, dynamic>? _nodeById(String id) {
    for (final n in widget.nodes) {
      if (n['id'].toString() == id) return n;
    }
    return null;
  }

  void _onSurfaceDown(PointerDownEvent e) {
    _downNodeId = _hitNodeAt(e.localPosition);
    _downEdge = _downNodeId == null ? _hitEdgeLabelAt(e.localPosition) : null;
    _downPos = e.localPosition;
    _surfaceMoved = false;
    _dragSamples.clear();
  }

  void _onSurfaceMove(PointerMoveEvent e) {
    final id = _downNodeId;
    final layout = _layout;
    if (id == null || layout == null || !layout.positions.containsKey(id)) {
      return;
    }
    if (!_surfaceMoved) {
      if ((e.localPosition - _downPos).distance < 4) return;
      _surfaceMoved = true;
      layout.pinnedId = id;
      layout.alphaTarget = 0.3;
      layout.reheat(0.3);
      _ensureTicking();
      setState(() => _draggingId = id);
    }
    final world = _toWorld(e.localPosition);
    if (world != null) {
      layout.positions[id] = world;
      _dragSamples.add((t: e.timeStamp, p: world));
      if (_dragSamples.length > 6) _dragSamples.removeAt(0);
    }
    _frameNotifier.value++;
  }

  void _onSurfaceUp(PointerUpEvent e) {
    final id = _downNodeId;
    if (id == null) {
      final edge = _downEdge;
      if (!_surfaceMoved && edge != null) widget.onEdgeTap?.call(edge);
    } else if (!_surfaceMoved) {
      final node = _nodeById(id);
      if (node != null) widget.onNodeTap?.call(node);
    } else {
      _releaseDrag(id, fling: true);
    }
    _downNodeId = null;
    _downEdge = null;
    _surfaceMoved = false;
  }

  void _onSurfaceCancel(PointerCancelEvent e) {
    final id = _downNodeId;
    if (id != null && _surfaceMoved) _releaseDrag(id, fling: false);
    _downNodeId = null;
    _downEdge = null;
    _surfaceMoved = false;
  }

  void _releaseDrag(String id, {required bool fling}) {
    final layout = _layout;
    if (layout == null) return;
    layout.pinnedId = null;
    layout.alphaTarget = 0.0;
    if (fling && _dragSamples.length >= 2) {
      final first = _dragSamples.first;
      final last = _dragSamples.last;
      final dtMs = (last.t - first.t).inMicroseconds / 1000.0;
      if (dtMs > 1) {
        // World-units per 60fps frame; capped so a flick can't explode.
        var v = (last.p - first.p) * (16.7 / dtMs);
        final speed = v.distance;
        const cap = 48.0;
        if (speed > cap) v = v * (cap / speed);
        layout.velocities[id] = v;
      }
    }
    if (layout.positions.containsKey(id)) _clampNodeToBounds(id);
    layout.reheat(0.25);
    _ensureTicking();
    setState(() => _draggingId = null);
    if (_lastViewport != Size.zero) {
      _syncWorldFrame(viewport: _lastViewport, preserveOrigin: true);
    }
  }

  void _onSurfaceHover(PointerHoverEvent e) {
    final id = _hitNodeAt(e.localPosition);
    if (id != _hoveredNodeId) {
      _hoveredNodeId = id;
      _syncFocus();
      _frameNotifier.value++;
    }
  }

  void _onSurfaceExit(PointerExitEvent e) {
    if (_hoveredNodeId != null) {
      _hoveredNodeId = null;
      _syncFocus();
      _frameNotifier.value++;
    }
  }

  // ---------------------------------------------------------------------
  // Scene painting (single canvas pass, world coordinates)
  // ---------------------------------------------------------------------

  void _advanceActive() {
    for (final node in _paintNodes) {
      final id = node['id'].toString();
      final target = (id == widget.selectedNodeId ||
              id == _hoveredNodeId ||
              id == _draggingId)
          ? 1.0
          : 0.0;
      final cur = _activeT[id] ?? 0.0;
      final next = cur + (target - cur) * 0.28;
      _activeT[id] = (next - target).abs() < 0.01 ? target : next;
    }
  }

  void _paintScene(Canvas canvas, Size size) {
    final layout = _layout;
    if (layout == null) return;

    // Nebula background — screen space, before the world transform. A soft
    // radial in dark mode; a barely-there light wash in light mode so the
    // colored discs still sit on a calm, near-white field.
    final bgRect = Offset.zero & size;
    canvas.drawRect(
      bgRect,
      Paint()
        ..shader = ui.Gradient.radial(
          bgRect.center,
          size.longestSide * 0.75,
          _darkCanvas
              ? const [AppColors.graphNebulaCore, AppColors.graphBgDark]
              : const [Color(0xFFF4F6FB), Color(0xFFE7ECF4)],
        ),
    );

    final matrix = _transformationController.value;
    final zoom = matrix.getMaxScaleOnAxis().clamp(1e-3, 100.0).toDouble();
    final adaptive = _adaptiveScaleFor(matrix);
    final effectiveZoom = zoom * adaptive;
    final lodFancy = effectiveZoom >= _kLodFancyZoom;

    Rect cullWorld;
    try {
      cullWorld = MatrixUtils.inverseTransformRect(matrix, bgRect)
          .shift(-_worldTranslate)
          .inflate(160);
    } catch (_) {
      cullWorld = layout.boundingRect(padding: 200);
    }

    _advanceActive();
    _edgeLabelHits.clear();

    canvas.save();
    canvas.transform(matrix.storage);
    canvas.translate(_worldTranslate.dx, _worldTranslate.dy);

    final focusProgress = widget.focusMode ? _focusAnim.value : 0.0;
    final focusSet = focusProgress > 0.004 ? _focusIds : null;

    if (focusSet == null) {
      _paintEdges(canvas, _visibleEdges, zoom, lodFancy, cullWorld, adaptive);
      _paintNodeDiscs(canvas, _paintNodes, zoom, lodFancy, cullWorld, adaptive);
      _paintNodeLabels(canvas, _paintNodes, zoom, cullWorld, adaptive);
      _paintEdgeLabels(canvas, _visibleEdges, zoom, lodFancy, cullWorld, adaptive);
    } else {
      final dimEdges = <Map<String, dynamic>>[];
      final litEdges = <Map<String, dynamic>>[];
      for (final e in _visibleEdges) {
        final inFocus = focusSet.contains(e['source_id'].toString()) &&
            focusSet.contains(e['target_id'].toString());
        (inFocus ? litEdges : dimEdges).add(e);
      }
      final dimNodes = <Map<String, dynamic>>[];
      final litNodes = <Map<String, dynamic>>[];
      for (final n in _paintNodes) {
        (focusSet.contains(n['id'].toString()) ? litNodes : dimNodes).add(n);
      }

      // Two-pass dim: the whole non-focused subgraph fades through ONE
      // saveLayer, so cached label painters stay color-agnostic. 0.30 keeps
      // dimmed silhouettes readable instead of vanishing into the background.
      final dimAlpha = ui.lerpDouble(1.0, 0.30, focusProgress)!;
      canvas.saveLayer(
        cullWorld,
        Paint()..color = Colors.white.withValues(alpha: dimAlpha),
      );
      _paintEdges(canvas, dimEdges, zoom, lodFancy, cullWorld, adaptive);
      _paintNodeDiscs(canvas, dimNodes, zoom, lodFancy, cullWorld, adaptive);
      _paintNodeLabels(canvas, dimNodes, zoom, cullWorld, adaptive);
      _paintEdgeLabels(canvas, dimEdges, zoom, lodFancy, cullWorld, adaptive);
      canvas.restore();

      _paintEdges(canvas, litEdges, zoom, lodFancy, cullWorld, adaptive);
      _paintNodeDiscs(canvas, litNodes, zoom, lodFancy, cullWorld, adaptive);
      _paintNodeLabels(canvas, litNodes, zoom, cullWorld, adaptive, litPass: true);
      _paintEdgeLabels(canvas, litEdges, zoom, lodFancy, cullWorld, adaptive);
    }

    _paintGlow(canvas, zoom, adaptive);

    canvas.restore();
  }

  /// 참조 노드 스파크: 확장 펄스 링 + 밝아진 코어 + 바깥으로 비산하는 파티클.
  /// 전부 _glowAnim.value(t)의 순수 함수 — 파티클 상태를 저장하지 않는다.
  void _paintGlow(Canvas canvas, double zoom, double adaptive) {
    if (!_glowAnim.isAnimating && _glowAnim.value == 0) return;
    final layout = _layout;
    if (layout == null || widget.glowNodeIds.isEmpty) return;
    final t = _glowAnim.value;
    if (t >= 1.0) return;
    final fade = 1.0 - t;

    for (final id in widget.glowNodeIds) {
      final wp = layout.positions[id];
      if (wp == null) continue;
      final tint = _nodeColors[id] ?? const Color(0xFF888888);
      final bright = Color.lerp(tint, Colors.white, 0.55)!;
      final r = (layout.nodeRadii[id] ?? kGraphNodeRadius) * adaptive;

      // 밝아진 코어 (블러 글로우).
      canvas.drawCircle(
        wp,
        r * (1.0 + 0.25 * fade),
        Paint()
          ..color = bright.withValues(alpha: 0.55 * fade)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.5),
      );

      // 확장 펄스 링.
      canvas.drawCircle(
        wp,
        r * (1.0 + 1.6 * t),
        Paint()
          ..color = bright.withValues(alpha: 0.8 * fade)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0 / zoom,
      );

      // 스파크 파티클 5개 — 노드 id 기반 결정적 각도로 바깥 비산.
      final rng = math.Random(id.hashCode);
      for (var i = 0; i < 5; i++) {
        final angle = rng.nextDouble() * 2 * math.pi;
        final speed = 1.4 + rng.nextDouble() * 1.2;
        final dist = r * (1.0 + speed * t);
        final p = wp + Offset(math.cos(angle) * dist, math.sin(angle) * dist);
        canvas.drawCircle(
          p,
          (2.5 * fade + 0.5) / zoom,
          Paint()..color = bright.withValues(alpha: 0.9 * fade),
        );
      }
    }
  }

  bool _edgeHighlighted(Map<String, dynamic> edge) {
    final srcId = edge['source_id'].toString();
    final tgtId = edge['target_id'].toString();
    final sel = widget.selectedNodeId;
    final nodeHit = sel != null && (srcId == sel || tgtId == sel);
    final hoverHit = _hoveredNodeId != null &&
        (srcId == _hoveredNodeId || tgtId == _hoveredNodeId);
    final edgeHit = edge['id'].toString() == widget.selectedEdgeId;
    return nodeHit || hoverHit || edgeHit;
  }

  void _paintEdges(
    Canvas canvas,
    List<Map<String, dynamic>> edges,
    double zoom,
    bool lodFancy,
    Rect cullWorld,
    double adaptive,
  ) {
    final layout = _layout!;
    for (final edge in edges) {
      final srcId = edge['source_id'].toString();
      final tgtId = edge['target_id'].toString();
      final src = layout.positions[srcId];
      final tgt = layout.positions[tgtId];
      if (src == null || tgt == null) continue;
      if (!cullWorld.contains(src) && !cullWorld.contains(tgt)) continue;

      final srcR = (layout.nodeRadii[srcId] ?? kGraphNodeRadius) * adaptive;
      final tgtR = (layout.nodeRadii[tgtId] ?? kGraphNodeRadius) * adaptive;
      final a = _rimPoint(src, tgt, srcR);
      final b = _rimPoint(tgt, src, tgtR);
      final ctrl = graphCurvedEdgeControl(a, b, bend: 0.2);

      final highlighted = _edgeHighlighted(edge);
      final srcColor = _nodeColors[srcId] ?? const Color(0xFF888888);
      final tgtColor = _nodeColors[tgtId] ?? srcColor;
      final blended = Color.lerp(srcColor, tgtColor, 0.4)!;
      final color = graphEdgeTintColor(blended, highlighted: highlighted);

      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);

      // Soft glow underlay — skipped at far zoom (LOD).
      if (lodFancy) {
        canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: highlighted ? 0.28 : 0.12)
            ..strokeWidth = (highlighted ? 4.0 : 2.5) / zoom
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 / zoom),
        );
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = (highlighted ? 1.5 : 1.0) / zoom
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _paintNodeDiscs(
    Canvas canvas,
    List<Map<String, dynamic>> nodes,
    double zoom,
    bool lodFancy,
    Rect cullWorld,
    double adaptive,
  ) {
    final layout = _layout!;
    for (final node in nodes) {
      final id = node['id'].toString();
      final wp = layout.positions[id];
      if (wp == null || !cullWorld.contains(wp)) continue;

      final color = _nodeColors[id] ?? const Color(0xFF888888);
      final selected = id == widget.selectedNodeId;
      final hovered = id == _hoveredNodeId;
      final isHub = id == _hubId;
      final dimmed = _dimmedIds.contains(id);
      final activeT = _activeT[id] ?? 0.0;
      final worldR = layout.nodeRadii[id] ?? kGraphNodeRadius;
      final r = worldR * adaptive * (1.0 + 0.1 * activeT);

      // Restrained glow: hubs and active nodes only — flat discs elsewhere
      // (the old per-node BoxShadow everywhere is why it felt heavy).
      if (lodFancy && !dimmed && (isHub || activeT > 0.05)) {
        canvas.drawCircle(
          wp,
          r * 1.15,
          Paint()
            ..color = color.withValues(alpha: 0.30 + 0.15 * activeT)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.35),
        );
      }

      final fillOpacity = graphNodeFillOpacity(
        isHub: isHub,
        selected: selected,
        hovered: hovered,
        dimmed: dimmed,
      );
      canvas.drawCircle(
        wp,
        r,
        Paint()..color = color.withValues(alpha: fillOpacity),
      );

      // Head-tier marker (Person/Source): thin outer ring — instantly readable
      // "이 노드가 진술의 귀속처".
      if (isStatementHeadType(node['type']?.toString())) {
        canvas.drawCircle(
          wp,
          r + 3.5,
          Paint()
            ..color = color.withValues(alpha: 0.55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      }

      final ringColor = _darkCanvas ? Colors.white : const Color(0xFF334155);
      if (selected) {
        canvas.drawCircle(
          wp,
          r,
          Paint()
            ..color = ringColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 / zoom,
        );
      } else if (hovered) {
        canvas.drawCircle(
          wp,
          r,
          Paint()
            ..color = ringColor.withValues(alpha: 0.75)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / zoom,
        );
      }
    }
  }

  void _paintNodeLabels(
    Canvas canvas,
    List<Map<String, dynamic>> nodes,
    double zoom,
    Rect cullWorld,
    double adaptive, {
    bool litPass = false,
  }) {
    if (!_showNodeLabels) return;
    final layout = _layout!;
    final adaptiveFade = _canvasSmoothstep(adaptive, 0.35, 0.75);
    if (adaptiveFade <= 0.02 && !litPass) return;
    for (final node in nodes) {
      final id = node['id'].toString();
      final wp = layout.positions[id];
      if (wp == null || !cullWorld.contains(wp)) continue;

      // Degree-priority LOD: hubs keep labels longest while zooming out.
      final degreeNorm =
          _maxDegree <= 0 ? 0.0 : (_degrees[id] ?? 0) / _maxDegree;
      var alpha = graphLabelLodOpacity(zoom, degreeNorm) * adaptiveFade;
      // Focused nodes keep readable labels regardless of zoom LOD.
      if (litPass) alpha = math.max(alpha, 0.85);
      if (_dimmedIds.contains(id)) alpha *= 0.45;
      if (alpha < 0.08) continue;

      final activeT = _activeT[id] ?? 0.0;
      final active = activeT > 0.5;
      final worldR = layout.nodeRadii[id] ?? kGraphNodeRadius;
      final r = worldR * adaptive * (1.0 + 0.1 * activeT);
      final label = graphShortLabel(nodeDisplayLabel(node), worldR);
      final fontSize = (worldR * 0.42).clamp(9.0, 15.0).toDouble();
      final baseWeight =
          (id == _hubId || active) ? FontWeight.w700 : FontWeight.w500;
      final importanceWeight = fontWeightForImportance(
        (node['importance_score'] as num?)?.toInt() ?? 0,
        _maxImportance,
      );
      final weight = baseWeight.value >= importanceWeight.value
          ? baseWeight
          : importanceWeight;

      final tp = _nodeLabelPainter(label, fontSize, weight, alpha, active);
      tp.paint(canvas, wp + Offset(-tp.width / 2, r + 4));
    }
  }

  TextPainter _nodeLabelPainter(
    String text,
    double fontSize,
    FontWeight weight,
    double alpha,
    bool active,
  ) {
    final alphaQ = ((alpha * 5).round().clamp(1, 5)) / 5;
    final key =
        'n|$text|${fontSize.toStringAsFixed(1)}|${weight.value}|$alphaQ|$active|$_darkCanvas';
    return _cachedPainter(key, () {
      final base = _darkCanvas
          ? (active ? Colors.white : AppColors.graphLabelLight)
          : (active ? const Color(0xFF0F172A) : AppColors.graphLabelDark);
      final color = base.withValues(alpha: alphaQ);
      // Halo the glyphs against the backdrop: dark scrim on the dark canvas,
      // light scrim on the light one.
      final shadow = _darkCanvas
          ? const Shadow(color: Color(0xE6000000), blurRadius: 6, offset: Offset(0, 1))
          : const Shadow(color: Color(0xCCFFFFFF), blurRadius: 5, offset: Offset(0, 1));
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: weight,
            height: 1.15,
            letterSpacing: 0.1,
            shadows: [shadow],
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '...',
      )..layout(maxWidth: math.max(48.0, fontSize * 10));
    });
  }

  void _paintEdgeLabels(
    Canvas canvas,
    List<Map<String, dynamic>> edges,
    double zoom,
    bool lodFancy,
    Rect cullWorld,
    double adaptive,
  ) {
    if (!_showEdgeLabels || !lodFancy || zoom < 0.3) return;
    final layout = _layout!;
    final baseAlpha = _canvasSmoothstep(zoom, 0.4, 0.75) * 0.9;
    for (final edge in edges) {
      final srcId = edge['source_id'].toString();
      final tgtId = edge['target_id'].toString();
      final src = layout.positions[srcId];
      final tgt = layout.positions[tgtId];
      if (src == null || tgt == null) continue;
      if (!cullWorld.contains(src) && !cullWorld.contains(tgt)) continue;

      final label = graphRelationDisplayLabel(edge['relation']?.toString() ?? '');
      if (label.isEmpty) continue;

      final highlighted = _edgeHighlighted(edge);
      final alpha = highlighted ? 1.0 : baseAlpha;
      if (alpha < 0.1) continue;

      final srcR = (layout.nodeRadii[srcId] ?? kGraphNodeRadius) * adaptive;
      final tgtR = (layout.nodeRadii[tgtId] ?? kGraphNodeRadius) * adaptive;
      final a = _rimPoint(src, tgt, srcR);
      final b = _rimPoint(tgt, src, tgtR);
      final ctrl = graphCurvedEdgeControl(a, b, bend: 0.2);
      final anchor = quadraticBezierPoint(a, ctrl, b, 0.5);
      final edgeId = edge['id'].toString();
      final side = edgeId.hashCode.isEven ? 1.0 : -1.0;
      final nudge = graphEdgeLabelOffset(a, b, magnitude: 8 * side);

      final srcColor = _nodeColors[srcId] ?? const Color(0xFF888888);
      final tgtColor = _nodeColors[tgtId] ?? srcColor;
      final tint = Color.lerp(srcColor, tgtColor, 0.4)!;

      final tp = _edgeLabelPainter(label, tint, alpha, highlighted);
      final topLeft =
          anchor + nudge + Offset(-tp.width / 2, -tp.height / 2);
      tp.paint(canvas, topLeft);
      _edgeLabelHits.add((rect: topLeft & tp.size, edge: edge));
    }
  }

  TextPainter _edgeLabelPainter(
    String text,
    Color tint,
    double alpha,
    bool highlighted,
  ) {
    final alphaQ = ((alpha * 5).round().clamp(1, 5)) / 5;
    final key = 'e|$text|${tint.hashCode}|$alphaQ|$highlighted|$_darkCanvas';
    return _cachedPainter(key, () {
      final highlightColor =
          _darkCanvas ? Colors.white : const Color(0xFF1E293B);
      final color = highlighted
          ? highlightColor.withValues(alpha: 0.95 * alphaQ)
          : tint.withValues(alpha: (_darkCanvas ? 0.7 : 0.95) * alphaQ);
      final shadows = _darkCanvas
          ? const [
              Shadow(color: Color(0xF0000000), blurRadius: 4, offset: Offset(0, 1)),
              Shadow(color: Color(0xC0000000), blurRadius: 8),
            ]
          : const [
              Shadow(color: Color(0xF0FFFFFF), blurRadius: 4, offset: Offset(0, 1)),
              Shadow(color: Color(0xC0FFFFFF), blurRadius: 8),
            ];
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: 8.0,
            height: 1.0,
            letterSpacing: 0.1,
            fontWeight: highlighted ? FontWeight.w600 : FontWeight.w400,
            fontStyle: FontStyle.italic,
            color: color,
            shadows: shadows,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    });
  }

  TextPainter _cachedPainter(String key, TextPainter Function() build) {
    final cached = _labelCache[key];
    if (cached != null) return cached;
    if (_labelCache.length > 4000) _clearLabelCache();
    return _labelCache[key] = build();
  }

  Color _speakerEncodedColor(
    Map<String, dynamic> node,
    Map<String, String> headIdx,
    Map<String, Color> headColors,
  ) {
    final type = node['type']?.toString();
    switch (graphFocusTier(type)) {
      case 'statement':
        final headId = headIdx[node['id'].toString()];
        return headColors[headId] ?? kConceptNeutralColor;
      case 'concept':
        return kConceptNeutralColor;
      default:
        return colorForType(type ?? '', widget.typeColors);
    }
  }

  int _tierPaintOrder(Map<String, dynamic> node) {
    switch (graphFocusTier(node['type']?.toString())) {
      case 'speaker':
        return 3; // painted last → on top
      case 'statement':
        return 2;
      case 'concept':
        return 1;
      default:
        return 0;
    }
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _darkCanvas = Theme.of(context).brightness == Brightness.dark;
    if (widget.nodes.isEmpty || _layout == null) {
      return ColoredBox(
        color: _canvasBackground,
        child: const Center(
          child: Text('노드 없음', style: TextStyle(color: AppColors.textMuted)),
        ),
      );
    }

    _visibleNodes = _effectiveNodes.where(_nodeMatchesFilter).toList();
    final visibleIds = _visibleNodes.map((n) => n['id'].toString()).toSet();
    _visibleEdges = _effectiveEdges.where((e) {
      return visibleIds.contains(e['source_id'].toString()) &&
          visibleIds.contains(e['target_id'].toString());
    }).toList();
    if (widget.hideHeadNodes) {
      // Speaker-to-Color: Statement는 귀속 head 색, Concept은 중립 회색.
      // 인덱스는 반드시 full 데이터로 — head 엣지는 effective에서 빠져 있다.
      final headColors = headColorById(widget.nodes);
      final headIdx = statementHeadIndex(widget.nodes, widget.edges);
      _nodeColors = {
        for (final n in _visibleNodes)
          n['id'].toString(): _speakerEncodedColor(n, headIdx, headColors),
      };
      final connected = <String>{};
      for (final e in _visibleEdges) {
        connected.add(e['source_id'].toString());
        connected.add(e['target_id'].toString());
      }
      _dimmedIds = {
        for (final n in _visibleNodes)
          if (!connected.contains(n['id'].toString())) n['id'].toString(),
      };
    } else {
      _nodeColors = {
        for (final n in _visibleNodes)
          n['id'].toString(): colorForType(
            n['type']?.toString() ?? '',
            widget.typeColors,
          ),
      };
      _dimmedIds = const {};
    }
    _maxImportance = _visibleNodes.fold<int>(
      0,
      (m, n) => math.max(m, (n['importance_score'] as num?)?.toInt() ?? 0),
    );
    // Tier paint order: concepts below, statements middle, speakers on top.
    _paintNodes = [
      for (var tier = 0; tier <= 3; tier++)
        ..._visibleNodes.where((n) => _tierPaintOrder(n) == tier),
    ];
    final selId = widget.selectedNodeId;
    if (selId != null) {
      final idx = _paintNodes.indexWhere((n) => n['id'].toString() == selId);
      if (idx >= 0 && idx != _paintNodes.length - 1) {
        _paintNodes.add(_paintNodes.removeAt(idx));
      }
    }

    final worldSize = _worldSize;

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
            ColoredBox(color: _canvasBackground),
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
                      onInteractionStart: (_) {
                        _cameraAnim.stop();
                        _notifyGraphPan(true);
                      },
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
                    // The whole scene — edges, nodes, labels — in ONE painter
                    // repainted via listenable (no per-frame setState).
                    Positioned.fill(
                      child: IgnorePointer(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _GraphScenePainter(this, _repaint),
                          ),
                        ),
                      ),
                    ),
                    // Hit surface: opaque ONLY over nodes / edge labels so
                    // InteractiveViewer keeps pan+pinch everywhere else —
                    // same layering semantics as the old per-node widgets.
                    Positioned.fill(
                      child: _GraphHitTestSurface(
                        hitPredicate: _hitPredicate,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onHover: _onSurfaceHover,
                          onExit: _onSurfaceExit,
                          child: Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: _onSurfaceDown,
                            onPointerMove: _onSurfaceMove,
                            onPointerUp: _onSurfaceUp,
                            onPointerCancel: _onSurfaceCancel,
                            child: const SizedBox.expand(),
                          ),
                        ),
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
              child: AnimatedBuilder(
                animation: _transformationController,
                builder: (context, _) => _ZoomControls(
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
                  // The scene is one CustomPainter repainted only via the
                  // merged `_repaint` listenable (ticker/frame/anim ticks) —
                  // shouldRepaint() can't see this toggle since it compares
                  // the same mutable state object every rebuild. Bump
                  // _frameNotifier so the label change actually redraws
                  // instead of waiting for the next incidental repaint.
                  onToggleNodeLabels: () => setState(() {
                    _showNodeLabels = !_showNodeLabels;
                    _frameNotifier.value++;
                  }),
                  onToggleEdgeLabels: () => setState(() {
                    _showEdgeLabels = !_showEdgeLabels;
                    _frameNotifier.value++;
                  }),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focusAnim.dispose();
    _cameraAnim.dispose();
    _glowAnim.dispose();
    _frameNotifier.dispose();
    _clearLabelCache();
    _transformationController.dispose();
    super.dispose();
  }
}

/// Paints the entire graph scene by delegating to the canvas state, which
/// owns all per-frame data. Repaints via [repaint] (transform, sim frames,
/// focus animation) without rebuilding any widgets.
class _GraphScenePainter extends CustomPainter {
  _GraphScenePainter(this.state, Listenable repaint) : super(repaint: repaint);

  final KnowledgeGraphCanvasState state;

  @override
  void paint(Canvas canvas, Size size) => state._paintScene(canvas, size);

  @override
  bool shouldRepaint(covariant _GraphScenePainter oldDelegate) =>
      oldDelegate.state != state;
}

/// Hit-test gate: transparent everywhere except over nodes and edge labels,
/// so pointer events fall through to InteractiveViewer (pan/pinch) on empty
/// canvas but reach the child Listener (drag/tap/hover) on interactive spots.
class _GraphHitTestSurface extends SingleChildRenderObjectWidget {
  const _GraphHitTestSurface({required this.hitPredicate, super.child});

  final bool Function(Offset local) hitPredicate;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGraphHitSurface(hitPredicate);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGraphHitSurface renderObject,
  ) {
    renderObject.hitPredicate = hitPredicate;
  }
}

class _RenderGraphHitSurface extends RenderProxyBox {
  _RenderGraphHitSurface(this.hitPredicate);

  bool Function(Offset local) hitPredicate;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    if (!hitPredicate(position)) return false;
    return super.hitTest(result, position: position);
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
    final shell = context.shell;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '$scalePercent%',
          style: TextStyle(
            fontSize: 10,
            color: shell.mutedText,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        _ZoomBtn(icon: Icons.add, tooltip: '확대', onTap: onZoomIn),
        _ZoomBtn(icon: Icons.remove, tooltip: '축소', onTap: onZoomOut),
        _ZoomBtn(icon: Icons.fit_screen, tooltip: '전체 보기', onTap: onFit),
        _ZoomBtn(icon: Icons.auto_awesome, tooltip: '레이아웃 재정렬', onTap: onRelayout),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: SizedBox(
              width: 38,
              child: Divider(height: 1, color: shell.panelBorder)),
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
    final shell = context.shell;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: active ? shell.subtleSurface : shell.panelBackground,
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
                  color: active ? AppColors.primary : shell.panelBorder,
                ),
              ),
              child: Icon(
                icon,
                color: active ? AppColors.primary : shell.mutedText,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 화자 숨김 모드 범례 항목: 숨겨진 head 이름 + 인코딩 색 + Statement 수.
typedef SpeakerLegendEntry = ({String name, Color color, int count, bool isSelf});

/// 화자 숨김 모드에서 좌상단에 뜨는 색상 범례. head 노드가 화면에서 사라진
/// 동안 "어떤 색이 누구인지"를 알려주는 유일한 단서.
class SpeakerColorLegendCard extends StatelessWidget {
  const SpeakerColorLegendCard({super.key, required this.entries});

  final List<SpeakerLegendEntry> entries;

  static const _maxRows = 8;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final shell = context.shell;
    final shown = entries.take(_maxRows).toList();
    final overflow = entries.length - shown.length;
    return Material(
      color: shell.panelBackground,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: shell.panelBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '화자 색상',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: shell.mutedText,
              ),
            ),
            const SizedBox(height: 6),
            ...shown.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: e.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: Text(
                        e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: shell.primaryText,
                          fontWeight: e.isSelf ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${e.count}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: shell.mutedText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (overflow > 0)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '외 $overflow명',
                  style: TextStyle(fontSize: 10.5, color: shell.mutedText),
                ),
              ),
          ],
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
    final shell = context.shell;
    final isAll = label == '전체';
    final bg = selected
        ? (isAll ? shell.subtleSurface : color.withValues(alpha: 0.18))
        : shell.panelBackground;
    final border = selected
        ? (isAll ? shell.mutedText : color)
        : shell.panelBorder;
    final textColor = selected ? shell.primaryText : shell.mutedText;

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
