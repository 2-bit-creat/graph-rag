import 'dart:math' as math;
import 'dart:ui';

/// Base node radius in world coordinates.
const kGraphNodeRadius = 28.0;

const kCollidePadding = 30.0;
const kMinLinkDistance = 180.0;
const kGraphMinHitDiameter = 24.0;

/// Force layout with category clustering + strict collide.
///
/// The constructor produces a settled batch layout (warm start). After that
/// the engine doubles as a live d3-style simulation: [tick] advances it one
/// frame, [reheat] injects energy, [pinnedId] pins the dragged node so the
/// springs pull its neighbors along.
class GraphLayoutEngine {
  GraphLayoutEngine({
    required this.nodeIds,
    required this.edges,
    required Map<String, double> nodeRadii,
    Map<String, String>? nodeTypes,
    Offset? center,
    Map<String, Offset>? initialPositions,
  })  : center = center ?? const Offset(500, 500),
        nodeRadii = Map<String, double>.from(nodeRadii),
        nodeTypes = nodeTypes ?? {} {
    final carried = <String>{};
    if (initialPositions != null) {
      for (final id in nodeIds) {
        final p = initialPositions[id];
        if (p != null) {
          positions[id] = p;
          carried.add(id);
        }
      }
    }
    // Incremental mode: most nodes survive a data refresh (e.g. an inspector
    // edit), so keep their positions and let the caller reheat the live sim
    // instead of scrambling the whole map with a fresh batch layout.
    seededIncrementally = carried.isNotEmpty && carried.length * 2 >= nodeIds.length;
    if (seededIncrementally) {
      _computeLayers();
      _seedIncremental(carried);
    } else {
      positions.clear();
      _initCategoryClusters();
      _computeLayers();
      runSimulation(
        iterations: nodeIds.length > 40 ? 170 : nodeIds.length > 15 ? 140 : 120,
      );
      enforceNonOverlap(maxPasses: 240);
      _normalizeToOrigin();
    }
  }

  final List<String> nodeIds;
  final List<({String source, String target})> edges;
  final Map<String, double> nodeRadii;
  final Map<String, String> nodeTypes;
  Offset center;

  final positions = <String, Offset>{};
  final layerByNodeId = <String, int>{};

  /// True when the constructor kept caller-provided positions instead of
  /// running a full batch layout.
  late final bool seededIncrementally;

  // Live simulation state (d3-force style).
  static const kAlphaMin = 0.015;
  final velocities = <String, Offset>{};
  double alpha = 0.0;
  double alphaTarget = 0.0;
  String? pinnedId;

  double _layoutRadius(String id) => nodeRadii[id] ?? kGraphNodeRadius;
  double _collideRadius(String id) => _layoutRadius(id) + kCollidePadding;
  double _minCenterDistance(String a, String b) =>
      _collideRadius(a) + _collideRadius(b);

  Map<String, int> get _degrees {
    final counts = <String, int>{};
    for (final id in nodeIds) {
      counts[id] = 0;
    }
    for (final e in edges) {
      if (counts.containsKey(e.source)) counts[e.source] = counts[e.source]! + 1;
      if (counts.containsKey(e.target)) counts[e.target] = counts[e.target]! + 1;
    }
    return counts;
  }

  Map<String, Set<String>> get _adjacency {
    final adj = <String, Set<String>>{};
    for (final id in nodeIds) {
      adj[id] = {};
    }
    for (final e in edges) {
      adj[e.source]?.add(e.target);
      adj[e.target]?.add(e.source);
    }
    return adj;
  }

  /// Seed nodes in angular sectors by entity type (color clusters).
  void _initCategoryClusters() {
    if (nodeIds.isEmpty) return;
    if (nodeIds.length == 1) {
      positions[nodeIds.first] = center;
      return;
    }

    final degrees = _degrees;
    final byType = <String, List<String>>{};
    for (final id in nodeIds) {
      final t = _normalizeType(nodeTypes[id]);
      byType.putIfAbsent(t, () => []).add(id);
    }

    final types = byType.keys.toList()..sort();
    final typeCount = types.length;
    final clusterSpread = 280.0 + nodeIds.length * 18.0;

    for (var ti = 0; ti < typeCount; ti++) {
      final ids = byType[types[ti]]!;
      ids.sort((a, b) => (degrees[b] ?? 0).compareTo(degrees[a] ?? 0));

      final sectorAngle = (ti / typeCount) * 2 * math.pi - math.pi / 2;
      final clusterCenter = center +
          Offset(
            math.cos(sectorAngle) * clusterSpread,
            math.sin(sectorAngle) * clusterSpread,
          );

      if (ids.length == 1) {
        positions[ids.first] = clusterCenter;
        continue;
      }

      positions[ids.first] = clusterCenter;
      final ringCount = ids.length - 1;
      final maxR = ids.map(_collideRadius).reduce(math.max);
      final ringRadius = math.max(
        maxR * 2.8 + 32,
        (ringCount * (maxR * 2 + 20)) / (2 * math.pi),
      );

      for (var i = 1; i < ids.length; i++) {
        final angle = sectorAngle + (i / ringCount) * 1.6 * math.pi - 0.8 * math.pi;
        positions[ids[i]] = clusterCenter +
            Offset(
              math.cos(angle) * ringRadius,
              math.sin(angle) * ringRadius,
            );
      }
    }

    // Pull global hub toward center for connected graphs.
    var hubId = nodeIds.first;
    for (final id in nodeIds) {
      final d = degrees[id] ?? 0;
      final hubD = degrees[hubId] ?? 0;
      if (d > hubD || (d == hubD && id.compareTo(hubId) < 0)) {
        hubId = id;
      }
    }
    final hubPos = positions[hubId]!;
    positions[hubId] = Offset.lerp(hubPos, center, 0.2)!;
  }

