import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Live mic waveform — a row of rounded bars whose heights track the rolling
/// [levels] buffer (0..1, newest last) from `AudioRecordController`. Bars ease
/// toward their new height each frame so the trace flows instead of snapping.
class AudioWaveform extends StatefulWidget {
  const AudioWaveform({
    super.key,
    required this.levels,
    this.color = AppColors.hubRecord,
    this.barCount = 32,
    this.height = 44,
    this.minBarFraction = 0.08,
  });

  final List<double> levels;
  final Color color;
  final int barCount;
  final double height;

  /// Idle bar height as a fraction of [height] (so silence still shows a line).
  final double minBarFraction;

  @override
  State<AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<AudioWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  late final List<double> _display = List.filled(widget.barCount, 0.0);

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// Sample the rolling buffer down to [barCount] targets, then ease toward them.
  void _advance() {
    final src = widget.levels;
    for (var i = 0; i < widget.barCount; i++) {
      double target;
      if (src.isEmpty) {
        target = 0;
      } else {
        // Map bar i onto the tail of the buffer so newest audio is on the right.
        final idx = src.length - widget.barCount + i;
        target = idx >= 0 && idx < src.length ? src[idx] : 0;
      }
      _display[i] += (target - _display[i]) * 0.35;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _ticker,
        builder: (context, _) {
          _advance();
          return CustomPaint(
            size: Size.infinite,
            painter: _WaveformPainter(
              display: _display,
              color: widget.color,
              minFraction: widget.minBarFraction,
            ),
          );
        },
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.display,
    required this.color,
    required this.minFraction,
  });

  final List<double> display;
  final Color color;
  final double minFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final n = display.length;
    if (n == 0) return;
    final gap = size.width / n;
    final barW = gap * 0.55;
    final mid = size.height / 2;
    final maxH = size.height;

    for (var i = 0; i < n; i++) {
      final level = display[i].clamp(0.0, 1.0);
      final h = maxH * (minFraction + (1 - minFraction) * level);
      final cx = gap * i + gap / 2;
      // Louder bars glow brighter; quiet ones stay faint.
      final paint = Paint()
        ..color = color.withValues(alpha: 0.35 + 0.65 * level)
        ..style = PaintingStyle.fill;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, mid), width: barW, height: h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => true;
}
