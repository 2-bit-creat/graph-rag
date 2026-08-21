import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'graph_layout.dart';

/// 3D 계층 뷰의 평행(축측)투영.
///
/// 이건 진짜 3D가 아니다. 노드의 z는 타입에 따라 세 값 중 하나로 **고정**이고
/// 카메라 행렬은 translate+scale 전용이므로, 원근 나눗셈도 GL도 필요 없다.
/// 투영은 물리 평면과 기존 카메라 사이의 월드 좌표에 접혀 들어간다:
///
///     물리 (x,y) + layer --project--> "뷰 월드" (x',y') --카메라--> 화면
///
/// 층 안에서는 순수 affine이므로 바운딩 박스도 코너 투영만으로 정확하다.
/// t=0에서 항등변환이라는 점이 이 설계의 핵심이다 — Top view가 지금의 2D
/// 그래프를 근사하는 게 아니라 **그대로** 복원한다.

const int kGraphLayerIdentity = 0; // 아래 평면
const int kGraphLayerStatement = 1; // 중간 평면
const int kGraphLayerConcept = 2; // 위 평면
const int kGraphLayerCount = 3;

/// 층 색. graph_layout.dart의 `_semanticTypeColors`(identity 주황 / statement
/// 보라 / concept 파랑)와 같은 값을 한 곳에서 내보내, 평면 쿼드·디스크·범례가
/// 서로 어긋날 수 없게 한다.
const List<Color> kGraphLayerColors = [
  Color(0xFFFF8C42),
  Color(0xFFB07BFF),
  Color(0xFF5B9DFF),
];

/// 층 이름 문자열 키 (평면 옆면 라벨과 범례가 공유).
const List<String> kGraphLayerLabelKeys = [
  'canvas.layerIdentity',
  'canvas.layerStatement',
  'canvas.layerConcept',
];

const double kGraphTiltYawMax = -18 * math.pi / 180;
const double kGraphTiltPitchMax = 55 * math.pi / 180;

/// 노드의 고정 z 슬롯.
///
/// [graphFocusTier] 위에 세운다 — 3D 적층과 기존 Speaker→Statement→Concept
/// 포커스 체인이 서로 다른 규칙을 쓰기 시작하면 두 기능이 조용히 어긋난다.
///
/// tier `'other'`는 네 번째 평면을 만들지 않고 중간에 둔다. 보통 비어 있는
/// 버킷 하나 때문에 층 개수·범례·쿼드 루프를 전부 바꿀 이유가 없고, 중간이면
/// 무엇에 연결되든 시각적으로 인접하다.
int graphLayerIndexForType(String? type) {
  switch (graphFocusTier(type)) {
    case 'speaker':
      return kGraphLayerIdentity;
    case 'concept':
      return kGraphLayerConcept;
    case 'statement':
    default:
      return kGraphLayerStatement;
  }
}

/// 그래프 크기에 비례한 층 간격.
///
/// 프레임마다가 아니라 레이아웃 epoch마다 한 번만 계산해야 한다 — 물리가
/// 안정화되며 bounds가 조금씩 변하는 동안 매 프레임 다시 재면 장면 전체가
/// 호흡하듯 흔들린다.
double graphLayerGapFor(Rect physicsBounds) =>
    (0.55 * physicsBounds.shortestSide).clamp(260.0, 1400.0);

@immutable
class GraphTiltProjection {
  const GraphTiltProjection._({
    required this.t,
    required this.layerGap,
    required double cosYaw,
    required double sinYaw,
    required double cosPitch,
    required double sinPitch,
  })  : _cosYaw = cosYaw,
        _sinYaw = sinYaw,
        _cosPitch = cosPitch,
        _sinPitch = sinPitch;