  String _normalizeType(String? raw) {
    if (raw == null || raw.isEmpty) return 'other';
    return raw.toLowerCase().trim();
  }

  /// Place nodes missing from [carried] near their first already-placed
  /// neighbor (falling back to the carried centroid) so a data refresh only
  /// introduces motion where the graph actually changed.
  void _seedIncremental(Set<String> carried) {
    final adj = _adjacency;
    final rnd = math.Random(nodeIds.length);
    var cx = 0.0;
    var cy = 0.0;
    for (final id in carried) {
      cx += positions[id]!.dx;
      cy += positions[id]!.dy;
    }
    final centroid = carried.isEmpty
        ? center
        : Offset(cx / carried.length, cy / carried.length);
    for (final id in nodeIds) {
      if (positions.containsKey(id)) continue;
      Offset? anchor;
      for (final n in adj[id] ?? const <String>{}) {
        if (positions.containsKey(n)) {
          anchor = positions[n];
          break;
        }
      }
      final base = anchor ?? centroid;
      final angle = rnd.nextDouble() * 2 * math.pi;
      final dist = anchor != null
          ? _collideRadius(id) * 2.4
          : 200.0 + rnd.nextDouble() * 120.0;
      positions[id] = base + Offset.fromDirection(angle, dist);
    }
    enforceNonOverlap(maxPasses: 12);
  }

