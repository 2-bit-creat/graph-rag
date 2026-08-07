import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A two-sided card that rotates around its Y axis when [showBack] flips.
///
/// Deliberately dependency-free: the whole effect is one [AnimationController]
/// driving a perspective [Matrix4]. The back child is pre-rotated by pi so it
/// reads the right way round once the card has passed the halfway point — and
/// only one side is ever built, so an expensive back face costs nothing while
/// the card is face down.
class FlipCard extends StatefulWidget {
  const FlipCard({
    super.key,
    required this.showBack,
    required this.front,
    required this.back,
    this.duration = const Duration(milliseconds: 420),
  });

  final bool showBack;
  final Widget front;
  final Widget back;
  final Duration duration;

  @override
  State<FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<FlipCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.showBack ? 1 : 0,
  );

  late final Animation<double> _turn = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  @override
  void didUpdateWidget(FlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showBack != oldWidget.showBack) {
      if (widget.showBack) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _turn,
      builder: (context, _) {
        final angle = _turn.value * math.pi;
        // Past the quarter turn the front is edge-on, so swapping there hides
        // the cut entirely — the viewer never sees either face mid-swap.
        final isBack = _turn.value > 0.5;
        final transform = Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateY(angle);
        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: isBack
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(math.pi),
                  child: widget.back,
                )
              : widget.front,
        );
      },
    );
  }
}
