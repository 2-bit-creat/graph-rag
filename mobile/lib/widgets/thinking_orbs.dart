import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Native "thinking orbs" loading animation — a cluster of soft, glowing orbs
/// that orbit a shared center with staggered phases and a gentle breathing
/// pulse. Purpose-built to signal AI *thinking / searching / generating*.
///
/// Zero dependencies: a single [AnimationController] driving a [CustomPainter].
/// Colors default to the app's brand gradient (graph → quiz) so it reads as the
/// same "voice" as the assistant avatar. Drop it in at any [size]; the geometry
/// and glow scale with it.
class ThinkingOrbs extends StatefulWidget {
  const ThinkingOrbs({
    super.key,
    this.size = 22,
    this.orbCount = 3,
    this.colors,
    this.period = const Duration(milliseconds: 2600),
  });

  final double size;
  final int orbCount;

  /// Orb tints, cycled across [orbCount]. Defaults to the brand gradient.
  final List<Color>? colors;
  final Duration period;

  @override
  State<ThinkingOrbs> createState() => _ThinkingOrbsState();
}

class _ThinkingOrbsState extends State<ThinkingOrbs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors ??
        const [AppColors.hubGraph, AppColors.hubQuiz, AppColors.accent];
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _OrbsPainter(
              t: _c.value,
              orbCount: widget.orbCount,
              colors: colors,
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbsPainter extends CustomPainter {
  _OrbsPainter({
    required this.t,
    required this.orbCount,
    required this.colors,
  });

  final double t; // 0..1
  final int orbCount;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final orbit = size.shortestSide * 0.26;
    final baseR = size.shortestSide * 0.19;
    final twoPi = 2 * math.pi;

    // Draw back-to-front so overlapping orbs blend softly (screen-like glow).
    for (var i = 0; i < orbCount; i++) {
      final phase = i / orbCount;
      final angle = (t + phase) * twoPi;
      // Slight vertical squash for a 3D orbit feel; farther orbs read smaller.
      final depth = (math.sin(angle) + 1) / 2; // 0 (back) .. 1 (front)
      final pos = center +
          Offset(math.cos(angle) * orbit, math.sin(angle) * orbit * 0.55);
      final pulse = 0.72 + 0.28 * depth;
      final r = baseR * pulse;
      final color = colors[i % colors.length];

      // Outer glow.
      canvas.drawCircle(
        pos,
        r * 2.1,
        Paint()
          ..color = color.withValues(alpha: 0.16 * pulse)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.9),
      );
      // Core.
      canvas.drawCircle(
        pos,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Color.lerp(color, Colors.white, 0.55 * depth)!,
              color.withValues(alpha: 0.85),
            ],
          ).createShader(Rect.fromCircle(center: pos, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbsPainter old) => old.t != t;
}

/// Chat-feed "thinking" row: orbs paired with a shimmering, cycling status
/// label ("생각하는 중…", "기억을 뒤적이는 중…", …). Reusable wherever the
/// assistant is working. Falls back to a single [label] when [phrases] is null.
class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({
    super.key,
    this.label,
    this.phrases,
    this.orbSize = 22,
  });

  final String? label;
  final List<String>? phrases;
  final double orbSize;

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator> {
  late final List<String> _phrases =
      widget.phrases ?? (widget.label != null ? [widget.label!] : _defaults);
  int _idx = 0;

  static const _defaults = [
    '기억을 뒤적이는 중…',
    '생각을 정리하는 중…',
    '연결고리를 찾는 중…',
  ];

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, top: 2),
      child: Row(
        children: [
          ThinkingOrbs(size: widget.orbSize),
          const SizedBox(width: AppSpacing.sm),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.35),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: _ShimmerText(
              // Key by index so AnimatedSwitcher animates between phrases.
              key: ValueKey(_idx),
              text: _phrases[_idx % _phrases.length],
              color: shell.mutedText,
              onCycle: _phrases.length > 1
                  ? () {
                      if (mounted) setState(() => _idx++);
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A short label with a light sweep shimmering across it. When [onCycle] is
/// provided it fires once per sweep so the parent can advance to the next
/// phrase — giving a "typing status" feel without a second controller.
class _ShimmerText extends StatefulWidget {
  const _ShimmerText({
    super.key,
    required this.text,
    required this.color,
    this.onCycle,
  });

  final String text;
  final Color color;
  final VoidCallback? onCycle;

  @override
  State<_ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<_ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        widget.onCycle?.call();
        _c.forward(from: 0);
      }
    });

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final hi = Color.lerp(base, Colors.white, 0.85)!;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final x = _c.value;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [base, hi, base],
            stops: [
              (x - 0.2).clamp(0.0, 1.0),
              x.clamp(0.0, 1.0),
              (x + 0.2).clamp(0.0, 1.0),
            ],
          ).createShader(rect),
          child: child,
        );
      },
      child: Text(
        widget.text,
        style: const TextStyle(
          color: Colors.white, // masked by the shader
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