  void _computeLayers() {
    if (nodeIds.isEmpty) return;
    final adj = _adjacency;
    final degrees = _degrees;

    var hubId = nodeIds.first;
    for (final id in nodeIds) {
      final d = degrees[id] ?? 0;
      final hubD = degrees[hubId] ?? 0;
      if (d > hubD || (d == hubD && id.compareTo(hubId) < 0)) {
        hubId = id;
      }
    }

    layerByNodeId.clear();
    layerByNodeId[hubId] = 0;
    final queue = <String>[hubId];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      final layer = layerByNodeId[id] ?? 0;
      for (final n in adj[id] ?? const {}) {
        if (layerByNodeId.containsKey(n)) continue;
        layerByNodeId[n] = layer + 1;
        queue.add(n);
      }
    }
    var maxLayer = layerByNodeId.values.fold<int>(0, math.max);
    for (final id in nodeIds) {
      layerByNodeId.putIfAbsent(id, () => maxLayer + 1);
      maxLayer = math.max(maxLayer, layerByNodeId[id]!);
    }
  }

  int get maxLayer =>
      layerByNodeId.values.fold<int>(0, (m, v) => math.max(m, v));

  void _applyCollide({double strength = 1.0}) {
    for (var i = 0; i < nodeIds.length; i++) {
      for (var j = i + 1; j < nodeIds.length; j++) {
        final a = nodeIds[i];
        final b = nodeIds[j];
        final pa = positions[a]!;
        final pb = positions[b]!;
        var delta = pb - pa;
        var dist = delta.distance;
        final minDist = _minCenterDistance(a, b);

        if (dist < 1e-6) {
          final angle = (i - j) * 0.9 + 0.4;
          delta = Offset(math.cos(angle), math.sin(angle)) * minDist;
          positions[a] = center - delta * 0.5;
          positions[b] = center + delta * 0.5;
          continue;
        }

        if (dist >= minDist) continue;

        // The pinned (dragged) node must stay under the pointer, so its
        // overlap partner absorbs the full separation.
        final overlap = ((minDist - dist) / dist) * strength * 0.5;
        if (a == pinnedId) {
          positions[b] = Offset(pb.dx + delta.dx * overlap * 2, pb.dy + delta.dy * overlap * 2);
        } else if (b == pinnedId) {
          positions[a] = Offset(pa.dx - delta.dx * overlap * 2, pa.dy - delta.dy * overlap * 2);
        } else {
          positions[a] = Offset(pa.dx - delta.dx * overlap, pa.dy - delta.dy * overlap);
          positions[b] = Offset(pb.dx + delta.dx * overlap, pb.dy + delta.dy * overlap);
        }
      }
    }
  }

  void _applyClusterForce({required double alpha, double strength = 0.04}) {
    final byType = <String, List<String>>{};
    for (final id in nodeIds) {
      final t = _normalizeType(nodeTypes[id]);
      byType.putIfAbsent(t, () => []).add(id);
    }

    for (final entry in byType.entries) {
      if (entry.value.length < 2) continue;
      var cx = 0.0;
      var cy = 0.0;
      for (final id in entry.value) {
        cx += positions[id]!.dx;
        cy += positions[id]!.dy;
      }
      cx /= entry.value.length;
      cy /= entry.value.length;
      final centroid = Offset(cx, cy);

      for (final id in entry.value) {
        final delta = centroid - positions[id]!;
        positions[id] = positions[id]! + delta * strength * alpha;
      }
    }
  }

  void runSimulation({int iterations = 240}) {
    if (nodeIds.length < 2) return;

    final velocities = {for (final id in nodeIds) id: Offset.zero};
    const linkStrength = 0.08;
    const repulsion = 12000.0;
    const damping = 0.62;
    const centerPull = 0.0012;

    for (var iter = 0; iter < iterations; iter++) {
      final alpha = math.pow(1.0 - iter / iterations, 0.75).toDouble();
      final forces = {for (final id in nodeIds) id: Offset.zero};

      for (final e in edges) {
        if (!positions.containsKey(e.source) || !positions.containsKey(e.target)) {
          continue;
        }
        final delta = positions[e.target]! - positions[e.source]!;
        final dist = math.max(delta.distance, 1.0);
        final ideal = math.max(
          kMinLinkDistance,
          _collideRadius(e.source) + _collideRadius(e.target) + 50,
        );
        final stretch = dist - ideal;
        final force = delta / dist * stretch * linkStrength * alpha;
        forces[e.source] = forces[e.source]! + force;
        forces[e.target] = forces[e.target]! - force;
      }

      for (var i = 0; i < nodeIds.length; i++) {
        for (var j = i + 1; j < nodeIds.length; j++) {
          final a = nodeIds[i];
          final b = nodeIds[j];
          final delta = positions[a]! - positions[b]!;
          final dist = math.max(delta.distance, 1.0);
          final force = repulsion * alpha / (dist * dist);
          final dir = delta / dist;
          forces[a] = forces[a]! + dir * force;
          forces[b] = forces[b]! - dir * force;
        }
      }

      for (final id in nodeIds) {
        final toCenter = center - positions[id]!;
        forces[id] = forces[id]! + toCenter * centerPull * alpha;
        velocities[id] = (velocities[id]! + forces[id]!) * damping;
        positions[id] = positions[id]! + velocities[id]!;
      }

      _applyClusterForce(alpha: alpha, strength: 0.012 * alpha);
      for (var c = 0; c < 5; c++) {
        _applyCollide(strength: 1.0);
      }
    }
  }

  /// Injects energy into the live simulation (drag, release, data refresh).
  void reheat([double a = 0.3]) {
    alpha = math.max(alpha, a);
  }

  /// Advances the live simulation by [dt] seconds.
  ///
  /// Returns false once the graph has settled (low energy AND negligible
  /// velocity) so the caller can stop its ticker. Forces mirror the batch
  /// pass but are alpha-scaled the d3 way: alpha eases toward [alphaTarget]
  /// (held up while dragging), and a released node keeps its velocity and
  /// coasts under damping — that decay is the visible inertia.
  bool tick(double dt) {
    if (nodeIds.length < 2) {
      alpha = 0.0;
      return false;
    }

    alpha += (alphaTarget - alpha) * 0.06;
    if (pinnedId == null && alphaTarget < kAlphaMin && alpha < kAlphaMin) {
      var maxSq = 0.0;
      for (final v in velocities.values) {
        maxSq = math.max(maxSq, v.distanceSquared);
      }
      if (maxSq < 0.0016) {
        alpha = 0.0;
        for (final id in velocities.keys.toList()) {
          velocities[id] = Offset.zero;
        }
        return false;
      }
    }

    // Normalize to 60fps frames so a slow frame doesn't slow the physics.
    final step = (dt * 60.0).clamp(0.5, 2.0);
    const linkStrength = 0.12;
    const repulsion = 12000.0;
    const damping = 0.85;
    const centerPull = 0.0012;

    final forces = {for (final id in nodeIds) id: Offset.zero};

    for (final e in edges) {
      if (!positions.containsKey(e.source) || !positions.containsKey(e.target)) {
        continue;
      }
      final delta = positions[e.target]! - positions[e.source]!;
      final dist = math.max(delta.distance, 1.0);
      final ideal = math.max(
        kMinLinkDistance,
        _collideRadius(e.source) + _collideRadius(e.target) + 50,
      );
      final force = delta / dist * ((dist - ideal) * linkStrength * alpha);
      forces[e.source] = forces[e.source]! + force;
      forces[e.target] = forces[e.target]! - force;
    }

    if (alpha > 0.002) {
      for (var i = 0; i < nodeIds.length; i++) {
        for (var j = i + 1; j < nodeIds.length; j++) {
          final a = nodeIds[i];
          final b = nodeIds[j];
          final delta = positions[a]! - positions[b]!;
          final dist = math.max(delta.distance, 1.0);
          final force = repulsion * alpha / (dist * dist);
          final dir = delta / dist;
          forces[a] = forces[a]! + dir * force;
          forces[b] = forces[b]! - dir * force;
        }
      }
      for (final id in nodeIds) {
        forces[id] = forces[id]! + (center - positions[id]!) * (centerPull * alpha);
      }
    }

    final dampingStep = math.pow(damping, step).toDouble();
    for (final id in nodeIds) {
      if (id == pinnedId) {
        velocities[id] = Offset.zero;
        continue;
      }
      var v = ((velocities[id] ?? Offset.zero) + forces[id]! * step) * dampingStep;
      final speed = v.distance;
      if (speed > 60) v = v * (60 / speed);
      velocities[id] = v;
      positions[id] = positions[id]! + v * step;
    }

    if (alpha > 0.002) {
      _applyClusterForce(alpha: alpha, strength: 0.008 * alpha);
    }
    // Soft positional collide instead of hard projection: hard projection
    // every frame looks jittery while the sim is in motion.
    _applyCollide(strength: 0.35);
    return true;
  }

  void enforceNonOverlap({int maxPasses = 240}) {
    for (var pass = 0; pass < maxPasses; pass++) {
      var overlaps = 0;
      for (var i = 0; i < nodeIds.length; i++) {
        for (var j = i + 1; j < nodeIds.length; j++) {
          final a = nodeIds[i];
          final b = nodeIds[j];
          final pa = positions[a]!;
          final pb = positions[b]!;
          final delta = pb - pa;
          var dist = delta.distance;
          final minDist = _minCenterDistance(a, b);

          if (dist < 1e-6) {
            final nudge = Offset.fromDirection((i - j) * 0.71 + 0.2, minDist);
            positions[a] = pa - nudge * 0.5;
            positions[b] = pb + nudge * 0.5;
            overlaps++;
            continue;
          }

          if (dist >= minDist - 0.01) continue;

          overlaps++;
          final push = (minDist - dist) / dist;
          positions[a] = Offset(pa.dx - delta.dx * push * 0.5, pa.dy - delta.dy * push * 0.5);
          positions[b] = Offset(pb.dx + delta.dx * push * 0.5, pb.dy + delta.dy * push * 0.5);
        }
      }
      if (overlaps == 0) return;
    }
  }

  void resolveCollisionsAround(String nodeId, {int passes = 48}) {
    if (!positions.containsKey(nodeId)) return;
    for (var pass = 0; pass < passes; pass++) {
      _applyCollide(strength: 1.0);
    }
    enforceNonOverlap(maxPasses: 48);
  }

  void _normalizeToOrigin({double margin = 140}) {
    if (positions.isEmpty) return;
    var minX = double.infinity;
    var minY = double.infinity;
    for (final p in positions.values) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
    }
    final shift = Offset(margin - minX, margin - minY);
    for (final id in nodeIds) {
      positions[id] = positions[id]! + shift;
    }
    center = center + shift;
  }

  Rect boundingRect({double padding = 120}) {
    if (positions.isEmpty) {
      return const Rect.fromLTWH(0, 0, 480, 360);
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final entry in positions.entries) {
      final r = _collideRadius(entry.key);
      minX = math.min(minX, entry.value.dx - r);
      minY = math.min(minY, entry.value.dy - r);
      maxX = math.max(maxX, entry.value.dx + r);
      maxY = math.max(maxY, entry.value.dy + r);
    }
    return Rect.fromLTRB(
      minX - padding,
      minY - padding,
      maxX + padding,
      maxY + padding,
    );
  }

  void focusOnNode(String nodeId, {double radius = 280}) {
    if (!positions.containsKey(nodeId)) return;
    final origin = positions[nodeId]!;
    for (final id in nodeIds) {
      if (id == nodeId) continue;
      final delta = positions[id]! - origin;
      if (delta.distance > radius * 3) {
        positions[id] = origin + Offset.fromDirection(delta.direction, radius * 2.2);
      }
    }
    enforceNonOverlap(maxPasses: 64);
  }
}

