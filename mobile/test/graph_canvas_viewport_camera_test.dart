import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/knowledge_graph_canvas.dart';

/// A phone browser resizes the canvas constantly: iOS Safari grows and shrinks
/// the visual viewport by a few pixels as its toolbar collapses while you drag,
/// and the keyboard and chat sheet move it too. The canvas used to re-fit the
/// whole graph on every one of those changes, which threw away the zoom and pan
/// mid-gesture — the map felt tugged out from under the finger, worst when
/// zoomed in, because a re-fit from there is a long way back out.
///
/// So: fit once, then absorb resizes by keeping the camera and re-anchoring the
/// center.
final _nodes = <Map<String, dynamic>>[
  for (var i = 0; i < 6; i++)
    {'id': 'n$i', 'name': 'node $i', 'type': i.isEven ? 'Identity' : 'Concept'},
];

final _edges = <Map<String, dynamic>>[
  for (var i = 0; i < 5; i++)
    {'id': 'e$i', 'source_id': 'n$i', 'target_id': 'n${i + 1}', 'relation': 'MENTIONS'},
];

Widget _host(double height) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 390,
          height: height,
          child: KnowledgeGraphCanvas(
            nodes: _nodes,
            edges: _edges,
            typeColors: const {},
          ),
        ),
      ),
    ),
  );
}

Future<KnowledgeGraphCanvasState> _settled(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
  return tester.state<KnowledgeGraphCanvasState>(
    find.byType(KnowledgeGraphCanvas),
  );
}

/// The camera's 2D zoom. Deliberately NOT `Matrix4.getMaxScaleOnAxis()`: that
/// takes the largest of the three axes and the untouched z axis is 1.0, so it
/// reports 1.0 for every zoom below 100% — including the fit-to-view scale this
/// graph starts at.
double _zoomOf(Matrix4 m) => m.entry(0, 0);

void main() {
  testWidgets('a resize keeps the zoom the user set', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(800));
    final state = await _settled(tester);
    final fitted = _zoomOf(state.debugTransform);
    expect(fitted, greaterThan(0),
        reason: 'the canvas should have fitted the graph once');

    // Zoom in twice, the way the user did in the report.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    final zoomed = _zoomOf(state.debugTransform);
    expect(zoomed, closeTo(fitted * 1.25 * 1.25, 1e-6));

    // Safari collapsing its toolbar mid-drag.
    await tester.pumpWidget(_host(760));
    await tester.pump();
    await tester.pump();

    // Before this fix the resize re-fitted, which would land back on `fitted`.
    expect(_zoomOf(state.debugTransform), closeTo(zoomed, 1e-9));
    expect(_zoomOf(state.debugTransform), isNot(closeTo(fitted, 1e-3)));
  });

  testWidgets('a resize shifts the view by half the delta, not to fit',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(800));
    final state = await _settled(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    final before = state.debugScreenPositionOf('n0')!;

    await tester.pumpWidget(_host(700));
    await tester.pump();
    await tester.pump();

    // Half of the 100px the viewport lost: the world point that was centered
    // stays centered, so nothing near the middle appears to move much and
    // nothing jumps back to the fitted framing.
    final after = state.debugScreenPositionOf('n0')!;
    expect(after.dx, closeTo(before.dx, 0.01));
    expect(after.dy, closeTo(before.dy - 50, 0.01));
  });
}
