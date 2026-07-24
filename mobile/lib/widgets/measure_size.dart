import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Reports [child]'s laid-out size to [onChange], and again whenever it changes.
///
/// Used where one widget's padding has to clear another's actual height —
/// guessing a constant there goes wrong the moment the other widget grows (an
/// extra chip row, a wrapped line, a different safe-area inset).
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onChange, required Widget super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMeasureSize).onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final next = size;
    if (_last == next) return;
    _last = next;
    // Callbacks that rebuild must not run during layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(next));
  }
}