double graphLayoutRadiusForNode({
  required int degree,
  required int maxDegree,
  required String name,
  int totalNodes = 20,
  String? type,
}) {
  return graphNodeRadiusForDegree(degree, maxDegree, totalNodes: totalNodes) *
      graphTierRadiusMultiplier(type);
}

/// Speaker → Statement → Concept 3-tier size bias: speakers are few and
/// anchor-like, statements are plentiful connective tissue.
double graphTierRadiusMultiplier(String? type) {
  if (isStatementHeadType(type)) return 1.2;
  final t = canonicalEntityType(type ?? '').toLowerCase();
  if (t == 'statement') return 0.85;
  return 1.0;
}

/// Hub nodes larger; small graphs use smaller radii to reduce world crowding.
double graphNodeRadiusForDegree(int degree, int maxDegree, {int totalNodes = 20}) {
  final compact = totalNodes <= 18;
  final minR = compact ? 13.0 : 18.0;
  final maxR = compact ? 26.0 : 38.0;
  if (degree <= 1 || maxDegree <= 1) return compact ? 15.0 : 22.0;
  final t = math.sqrt((degree / maxDegree).clamp(0.0, 1.0));
  return minR + (maxR - minR) * t;
}

/// Bolder label for nodes with a higher cumulative LLM-assigned importance
/// (Node.importance_score — see backend crud._get_or_create_node). Independent
/// of degree-based sizing: a concept can be small (few mentions) but weighty
/// (each mention scored high), or vice versa.
FontWeight fontWeightForImportance(int score, int maxScore) {
  if (maxScore <= 0 || score <= 0) return FontWeight.w500;
  final t = (score / maxScore).clamp(0.0, 1.0);
  if (t >= 0.8) return FontWeight.w700;
  if (t >= 0.55) return FontWeight.w700;
  if (t >= 0.3) return FontWeight.w700;
  if (t >= 0.1) return FontWeight.w600;
  return FontWeight.w500;
}

