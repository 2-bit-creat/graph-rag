import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/graph_layout.dart';
import 'package:graphrag_mobile/widgets/knowledge_graph_canvas.dart';

/// Merging duplicates ('의준' and '박의준' are one person) is done by long-pressing
/// a node and dropping it on another. Two things have to hold for that to be
/// safe: an ordinary drag — the one that nudges a node around — must never turn
/// into a merge, and a drop must only be offered where the backend will accept
/// it.
Map<String, dynamic> _node(String id, String name, String type) => {
      'id': id,
      'name': name,
      'type': type,
    };

final _nodes = <Map<String, dynamic>>[
  _node('me', '나', 'Identity')..['is_self'] = true,
  _node('a', '의준', 'Identity'),
  _node('b', '박의준', 'Identity'),
  _node('c', '운동', 'Concept'),
  _node('s', '네이버지도', 'Source'),
  _node('st', '운동 완료', 'Statement'),
];

final _edges = <Map<String, dynamic>>[
  {'id': 'e1', 'source_id': 'b', 'target_id': 'st', 'relation': 'SPOKE_OR_PUBLISHED'},
  {'id': 'e2', 'source_id': 'st', 'target_id': 'c', 'relation': 'CONTEXT'},
  {'id': 'e3', 'source_id': 'a', 'target_id': 'c', 'relation': 'MENTIONS'},
];

Widget _host({
  void Function(Map<String, dynamic>, Map<String, dynamic>)? onMerge,
}) {
  return MaterialApp(
    home: Scaffold(
      body: KnowledgeGraphCanvas(
        nodes: _nodes,
        edges: _edges,
        typeColors: const {},
        showControls: false,
        onNodeMergeRequest: onMerge,
      ),
    ),
  );
}

/// The canvas fits the graph in a post-frame callback and runs a live physics
/// ticker, so pumpAndSettle would spin. Pump a fixed number of frames instead.
Future<KnowledgeGraphCanvasState> _settled(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
  return tester.state<KnowledgeGraphCanvasState>(
    find.byType(KnowledgeGraphCanvas),
  );
}

void main() {
  group('canMergeNodes', () {
    test('same bucket merges, and Concept may become an Identity', () {
      expect(canMergeNodes(_nodes[1], _nodes[2]), isTrue); // Identity → Identity
      expect(canMergeNodes(_nodes[3], _nodes[2]), isTrue); // Concept → Identity
      expect(canMergeNodes(_nodes[1], _nodes[0]), isTrue); // → '나' is allowed
    });

    test('buckets that must not mix', () {
      // Source (media/organisation) and Identity are deliberately separate: the
      // resolver never mixes them, so a drag must not either.
      expect(canMergeNodes(_nodes[4], _nodes[2]), isFalse);
      expect(canMergeNodes(_nodes[2], _nodes[4]), isFalse);
      // Two statements are never "the same thing" — each is a sentence from its
      // own entry, and merging would flatten their provenance.
      expect(canMergeNodes(_nodes[5], _nodes[2]), isFalse);
      expect(canMergeNodes(_nodes[2], _nodes[5]), isFalse);
      // '나' is absorbed into nothing; the backend rejects it with a 400.
      expect(canMergeNodes(_nodes[0], _nodes[2]), isFalse);
      // Identity → the same Identity.
      expect(canMergeNodes(_nodes[2], _nodes[2]), isFalse);
    });
  });

  testWidgets('long-press then drop on a node asks to merge', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final requests = <({String source, String target})>[];
    await tester.pumpWidget(_host(
      onMerge: (s, t) => requests.add(
        (source: s['id'].toString(), target: t['id'].toString()),
      ),
    ));
    final state = await _settled(tester);

    final from = state.debugScreenPositionOf('a');
    final to = state.debugScreenPositionOf('b');
    expect(from, isNotNull, reason: 'layout must have placed the nodes');
    expect(to, isNotNull);

    final gesture = await tester.startGesture(from!);
    // Hold without moving — this is what separates a merge from a reposition.
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(state.debugScreenPositionOf('b')!);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(requests, [(source: 'a', target: 'b')]);
  });

  testWidgets('a plain drag moves the node and asks nothing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var asked = 0;
    await tester.pumpWidget(_host(onMerge: (_, __) => asked++));
    final state = await _settled(tester);

    final from = state.debugScreenPositionOf('a')!;
    final gesture = await tester.startGesture(from);
    // Moving before the hold elapses claims the gesture as a reposition. The
    // node passing over another one must not be read as a drop.
    await gesture.moveTo(state.debugScreenPositionOf('b')!);
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.up();
    await tester.pump();

    expect(asked, 0);
  });

  testWidgets('dropping on a node from another bucket asks nothing',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var asked = 0;
    await tester.pumpWidget(_host(onMerge: (_, __) => asked++));
    final state = await _settled(tester);

    // A Source node held over an Identity: the highlight never lights up, so the
    // release has nothing to confirm.
    final gesture = await tester.startGesture(state.debugScreenPositionOf('s')!);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(state.debugScreenPositionOf('b')!);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(asked, 0);
  });

  testWidgets('the dropped node returns to where it started', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(onMerge: (_, __) {}));
    final state = await _settled(tester);

    final origin = state.debugScreenPositionOf('a')!;
    final gesture = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(state.debugScreenPositionOf('b')!);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // The confirmation is still open at this point and can be cancelled, so the
    // layout must be untouched — a node left sitting on top of another reads as
    // a graph that broke on its own.
    final after = state.debugScreenPositionOf('a')!;
    expect((after - origin).distance, lessThan(1.0));
  });
}
