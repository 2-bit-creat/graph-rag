import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'package:flutter/foundation.dart';

/// How many logical pixels at the bottom of the layout viewport are currently
/// covered by the on-screen keyboard. 0 when it is closed.
final ValueNotifier<double> keyboardInset = ValueNotifier<double>(0);

/// Raw viewport numbers behind [keyboardInset], surfaced by the `?kbdebug=1`
/// HUD. Mobile browsers disagree wildly about what the keyboard does to a
/// viewport, so this is the only way to see what a given device reports.
final ValueNotifier<String> keyboardInsetDebug = ValueNotifier<String>('-');

bool _started = false;

/// Anything below this is browser chrome (a collapsing URL bar, a toolbar),
/// not a keyboard — treating those as an inset would make the layout jitter
/// while scrolling.
const double _minKeyboardHeight = 80;

/// Whether the document's focused element is a text editor. Flutter web routes
/// text input through a real `<input>`/`<textarea>` in the DOM, so this is true
/// exactly when a Flutter text field (or a plain HTML one) holds focus.
bool _isEditingElementFocused() {
  final Object? active = js_util.getProperty(html.document, 'activeElement');
  if (active == null) return false;
  final tag =
      (js_util.getProperty(active, 'tagName') as String?)?.toUpperCase();
  if (tag == 'INPUT' || tag == 'TEXTAREA') return true;
  return js_util.getProperty(active, 'isContentEditable') == true;
}

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
    final num? scale = js_util.getProperty(viewport, 'scale');
    if (layout == null || visual == null) return;

    // The visual viewport is what the user actually sees. When the keyboard
    // opens it shrinks (and may be scrolled down within the layout viewport),
    // so whatever the layout viewport has left over is the covered strip.
    final covered =
        layout.toDouble() - visual.toDouble() - (offsetTop?.toDouble() ?? 0);

    // Pinch-zoom shrinks the visual viewport exactly like a keyboard does, and
    // at the top of the page offsetTop is 0, so the formula above would report
    // a keyboard that isn't there and shove the layout up. Zoom is the only
    // other thing that moves these numbers, so gate on it — and on something
    // actually being focused, since no keyboard opens without an editor.
    final zoomed = scale != null && scale.toDouble() > 1.01;
    final editing = _isEditingElementFocused();
    final open = !zoomed && editing && covered > _minKeyboardHeight;
    keyboardInset.value = open ? covered : 0;

    final scrollY = js_util.getProperty(html.window, 'scrollY') as num?;
    keyboardInsetDebug.value = 'inner=${layout.toStringAsFixed(0)} '
        'vv=${visual.toStringAsFixed(0)} '
        'off=${offsetTop?.toStringAsFixed(0) ?? '-'} '
        'scrollY=${scrollY?.toStringAsFixed(0) ?? '-'} '
        'covered=${covered.toStringAsFixed(0)} '
        'scale=${scale?.toStringAsFixed(2) ?? '-'} '
        'edit=$editing';
  }

  final listener = js_util.allowInterop((_) => update());
  js_util.callMethod(viewport, 'addEventListener', ['resize', listener]);
  js_util.callMethod(viewport, 'addEventListener', ['scroll', listener]);
  // Focus changes gate the measurement, so recompute on them too. Flutter web
  // focuses a real DOM input for text editing, so these fire for it.
  js_util.callMethod(html.document, 'addEventListener', ['focusin', listener]);
  js_util.callMethod(html.document, 'addEventListener', ['focusout', listener]);
  update();
}