double _smoothstep(double x, double lo, double hi) {
  if (x <= lo) return 0;
  if (x >= hi) return 1;
  final t = (x - lo) / (hi - lo);
  return t * t * (3 - 2 * t);
}

double graphScreenRadius(double worldRadius, double zoom, {double adaptiveScale = 1.0}) {
  return worldRadius * zoom * adaptiveScale;
}

double graphNameTextOpacity(double zoom) => _smoothstep(zoom, 0.15, 0.38);

/// Degree-priority label LOD: hub labels survive further zoom-out, leaf
/// labels fade first (Obsidian behavior). [degreeNorm] ∈ [0, 1].
double graphLabelLodOpacity(double zoom, double degreeNorm) {
  final t = degreeNorm.clamp(0.0, 1.0);
  final lo = 0.18 - 0.10 * t;
  final hi = 0.42 - 0.20 * t;
  return _smoothstep(zoom, lo, hi);
}

double graphTypeTextOpacity(double zoom) => _smoothstep(zoom, 0.9, 1.2);

double graphNodeFillOpacity({
  required bool isHub,
  bool dimmed = false,
  bool selected = false,
  bool hovered = false,
}) {
  var opacity = isHub ? 1.0 : 0.94;
  if (hovered || selected) opacity = 1.0;
  if (dimmed) opacity *= 0.6;
  return opacity;
}

/// Truncates by the node's WORLD radius (zoom-independent) so cached label
/// layouts never thrash while zooming.
String graphShortLabel(String name, double worldRadius) {
  final n = name.trim();
  if (n.isEmpty) return '?';
  final maxChars = (worldRadius * 0.55).round().clamp(6, 20);
  if (n.length <= maxChars) return n;
  return '${n.substring(0, maxChars - 1)}…';
}

String formatRelationLabel(String relation) {
  final r = relation.trim();
  if (r.isEmpty) return '';
  return r
      .replaceAll(RegExp(r'[\s\-]+'), '_')
      .replaceAll(RegExp(r'[^a-zA-Z0-9_가-힣]'), '')
      .toUpperCase();
}

/// Human-readable relation text for on-canvas edge chips.
String graphRelationDisplayLabel(String relation, {int maxLen = 11}) {
  final r = relation.trim();
  if (r.isEmpty) return '';
  var display = r.replaceAll(RegExp(r'\s+'), ' ');
  if (display.length <= maxLen) return display;
  return '${display.substring(0, maxLen - 1)}…';
}

double graphEdgeLabelOpacity(double zoom, {bool highlighted = false}) {
  if (highlighted) return 1.0;
  return _smoothstep(zoom, 0.22, 0.48) * 0.92 + 0.08;
}

double graphEdgeLabelFontSize(double zoom) =>
    (7.5 * zoom.clamp(0.55, 1.25)).clamp(6.5, 9.0);

Color graphRelationAccentColor(RelationSentiment sentiment, Color edgeTint) {
  switch (sentiment) {
    case RelationSentiment.positive:
      return const Color(0xFF3DD6C3);
    case RelationSentiment.negative:
      return const Color(0xFFFF7A7A);
    case RelationSentiment.neutral:
      return edgeTint.withValues(alpha: 0.75);
  }
}

/// Point on a quadratic Bézier at [t] ∈ [0, 1].
Offset quadraticBezierPoint(Offset a, Offset ctrl, Offset b, double t) {
  final u = 1 - t;
  return Offset(
    u * u * a.dx + 2 * u * t * ctrl.dx + t * t * b.dx,
    u * u * a.dy + 2 * u * t * ctrl.dy + t * t * b.dy,
  );
}

Color parseHexColor(String hex, {Color fallback = const Color(0xFF6366F1)}) {
  try {
    final h = hex.replaceFirst('#', '');
    if (h.length == 6) return Color(int.parse('FF$h', radix: 16));
    if (h.length == 8) return Color(int.parse(h, radix: 16));
  } catch (_) {}
  return fallback;
}

