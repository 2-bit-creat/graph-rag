import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shrinks its child uniformly so it fits [maxHeight], rather than letting the
/// overflow scroll out of sight.
///
/// The quiz card's problem is not that it lays out wrongly — it fits the space
/// above the keyboard exactly. It is that the space is ~340px and the question
/// is ~500px, so a third of it lives below an internal fold the learner has no
/// reason to suspect is there. Scrolling is the honest fallback but a poor
/// default: the thing you scroll away is the sentence you are answering.
///
/// So take the trade the learner would take — smaller text, all of it visible.
///
/// The scale is uniform (a real [Transform], not a font-size change), so
/// nothing re-flows into a different shape at a different size: the card the
/// learner sees is the card they would see on a bigger screen, just smaller.
///
/// ## Why the child is laid out *wider* than the box
///
/// Scaling by `s` also scales width, which would leave `width * (1 - s)` of
/// empty gutter. Laying the child out at `width / s` first means it lands at
/// exactly `width` after scaling. That re-wraps the text at a wider line box —
/// more characters per line, fewer lines — so the scaled height comes out
/// *below* the estimate. The result always fits; it is just occasionally a
/// little smaller than it strictly had to be, which is the safe direction to
/// err.
///
/// ## The floor
///
/// [minScale] is where the trade stops paying. Past it the text is small enough
/// that "visible" stops meaning "readable", and this box gives up and reports
/// its full scaled height — leaving a surrounding scroll view to handle the
/// remainder, which is what used to happen for everything.
class ScaleToFit extends SingleChildRenderObjectWidget {
  const ScaleToFit({
    super.key,
    required this.maxHeight,
    this.minScale = 0.70,
    required Widget super.child,
  });

  /// The height to fit into. Passed in rather than read from the incoming
  /// constraints because this normally sits inside a scroll view, where the
  /// incoming maxHeight is infinite.
  final double maxHeight;

  /// How far the trade is allowed to go before scrolling takes over.
  final double minScale;

  @override
  RenderScaleToFit createRenderObject(BuildContext context) =>
      RenderScaleToFit(maxHeight: maxHeight, minScale: minScale);

  @override
  void updateRenderObject(BuildContext context, RenderScaleToFit renderObject) {
    renderObject
      ..maxHeight = maxHeight
      ..minScale = minScale;
  }
}

class RenderScaleToFit extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderScaleToFit({required double maxHeight, required double minScale})
      : _maxHeight = maxHeight,
        _minScale = minScale;

  double _maxHeight;
  double get maxHeight => _maxHeight;
  set maxHeight(double value) {
    if (_maxHeight == value) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  double _minScale;
  double get minScale => _minScale;
  set minScale(double value) {
    if (_minScale == value) return;
    _minScale = value;
    markNeedsLayout();
  }

  double _scale = 1;

  /// The scale actually applied. 1.0 means the child fitted as-is.
  double get scale => _scale;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      _scale = 1;
      size = constraints.smallest;
      return;
    }
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.constrainWidth(double.infinity);
    final limit = math.min(_maxHeight, constraints.maxHeight);

    child.layout(
      BoxConstraints(minWidth: width, maxWidth: width),
      parentUsesSize: true,
    );

    var scale = 1.0;
    if (limit.isFinite && limit > 0 && child.size.height > limit) {
      // `limit / naturalHeight` is only a lower bound on the usable scale,
      // because laying the child out wider (see the class note) re-wraps the
      // text into fewer lines. Taking that first estimate shrank the card to
      // the floor even in cases that fitted comfortably at 0.85 — visible, but
      // needlessly small, which spends the learner's legibility for nothing.
      //
      // `height(width / s) * s` is monotonic in `s`: a smaller `s` both scales
      // down and widens, and each shrinks the result. So binary-search the
      // largest scale that still fits. Five passes lands within ~1%.
      double scaledHeightAt(double candidate) {
        final wide = width / candidate;
        child.layout(
          BoxConstraints(minWidth: wide, maxWidth: wide),
          parentUsesSize: true,
        );
        return child.size.height * candidate;
      }

      var lo = _minScale;
      var hi = 1.0;
      if (scaledHeightAt(lo) > limit) {
        // Too long to rescue without making it unreadable. Take the floor and
        // let the surrounding scroll view carry the remainder.
        scale = lo;
      } else {
        for (var i = 0; i < 5; i++) {
          final mid = (lo + hi) / 2;
          if (scaledHeightAt(mid) <= limit) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        scale = lo;
      }
      // The search leaves the child laid out at whatever it probed last.
      final wide = width / scale;
      child.layout(
        BoxConstraints(minWidth: wide, maxWidth: wide),
        parentUsesSize: true,
      );
    }
    _scale = scale;
    size = constraints.constrain(
      Size(width, child.size.height * scale),
    );
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_scale == 1.0) {
      context.paintChild(child, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (innerContext, innerOffset) => innerContext.paintChild(child, innerOffset),
      oldLayer: layer as TransformLayer?,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    // Buttons and text fields inside a scaled card must still take taps where
    // they are drawn, not where they were laid out.
    return result.addWithPaintTransform(
      transform: _scale == 1.0 ? null : _transform,
      position: position,
      hitTest: (BoxHitTestResult innerResult, Offset innerPosition) =>
          child.hitTest(innerResult, position: innerPosition),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_scale != 1.0) transform.scaleByDouble(_scale, _scale, 1, 1);
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;
}
