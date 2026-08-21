import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/graph_projection.dart';
import 'package:graphrag_mobile/widgets/knowledge_graph_canvas.dart';

/// 3D 계층 뷰는 물리가 아니라 **카메라**다. 노드의 z는 타입별로 고정이고
/// GraphLayoutEngine은 이 모드의 존재를 모른다 — 기울이기는 물리 평면과
/// 기존 카메라 사이에 끼어드는 평행투영일 뿐이다.
///
/// 그래서 이 파일이 지키는 계약은 두 가지다:
///   1. 기울여도 `layout.positions`는 한 바이트도 변하지 않는다.
///   2. Top view로 돌아오면 기울이기 전 화면이 **그대로** 복원된다.
///
/// all_screens_screenshot_test.dart가 그래프 화면을 제외하는 이유와 같은
/// 이유로 pumpAndSettle을 쓰지 않는다 (물리 루프가 스스로 멈추기 전까지
/// 프레임을 계속 요구한다). 수동 pump로 시간을 밀어 준다.

final _nodes = <Map<String, dynamic>>[
  {'id': 'i0', 'name': '나', 'type': 'Identity'},
  {'id': 'i1', 'name': '마야', 'type': 'Identity'},
  {'id': 's0', 'name': 'statement zero', 'type': 'Statement'},
  {'id': 's1', 'name': 'statement one', 'type': 'Statement'},
  {'id': 'c0', 'name': 'concept zero', 'type': 'Concept'},
  {'id': 'c1', 'name': 'concept one', 'type': 'Topic'},
];

final _edges = <Map<String, dynamic>>[
  {'id': 'e0', 'source_id': 'i0', 'target_id': 's0', 'relation': 'SPOKE_OR_PUBLISHED'},
  {'id': 'e1', 'source_id': 'i1', 'target_id': 's1', 'relation': 'SPOKE_OR_PUBLISHED'},
  {'id': 'e2', 'source_id': 's0', 'target_id': 'c0', 'relation': 'CONTEXT'},
  {'id': 'e3', 'source_id': 's1', 'target_id': 'c1', 'relation': 'CONTEXT'},
  {'id': 'e4', 'source_id': 's0', 'target_id': 'i1', 'relation': 'MENTIONS'},
];

Widget _host() => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 390,
            height: 800,
            child: KnowledgeGraphCanvas(
              nodes: _nodes,
              edges: _edges,
              typeColors: const {},
            ),
          ),
        ),
      ),
    );

Future<KnowledgeGraphCanvasState> _settled(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
  return tester.state<KnowledgeGraphCanvasState>(
    find.byType(KnowledgeGraphCanvas),
  );
}