/// Vibrant palette tuned for dark canvas (reference graph style).
const _semanticTypeColors = <String, Color>{
  'chunk': Color(0xFF6366F1),
  'speaker': Color(0xFFFF8C42),
  'vocab': Color(0xFF3DD6C3),
  // 3-노드 구조 핵심 색상: Person=주황 / Statement=보라 / Concept=파랑.
  // statement 키가 없으면 fallback 팔레트의 파랑(0xFF5B9DFF)으로 떨어져 concept과
  // 색이 겹쳐 보이므로 반드시 명시적으로 구분된 색을 지정한다.
  'statement': Color(0xFFB07BFF),
  'concept': Color(0xFF5B9DFF),
  'person': Color(0xFFFF8C42),
  'individual': Color(0xFFFF8C42),
  // Source(외부 출처) head: person과 같은 warm 계열이되 구분되는 골드 —
  // "귀속처 계층은 따뜻한 색" 규칙 유지, 사람/출처는 색으로 구분.
  'source': Color(0xFFFFC53D),
  // Identity(정체성): 사람인지 확정되지 않은 개체(반려동물·단체 등). 정체성
  // 계층이라 warm 계열(살구/코랄)로 person·source와 묶되 구분되는 톤.
  'identity': Color(0xFFF07B5B),
  'organization': Color(0xFF5BABFF),
  'company': Color(0xFF5BABFF),
  'topic': Color(0xFF5B9DFF),
  'activity': Color(0xFF3DD6C3),
  'event': Color(0xFFE8B86D),
  'beverage': Color(0xFF5CD97A),
  'food': Color(0xFF7AE85A),
  'object': Color(0xFFC77DFF),
  'place': Color(0xFFFF6B9D),
  'location': Color(0xFFFF6B9D),
  'product': Color(0xFFFFB84D),
  'technology': Color(0xFF5CE0A0),
  'sector': Color(0xFFFF5C5C),
  'market': Color(0xFFFF7EB6),
  'asset': Color(0xFF4DB8FF),
};

Map<String, Color> buildTypeColorMap(List<dynamic>? entityTypes) {
  final map = <String, Color>{};
  if (entityTypes == null) return map;
  for (final raw in entityTypes) {
    if (raw is! Map) continue;
    final name = raw['name']?.toString();
    final color = raw['color']?.toString();
    if (name != null && color != null) map[name] = parseHexColor(color);
  }
  return map;
}

Map<String, Color> buildDynamicTypeColorMap(Iterable<String> types) {
  const fallbackPalette = [
    Color(0xFFFF8C42),
    Color(0xFF5B9DFF),
    Color(0xFF3DD6C3),
    Color(0xFFC77DFF),
    Color(0xFF5CD97A),
    Color(0xFFE8B86D),
    Color(0xFFFF6B9D),
    Color(0xFF5BABFF),
    Color(0xFFFFB84D),
    Color(0xFF5CE0A0),
  ];
  final map = <String, Color>{};
  var i = 0;
  for (final type in types) {
    if (type.isEmpty) continue;
    final key = type.toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');
    map[type] = _semanticTypeColors[key] ?? fallbackPalette[i % fallbackPalette.length];
    i++;
  }
  return map;
}

Map<String, Map<String, dynamic>> buildNodeById(
  List<Map<String, dynamic>> nodes,
) {
  return Map<String, Map<String, dynamic>>.fromEntries(
    nodes.map((n) => MapEntry(n['id'].toString(), n)),
  );
}

List<Map<String, dynamic>> entityTypesFromNodes(List<Map<String, dynamic>> nodes) {
  final counts = <String, int>{};
  final display = <String, String>{};
  for (final n in nodes) {
    final raw = n['type']?.toString().trim();
    if (raw == null || raw.isEmpty) continue;
    final canonical = canonicalEntityType(raw);
    final key = canonical.toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
    display[key] = canonical;
  }
  final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return sorted
      .map((e) => {'name': display[e.key] ?? e.key, 'count': e.value})
      .toList();
}

String canonicalEntityType(String raw) {
  final parts = raw.split(RegExp(r'[\s_\-]+')).where((p) => p.isNotEmpty);
  return parts.map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase()).join();
}

bool entityTypeMatches(String? nodeType, String filter) {
  if (filter == '전체') return true;
  if (nodeType == null) return false;
  return canonicalEntityType(nodeType).toLowerCase() ==
      canonicalEntityType(filter).toLowerCase();
}

