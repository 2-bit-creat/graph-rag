import 'dart:ui' show Rect;

/// Non-web builds: the keyboard is not owned by a DOM element, so a tap on a
/// Flutter-drawn overlay never blurs anything. Nothing to guard.
void keepKeyboardOverRect(Rect? rect) {}
