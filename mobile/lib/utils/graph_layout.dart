import 'dart:math' as math;
import 'dart:ui';

/// Base node radius in world coordinates.
const kGraphNodeRadius = 28.0;

const kCollidePadding = 30.0;
const kMinLinkDistance = 180.0;
const kGraphMinHitDiameter = 24.0;

/// Force layout with category clustering + strict collide.
class GraphLayoutEngine {
  GraphLayoutEngine({
    required this.nodeIds,
    required this.edges,
    required Map<String, double> nodeRadii,
    Map<String, String>? nodeTypes,
    Offset? center,
  })  : center = center ?? const Offset(500, 500),
        nodeRadii = Map<String, double>.from(nodeRadii),
        nodeTypes = nodeTypes ?? {} {
    _initCategoryClusters();
    _computeLayers();
    runSimulation(
      iterations: nodeIds.length > 40 ? 340 : nodeIds.length > 15 ? 280 : 240,
    );
    enforceNonOverlap(maxPasses: 240);
    _normalizeToOrigin();
  }

  final List<String> nodeIds;
  final List<({String source, String target})> edges;
  final Map<String, double> nodeRadii;
  final Map<String, String> nodeTypes;
  Offset center;

  final positions = <String, Offset>{};
  final layerByNodeId = <String, int>{};

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

        final overlap = ((minDist - dist) / dist) * strength * 0.5;
        positions[a] = Offset(pa.dx - delta.dx * overlap, pa.dy - delta.dy * overlap);
        positions[b] = Offset(pb.dx + delta.dx * overlap, pb.dy + delta.dy * overlap);
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
}) {
  return graphNodeRadiusForDegree(degree, maxDegree, totalNodes: totalNodes);
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

String graphShortLabel(String name, double screenRadius, {double zoom = 1.0}) {
  final n = name.trim();
  if (n.isEmpty) return '?';
  final maxChars = zoom >= 0.8
      ? (screenRadius * 0.55).round().clamp(6, 20)
      : (screenRadius * 0.4).round().clamp(4, 10);
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
  'concept': Color(0xFF5B9DFF),
  'person': Color(0xFFFF8C42),
  'individual': Color(0xFFFF8C42),
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