Color colorForType(String type, Map<String, Color> typeColors) {
  if (typeColors.containsKey(type)) return typeColors[type]!;
  final lower = type.toLowerCase();
  for (final entry in typeColors.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  final normalized = lower.replaceAll(RegExp(r'[\s\-]+'), '_');
  return _semanticTypeColors[normalized] ?? parseHexColor('#64748b');
}

Set<String> neighborIds(String nodeId, List<Map<String, dynamic>> edges) {
  final ids = <String>{nodeId};
  for (final e in edges) {
    final s = e['source_id'].toString();
    final t = e['target_id'].toString();
    if (s == nodeId) ids.add(t);
    if (t == nodeId) ids.add(s);
  }
  return ids;
}

/// Focus tier of a node within the Speaker → Statement → Concept chain.
String graphFocusTier(String? type) {
  // Source(외부 출처) heads sit in the speaker tier: 2-hop 포커스가
  // Source → Statement → Concept 체인으로 똑같이 동작해야 한다.
  if (isStatementHeadType(type)) return 'speaker';
  final t = canonicalEntityType(type ?? '').toLowerCase();
  if (t == 'statement') return 'statement';
  if (t == 'concept' || t == 'topic') return 'concept';
  return 'other';
}

/// Tier-aware focus set exploiting the Speaker → Statement → Concept chain:
/// - Concept: its Statements (1 hop) + those Statements' Speakers (2nd hop)
/// - Speaker: their Statements + those Statements' Concepts
/// - Statement / other: plain 1-hop neighbors
Set<String> tierFocusIds(
  String nodeId,
  Map<String, String> typeById,
  List<Map<String, dynamic>> edges,
) {
  final tier = graphFocusTier(typeById[nodeId]);
  if (tier != 'speaker' && tier != 'concept') {
    return neighborIds(nodeId, edges);
  }
  final farTier = tier == 'concept' ? 'speaker' : 'concept';
  final result = <String>{nodeId};
  final statements = <String>{};
  for (final e in edges) {
    final s = e['source_id'].toString();
    final t = e['target_id'].toString();
    String? other;
    if (s == nodeId) other = t;
    if (t == nodeId) other = s;
    if (other == null) continue;
    result.add(other);
    if (graphFocusTier(typeById[other]) == 'statement') statements.add(other);
  }
  for (final e in edges) {
    final s = e['source_id'].toString();
    final t = e['target_id'].toString();
    if (statements.contains(s) && graphFocusTier(typeById[t]) == farTier) {
      result.add(t);
    }
    if (statements.contains(t) && graphFocusTier(typeById[s]) == farTier) {
      result.add(s);
    }
  }
  return result;
}

enum RelationSentiment { positive, negative, neutral }

final _positiveRelationPattern = RegExp(
  r'like|love|enjoy|help|friend|good|happy|met|work_with|colleague|'
  r'좋|친|사랑|도움|함께|만남|협력|동료|칭찬|성공|기쁨|신뢰|존경|응원',
  caseSensitive: false,
);

final _negativeRelationPattern = RegExp(
  r'hate|dislike|conflict|argue|bad|angry|fired|quit|problem|against|'
  r'싫|미움|싸움|갈등|문제|퇴사|해고|분쟁|불만|실망|비난|거부|적대',
  caseSensitive: false,
);

RelationSentiment classifyRelationSentiment(String relation) {
  final r = relation.trim();
  if (r.isEmpty) return RelationSentiment.neutral;
  if (_negativeRelationPattern.hasMatch(r)) return RelationSentiment.negative;
  if (_positiveRelationPattern.hasMatch(r)) return RelationSentiment.positive;
  return RelationSentiment.neutral;
}

Color graphEdgeTintColor(Color sourceColor, {bool highlighted = false, bool dimmed = false}) {
  if (dimmed) return sourceColor.withValues(alpha: 0.06);
  if (highlighted) return sourceColor.withValues(alpha: 0.72);
  return sourceColor.withValues(alpha: 0.38);
}

Map<String, int> degreeByNodeId(List<Map<String, dynamic>> edges) {
  final counts = <String, int>{};
  for (final e in edges) {
    final s = e['source_id'].toString();
    final t = e['target_id'].toString();
    counts[s] = (counts[s] ?? 0) + 1;
    counts[t] = (counts[t] ?? 0) + 1;
  }
  return counts;
}

bool isPersonLikeType(String? raw) => isSpeakerLikeType(raw);

bool isSpeakerLikeType(String? raw) {
  final t = canonicalEntityType(raw ?? '').toLowerCase();
  return t == 'speaker' || t == 'person' || t == 'individual';
}

/// Statement head-node types (Speaker → Statement → Concept 체인의 최상위 계층).
/// Source(외부 출처: 매체·기관·AI)는 head지만 사람이 아니므로 화자 피커에는
/// 절대 노출되지 않는다 — isSpeakerLikeType에 포함하지 말 것.
bool isStatementHeadType(String? raw) {
  if (isSpeakerLikeType(raw)) return true;
  return canonicalEntityType(raw ?? '').toLowerCase() == 'source';
}

// ---------------------------------------------------------------------------
// 화자 숨김(Speaker-to-Color) 모드
//
// head(화자·출처) 노드를 물리 데이터에서 제거하면 Statement가 귀속 정보를
// 잃으므로, 그 공백을 Statement 노드 색상으로 인코딩한다. 색은 head id 기반으로
// 결정적이어야 한다 — 세션·재빌드가 바뀌어도 같은 화자는 항상 같은 색.
// ---------------------------------------------------------------------------

/// '나'(self) head 고정 색. concept 기본색과 겹치지 않도록 숨김 모드에서
/// concept은 [kConceptNeutralColor]로 강등된다.
const kSelfHeadColor = Color(0xFF4D9DFF);

/// 숨김 모드의 Concept 중립색: Statement의 화자색이 유일한 색 채널이 되도록
/// 채도를 뺀 회색 계열.
const kConceptNeutralColor = Color(0xFF9AA3B2);

/// self 이외 head에 배정되는 팔레트 (파랑 계열은 self 전용이라 제외).
const kHeadColorPalette = <Color>[
  Color(0xFF5CD97A), // green
  Color(0xFFFF6B9D), // pink
  Color(0xFFFF8C42), // orange
  Color(0xFF3DD6C3), // teal
  Color(0xFFB07BFF), // purple
  Color(0xFFFFC53D), // gold
  Color(0xFFFF7A7A), // coral
  Color(0xFF5CE0A0), // mint
];

bool isSelfNode(Map<String, dynamic> node) {
  if (node['is_self'] == true) return true;
  // 구버전 백엔드 fallback: is_self 미노출 시 이름으로 판별.
  return isSpeakerLikeType(node['type']?.toString()) &&
      node['name']?.toString().trim() == '나';
}

/// FNV-1a — String.hashCode는 플랫폼별로 달라질 수 있어 직접 구현.
int _stableStringHash(String s) {
  var h = 0x811C9DC5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0x7FFFFFFF;
  }
  return h;
}

