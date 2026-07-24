import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'package:flutter/foundation.dart';

/// How many logical pixels at the bottom of the layout viewport are currently
/// covered by the on-screen keyboard. 0 when it is closed.
final ValueNotifier<double> keyboardInset = ValueNotifier<double>(0);

bool _started = false;

/// Anything below this is browser chrome (a collapsing URL bar, a toolbar),
/// not a keyboard — treating those as an inset would make the layout jitter
/// while scrolling.
const double _minKeyboardHeight = 80;

void startKeyboardInsetTracking() {
  if (_started) return;
  _started = true;

  // visualViewport isn't exposed on dart:html's Window, so reach it through
  // js_util rather than adding a package:web dependency.
  final Object? viewport = js_util.getProperty(html.window, 'visualViewport');
  if (viewport == null) return;

  void update() {
    final num? layout = js_util.getProperty(html.window, 'innerHeight');
    final num? visual = js_util.getProperty(viewport, 'height');
    final num? offsetTop = js_util.getProperty(viewport, 'offsetTop');
    if (layout == null || visual == null) return;

    // The visual viewport is what the user actually sees. When the keyboard
    // opens it shrinks (and may be scrolled down within the layout viewport),
    // so whatever the layout viewport has left over is the covered strip.
    final covered = layout.toDouble() - visual.toDouble() - (offsetTop?.toDouble() ?? 0);
    keyboardInset.value = covered > _minKeyboardHeight ? covered : 0;
  }

  final listener = js_util.allowInterop((_) => update());
  js_util.callMethod(viewport, 'addEventListener', ['resize', listener]);
  js_util.callMethod(viewport, 'addEventListener', ['scroll', listener]);
  update();
}
