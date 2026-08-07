import 'dart:math' as math;

import 'package:flutter/material.dart';

enum SwipeDirection { left, right }

/// Imperative handle so chrome outside the deck (the "안다"/"복습" buttons) can
/// trigger the same animated dismissal a drag produces.
class SwipeDeckController extends ChangeNotifier {
  _SwipeDeckState? _state;

  void _attach(_SwipeDeckState state) => _state = state;

  void _detach(_SwipeDeckState state) {
    if (identical(_state, state)) _state = null;
  }

  /// Fling the top card away. No-op when the deck is empty or mid-animation.
  void swipe(SwipeDirection direction) => _state?.programmaticSwipe(direction);

  @override
  void dispose() {
    _state = null;
    super.dispose();
  }
}

/// A Quizlet-style card stack: drag the top card left or right to dismiss it.
///
/// Hand-rolled rather than pulled from pub so the gesture arena stays ours —
/// the deck lives inside the same app that hosts an InteractiveViewer canvas,
/// and Flutter Web's pointer handling is where third-party swipers tend to
/// disagree with the framework. It is also the reason the drag uses a plain
/// [GestureDetector] pan: that competes cleanly with an enclosing scrollable
/// instead of claiming every pointer.
class SwipeDeck extends StatefulWidget {
  const SwipeDeck({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onSwipe,
    this.controller,
    this.overlayBuilder,
  });

  final int itemCount;

  /// Builds the card at [index]. Index 0 is always the current top card.
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// Fired once the dismissal animation has completed.
  final void Function(int index, SwipeDirection direction) onSwipe;

  final SwipeDeckController? controller;

  /// Tint drawn over the top card while it is being dragged. [progress] runs
  /// 0..1 with the drag distance, so the caller can fade in a verdict colour.
  final Widget Function(
    BuildContext context,
    SwipeDirection direction,
    double progress,
  )? overlayBuilder;

  @override
  State<SwipeDeck> createState() => _SwipeDeckState();
}

class _SwipeDeckState extends State<SwipeDeck> with TickerProviderStateMixin {
  static const _rotationRadians = 0.18;
  static const _velocityThreshold = 800.0;
  static const _distanceFraction = 0.28;

  // Built eagerly in initState, not lazily. A deck that is opened and closed
  // without a single drag would otherwise first touch this field in dispose(),
  // and createTicker looks up TickerMode on an element that is already
  // deactivated by then — an assertion failure on an ordinary close.
  late final AnimationController _settle;

  Offset _drag = Offset.zero;
  Offset _settleFrom = Offset.zero;
  Offset _settleTo = Offset.zero;
  SwipeDirection? _flyingOut;
  double _width = 1;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_onSettleTick);
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(SwipeDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _settle.dispose();
    super.dispose();
  }

  void _onSettleTick() {
    final t = Curves.easeOutCubic.transform(_settle.value);
    setState(() => _drag = Offset.lerp(_settleFrom, _settleTo, t)!);
    if (_settle.isCompleted) _finishSettle();
  }

  void _finishSettle() {
    final direction = _flyingOut;
    _flyingOut = null;
    setState(() => _drag = Offset.zero);
    if (direction != null) widget.onSwipe(0, direction);
  }

  bool get _busy => _settle.isAnimating;

  void programmaticSwipe(SwipeDirection direction) {
    if (_busy || widget.itemCount == 0) return;
    _flingOut(direction);
  }

  void _flingOut(SwipeDirection direction) {
    _flyingOut = direction;
    _settleFrom = _drag;
    _settleTo = Offset(
      direction == SwipeDirection.right ? _width * 1.6 : -_width * 1.6,
      _drag.dy,
    );
    _settle
      ..duration = const Duration(milliseconds: 260)
      ..forward(from: 0);
  }

  void _springBack() {
    _flyingOut = null;
    _settleFrom = _drag;
    _settleTo = Offset.zero;
    _settle
      ..duration = const Duration(milliseconds: 280)
      ..forward(from: 0);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_busy) return;
    setState(() => _drag += details.delta);
  }

  void _onPanEnd(DragEndDetails details) {
    if (_busy) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final passedDistance = _drag.dx.abs() > _width * _distanceFraction;
    final passedVelocity = velocity.abs() > _velocityThreshold;
    if (passedDistance || passedVelocity) {
      // A hard flick wins over position: releasing a barely-moved card with a
      // fast flick should still commit, in the flick's direction.
      final dx = passedVelocity ? velocity : _drag.dx;
      _flingOut(dx > 0 ? SwipeDirection.right : SwipeDirection.left);
    } else {
      _springBack();
    }
  }

  double get _progress =>
      (_drag.dx.abs() / (_width * _distanceFraction)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth <= 0 ? 1 : constraints.maxWidth;
        final direction =
            _drag.dx >= 0 ? SwipeDirection.right : SwipeDirection.left;

        return Stack(
          alignment: Alignment.center,
          children: [
            // The card underneath, so the stack reads as a deck. It eases up to
            // full size as the top card leaves.
            if (widget.itemCount > 1)
              Transform.scale(
                scale: 0.94 + 0.06 * _progress,
                child: Opacity(
                  opacity: 0.6 + 0.4 * _progress,
                  child: IgnorePointer(child: widget.itemBuilder(context, 1)),
                ),
              ),
            Transform.translate(
              offset: _drag,
              child: Transform.rotate(
                angle: (_drag.dx / _width) * _rotationRadians * math.pi,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: Stack(
                    children: [
                      widget.itemBuilder(context, 0),
                      if (widget.overlayBuilder != null && _progress > 0)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: widget.overlayBuilder!(
                              context,
                              direction,
                              _progress,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