/// headId → 인코딩 색. self는 고정 파랑, 나머지는 id 해시로 팔레트에서 배정.
/// 해시 충돌은 id 정렬 순서(불변)로 선형 탐사해 해소하므로 배정이 안정적이다.
Map<String, Color> headColorById(List<Map<String, dynamic>> nodes) {
  final heads = [
    for (final n in nodes)
      if (isStatementHeadType(n['type']?.toString())) n,
  ]..sort((a, b) => a['id'].toString().compareTo(b['id'].toString()));

  final map = <String, Color>{};
  final used = <int>{};
  for (final n in heads) {
    final id = n['id'].toString();
    if (isSelfNode(n)) {
      map[id] = kSelfHeadColor;
      continue;
    }
    var idx = _stableStringHash(id) % kHeadColorPalette.length;
    if (used.length < kHeadColorPalette.length) {
      while (used.contains(idx)) {
        idx = (idx + 1) % kHeadColorPalette.length;
      }
    }
    used.add(idx);
    map[id] = kHeadColorPalette[idx];
  }
  return map;
}

/// statementId → 귀속 head(화자/출처) id. 숨김 모드에서 head 엣지는 물리
/// 데이터에서 빠지므로 반드시 필터링 전 full 엣지 목록으로 만들어야 한다.
Map<String, String> statementHeadIndex(
  List<Map<String, dynamic>> nodes,
  List<Map<String, dynamic>> edges,
) {
  final typeById = {
    for (final n in nodes) n['id'].toString(): n['type']?.toString() ?? '',
  };
  bool isStmt(String? t) =>
      canonicalEntityType(t ?? '').toLowerCase() == 'statement';
  final map = <String, String>{};
  for (final e in edges) {
    final s = e['source_id'].toString();
    final t = e['target_id'].toString();
    if (isStatementHeadType(typeById[s]) && isStmt(typeById[t])) {
      map[t] = s;
    } else if (isStatementHeadType(typeById[t]) && isStmt(typeById[s])) {
      map[s] = t;
    }
  }
  return map;
}

/// [statementId]에 연결된 head 노드 (없으면 null).
Map<String, dynamic>? statementHeadNode(
  String statementId,
  List<Map<String, dynamic>> edges,
  Map<String, Map<String, dynamic>> nodeById,
) {
  for (final e in edges) {
    final s = e['source_id'].toString();
    final t = e['target_id'].toString();
    String? other;
    if (s == statementId) other = t;
    if (t == statementId) other = s;
    if (other == null) continue;
    final n = nodeById[other];
    if (n != null && isStatementHeadType(n['type']?.toString())) return n;
  }
  return null;
}

/// Display label for graph nodes (Chunk uses display_title when available).
String nodeDisplayLabel(Map<String, dynamic> node) {
  final type = canonicalEntityType(node['type']?.toString() ?? '').toLowerCase();
  if (type == 'chunk') {
    return node['display_title']?.toString() ??
        node['name']?.toString() ??
        '';
  }
  return node['name']?.toString() ?? '';
}

Offset graphEdgeLabelOffset(Offset a, Offset b, {double magnitude = 14}) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-3) return Offset.zero;
  return Offset(-dy / len * magnitude, dx / len * magnitude);
}

/// Quadratic bezier control point for curved organic edges.
Offset graphCurvedEdgeControl(Offset a, Offset b, {double bend = 0.18}) {
  final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-3) return mid;
  return mid + Offset(-dy / len * len * bend, dx / len * len * bend);
}
