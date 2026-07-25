import 'package:flutter/widgets.dart';

/// Carries the exact vertical space left above the docked composer.
/// Quiz cards use it to compact vertically while keeping their full width.
class QuizViewportScope extends InheritedWidget {
  const QuizViewportScope({
    super.key,
    required this.availableHeight,
    required super.child,
  });

  final double availableHeight;

  static double? maybeHeightOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QuizViewportScope>()?.availableHeight;

  @override
  bool updateShouldNotify(QuizViewportScope oldWidget) =>
      oldWidget.availableHeight != availableHeight;
}