  factory GraphTiltProjection({
    required double t,
    required double layerGap,
    double yawMax = kGraphTiltYawMax,
    double pitchMax = kGraphTiltPitchMax,
  }) {
    // cos φ가 0에 가까워지면 unproject가 폭발한다. 80°면 cos φ >= 0.17로,
    // 실제로 쓰는 55°(cos ≈ 0.57)에서 한참 여유가 있다.
    assert(pitchMax.abs() < 80 * math.pi / 180);
    final tc = t.clamp(0.0, 1.0);
    if (tc <= 1e-4) return flat;
    final yaw = yawMax * tc;
    final pitch = pitchMax * tc;
    return GraphTiltProjection._(
      t: tc,
      layerGap: layerGap,
      cosYaw: math.cos(yaw),
      sinYaw: math.sin(yaw),
      cosPitch: math.cos(pitch),
      sinPitch: math.sin(pitch),
    );
  }

  /// 항등투영. 2D 모드 전체가 이 인스턴스를 쓰고, 호출자는 [isFlat]으로
  /// 물리 좌표를 그대로 재사용하도록 단락할 수 있다.
  static const flat = GraphTiltProjection._(
    t: 0,
    layerGap: 0,
    cosYaw: 1,
    sinYaw: 0,
    cosPitch: 1,
    sinPitch: 0,
  );

  final double t;
  final double layerGap;
  final double _cosYaw;
  final double _sinYaw;
  final double _cosPitch;
  final double _sinPitch;

  bool get isFlat => t <= 1e-4;

  /// 화면에서 한 층이 위로 밀려나는 거리 (양수).
  double get layerRise => layerGap * _sinPitch;

  Offset project(Offset p, int layer) {
    if (isFlat) return p;
    final xr = p.dx * _cosYaw - p.dy * _sinYaw;
    final yr = p.dx * _sinYaw + p.dy * _cosYaw;
    return Offset(xr, yr * _cosPitch - layer * layerGap * _sinPitch);
  }

  /// [project]의 정확한 역. 노드의 층을 타입에서 알기 때문에 깊이 모호성이
  /// 없다 — 이것이 "z는 타입별 고정"이 드래그를 공짜로 만들어 주는 지점이다.
  Offset unproject(Offset v, int layer) {
    if (isFlat) return v;
    if (_cosPitch.abs() < 1e-3) return v; // 도달 불가(assert), 방어용
    final xr = v.dx;
    final yr = (v.dy + layer * layerGap * _sinPitch) / _cosPitch;
    // 회전 역행렬은 [[cos, sin], [-sin, cos]] — 부호를 틀리기 쉬운 자리라
    // graph_projection_test.dart의 왕복 테스트가 이걸 지킨다.
    return Offset(
      xr * _cosYaw + yr * _sinYaw,
      -xr * _sinYaw + yr * _cosYaw,
    );
  }

  /// 한 층의 평면 쿼드 코너 4개 (좌상→우상→우하→좌하). yaw 때문에
  /// 직사각형이 아니라 평행사변형이 된다.
  List<Offset> planeQuad(Rect physicsBounds, int layer) => [
        project(physicsBounds.topLeft, layer),
        project(physicsBounds.topRight, layer),
        project(physicsBounds.bottomRight, layer),
        project(physicsBounds.bottomLeft, layer),
      ];

  /// 전 층에 걸친 투영 바운딩 박스. 층 안에서 affine이므로 코너 4×층수 =
  /// 12점만 보면 정확하다.
  ///
  /// `_syncWorldFrame`/`_fitToView`가 이걸 써야 기울인 스택이 화면에
  /// 잘리지 않는다.
  Rect projectBounds(Rect physicsBounds) {
    if (isFlat) return physicsBounds;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (var layer = 0; layer < kGraphLayerCount; layer++) {
      for (final c in planeQuad(physicsBounds, layer)) {
        minX = math.min(minX, c.dx);
        minY = math.min(minY, c.dy);
        maxX = math.max(maxX, c.dx);
        maxY = math.max(maxY, c.dy);
      }
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}
