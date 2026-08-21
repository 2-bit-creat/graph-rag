import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/graph_projection.dart';

const _pts = [
  Offset.zero,
  Offset(120, -340),
  Offset(-870.5, 42.25),
  Offset(5000, 5000),
];

void main() {
  group('graphLayerIndexForType', () {
    test('세 계층을 타입에서 뽑는다', () {
      for (final t in ['Person', 'Source', 'Identity', 'Speaker', '화자']) {
        expect(graphLayerIndexForType(t), kGraphLayerIdentity, reason: t);
      }
      expect(graphLayerIndexForType('Statement'), kGraphLayerStatement);
      expect(graphLayerIndexForType('Concept'), kGraphLayerConcept);
      expect(graphLayerIndexForType('Topic'), kGraphLayerConcept);
    });

    test("알 수 없는 타입('other')은 4번째 평면을 만들지 않고 중간에 앉는다", () {
      expect(graphLayerIndexForType('Beverage'), kGraphLayerStatement);
      expect(graphLayerIndexForType(null), kGraphLayerStatement);
      expect(graphLayerIndexForType(''), kGraphLayerStatement);
    });
  });

  group('GraphTiltProjection', () {
    test('t=0은 정확한 항등변환 — Top view가 지금의 2D 지도를 그대로 복원한다', () {
      // 근사가 아니라 정확한 일치여야 한다. 이 단언이 "Top view = 원래 맵"
      // 보증의 전부다.
      for (final proj in [
        GraphTiltProjection.flat,
        GraphTiltProjection(t: 0, layerGap: 800),
        GraphTiltProjection(t: 1e-9, layerGap: 800),
      ]) {
        expect(proj.isFlat, isTrue);
        for (var layer = 0; layer < kGraphLayerCount; layer++) {
          for (final p in _pts) {
            expect(proj.project(p, layer), p);
            expect(proj.unproject(p, layer), p);
          }
        }
      }
    });

    test('unproject(project(p)) == p — 회전 역행렬 부호 검증', () {
      for (final yawMax in [kGraphTiltYawMax, -kGraphTiltYawMax, 0.0]) {
        for (final t in [0.15, 0.5, 0.87, 1.0]) {
          final proj = GraphTiltProjection(
            t: t,
            layerGap: 640,
            yawMax: yawMax,
          );
          for (var layer = 0; layer < kGraphLayerCount; layer++) {
            for (final p in _pts) {
              final back = proj.unproject(proj.project(p, layer), layer);
              expect(back.dx, closeTo(p.dx, 1e-9),
                  reason: 'yaw=$yawMax t=$t layer=$layer p=$p');
              expect(back.dy, closeTo(p.dy, 1e-9),
                  reason: 'yaw=$yawMax t=$t layer=$layer p=$p');
            }
          }
        }
      }
    });

    test('같은 물리 좌표에서 Concept이 Identity보다 화면 위에 온다', () {
      final proj = GraphTiltProjection(t: 1, layerGap: 640);
      const p = Offset(30, -75);
      final identity = proj.project(p, kGraphLayerIdentity);
      final statement = proj.project(p, kGraphLayerStatement);
      final concept = proj.project(p, kGraphLayerConcept);

      // 화면 y는 아래로 증가하므로 "위"는 작은 y다.
      expect(concept.dy, lessThan(statement.dy));
      expect(statement.dy, lessThan(identity.dy));

      // 층 간격은 균일하고 layerRise와 일치한다.
      expect(statement.dy - concept.dy, closeTo(proj.layerRise, 1e-9));
      expect(identity.dy - statement.dy, closeTo(proj.layerRise, 1e-9));

      // 층은 x를 옮기지 않는다 (yaw는 (x,y)에만 작용).
      expect(concept.dx, closeTo(identity.dx, 1e-9));
    });

    test('층은 x/y 물리 이동을 절대 일으키지 않는다 — z는 고정', () {
      final proj = GraphTiltProjection(t: 1, layerGap: 500);
      // 서로 다른 층의 두 점을 역투영하면 원래의 같은 물리 좌표로 돌아온다.
      const physical = Offset(88, 15);
      final a = proj.project(physical, kGraphLayerIdentity);
      final b = proj.project(physical, kGraphLayerConcept);
      expect(proj.unproject(a, kGraphLayerIdentity).dx,
          closeTo(proj.unproject(b, kGraphLayerConcept).dx, 1e-9));
      expect(proj.unproject(a, kGraphLayerIdentity).dy,
          closeTo(proj.unproject(b, kGraphLayerConcept).dy, 1e-9));
    });

    test('projectBounds가 전 층의 투영 코너를 모두 담는다', () {
      final proj = GraphTiltProjection(t: 1, layerGap: 720);
      const bounds = Rect.fromLTRB(-400, -260, 380, 310);
      final out = proj.projectBounds(bounds);

      for (var layer = 0; layer < kGraphLayerCount; layer++) {
        for (final c in proj.planeQuad(bounds, layer)) {
          expect(out.left, lessThanOrEqualTo(c.dx + 1e-9));
          expect(out.right, greaterThanOrEqualTo(c.dx - 1e-9));
          expect(out.top, lessThanOrEqualTo(c.dy + 1e-9));
          expect(out.bottom, greaterThanOrEqualTo(c.dy - 1e-9));
        }
      }
      // 기울이면 반드시 세로로 자란다 — 이게 fit-to-view 클리핑을 막는다.
      expect(out.height, greaterThan(bounds.height));
    });

    test('projectBounds는 평면 모드에서 입력을 그대로 돌려준다', () {
      const bounds = Rect.fromLTRB(-10, -20, 30, 40);
      expect(GraphTiltProjection.flat.projectBounds(bounds), bounds);
    });

    test('planeQuad는 yaw 때문에 평행사변형이 된다', () {
      final proj = GraphTiltProjection(t: 1, layerGap: 640);
      const bounds = Rect.fromLTRB(-100, -100, 100, 100);
      final q = proj.planeQuad(bounds, kGraphLayerStatement);
      expect(q, hasLength(4));
      // 마주보는 변이 평행: (q1-q0) == (q2-q3)
      expect((q[1] - q[0]).dx, closeTo((q[2] - q[3]).dx, 1e-9));
      expect((q[1] - q[0]).dy, closeTo((q[2] - q[3]).dy, 1e-9));
      // 그리고 직사각형은 아니다 (yaw가 기울였으므로).
      expect((q[1] - q[0]).dy.abs(), greaterThan(1.0));
    });

    test('graphLayerGapFor는 그래프 크기에 비례하되 상하한에 걸린다', () {
      expect(graphLayerGapFor(const Rect.fromLTWH(0, 0, 10, 10)), 260.0);
      expect(graphLayerGapFor(const Rect.fromLTWH(0, 0, 99999, 99999)), 1400.0);
      final mid = graphLayerGapFor(const Rect.fromLTWH(0, 0, 1000, 1000));
      expect(mid, closeTo(550.0, 1e-9));
    });

    test('t는 0..1로 클램프된다', () {
      final over = GraphTiltProjection(t: 4, layerGap: 100);
      final one = GraphTiltProjection(t: 1, layerGap: 100);
      expect(over.project(const Offset(3, 7), 2),
          _offsetCloseTo(one.project(const Offset(3, 7), 2)));
      expect(GraphTiltProjection(t: -2, layerGap: 100).isFlat, isTrue);
    });

    test('pitch는 cos φ를 0에서 떨어뜨리는 범위로만 만들 수 있다', () {
      expect(
        () => GraphTiltProjection(
          t: 1,
          layerGap: 100,
          pitchMax: 89 * math.pi / 180,
        ),
        throwsAssertionError,
      );
    });
  });
}

Matcher _offsetCloseTo(Offset expected) => predicate<Offset>(
      (a) =>
          (a.dx - expected.dx).abs() < 1e-9 && (a.dy - expected.dy).abs() < 1e-9,
      'within 1e-9 of $expected',
    );