/// 전환(620ms)이 끝날 때까지 민다.
Future<void> _finishTilt(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

/// 카메라의 2D 줌. `Matrix4.getMaxScaleOnAxis()`를 일부러 쓰지 않는다: 세 축
/// 중 최대를 취하는데 건드리지 않은 z축이 1.0이라, 100% 미만의 모든 줌에서
/// 1.0을 돌려주며 깨진 단언을 조용히 통과시킨다.
double _zoomOf(Matrix4 m) => m.entry(0, 0);

void main() {
  setUp(() {});

  testWidgets('토글하면 3D로 들어가고 예외 없이 안정화된다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);
    expect(state.is3d, isFalse);
    expect(state.debugTilt, 0.0);

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);

    expect(state.is3d, isTrue);
    expect(state.debugTilt, closeTo(1.0, 1e-9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('노드는 타입에서 층을 받고, 층은 오직 화면 y만 옮긴다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);

    expect(state.debugLayerOf('i0'), kGraphLayerIdentity);
    expect(state.debugLayerOf('i1'), kGraphLayerIdentity);
    expect(state.debugLayerOf('s0'), kGraphLayerStatement);
    expect(state.debugLayerOf('c0'), kGraphLayerConcept);
    expect(state.debugLayerOf('c1'), kGraphLayerConcept, reason: 'Topic도 개념층');

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);

    // 같은 물리 좌표를 서로 다른 층에서 투영하면 화면 y만 층 간격만큼 벌어진다.
    final physics = state.debugPhysicsPositions;
    final proj = GraphTiltProjection(t: 1, layerGap: state.debugLayerGap);
    final p = physics['s0']!;
    final atIdentity = proj.project(p, kGraphLayerIdentity);
    final atConcept = proj.project(p, kGraphLayerConcept);
    expect(atIdentity.dy - atConcept.dy,
        closeTo(proj.layerRise * 2, 1e-9));
    expect(atIdentity.dx, closeTo(atConcept.dx, 1e-9));

    // 그리고 실제 캔버스도 같은 계층 분리를 낸다.
    final identityY = state.debugViewPositionOf('i0')!.dy -
        proj.project(physics['i0']!, kGraphLayerConcept).dy;
    expect(identityY, closeTo(proj.layerRise * 2, 1e-6));
  });

  testWidgets('기울여도 물리 좌표는 한 바이트도 변하지 않는다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);
    final before = state.debugPhysicsPositions;

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);

    final during = state.debugPhysicsPositions;
    expect(during.keys.toSet(), before.keys.toSet());
    for (final id in before.keys) {
      expect(during[id], before[id],
          reason: '$id 가 3D 전환만으로 움직였다 — 물리는 이 모드를 몰라야 한다');
    }
  });

  testWidgets('Top view는 기울이기 전 카메라를 그대로 복원한다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);
    final before = state.debugTransform;

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);
    expect(state.is3d, isTrue);
    // 3D에서는 스택 전체를 담느라 줌이 줄어든다 — 실제로 뭔가 달라졌는지 확인.
    expect(_zoomOf(state.debugTransform), lessThan(_zoomOf(before)));

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);

    expect(state.is3d, isFalse);
    expect(state.debugTilt, 0.0);
    final after = state.debugTransform;
    for (var i = 0; i < 16; i++) {
      expect(after.storage[i], closeTo(before.storage[i], 1e-6),
          reason: 'Top view는 원래 보던 지도로 정확히 돌아와야 한다 (칸 $i)');
    }
  });

  testWidgets('평면 모드에서 투영은 항등 — 2D 경로가 이전과 동일하다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);

    final physics = state.debugPhysicsPositions;
    for (final id in physics.keys) {
      expect(state.debugViewPositionOf(id), physics[id],
          reason: '2D에서 뷰 좌표는 물리 좌표 그 자체여야 한다');
    }
  });

  testWidgets('3D에서 겹쳐 보이면 앞쪽(개념) 층이 히트테스트를 이긴다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);

    // 개념 노드를 화면에서 정확히 집어낸다.
    final screen = state.debugScreenPositionOf('c0');
    expect(screen, isNotNull);
    expect(state.debugHitNodeAt(screen!), 'c0');
  });

  testWidgets('3D 드래그: 노드가 자기 평면에 머문 채 손가락을 따라온다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);

    final layerBefore = state.debugLayerOf('i0');
    final start = state.debugScreenPositionOf('i0')!;
    final canvasBox = tester.getRect(find.byType(KnowledgeGraphCanvas));
    const delta = Offset(40, 30);

    final gesture = await tester.startGesture(canvasBox.topLeft + start);
    await tester.pump(const Duration(milliseconds: 16));
    // 4px 임계값을 넘겨 드래그로 확정시킨 뒤 목표까지 민다.
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(delta - const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 16));

    final now = state.debugScreenPositionOf('i0')!;
    expect((now - (start + delta)).distance, lessThan(1.5),
        reason: '역투영이 맞다면 노드는 손가락 아래에 붙어 있어야 한다');
    expect(state.debugLayerOf('i0'), layerBefore,
        reason: 'z는 타입 고정 — 끌어도 층이 바뀌면 안 된다');

    await gesture.up();
    await tester.pump();
  });

  testWidgets('토글은 3D↔Top view를 오간다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    final state = await _settled(tester);
    expect(state.is3d, isFalse);

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);
    expect(state.is3d, isTrue);

    await tester.tap(find.byKey(const Key('canvas.toggle3d')));
    await _finishTilt(tester);
    expect(state.is3d, isFalse);
    expect(tester.takeException(), isNull);
  });
}
