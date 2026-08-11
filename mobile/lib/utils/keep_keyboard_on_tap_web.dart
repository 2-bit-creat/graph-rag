import 'dart:js_interop';
import 'dart:ui' show Rect;

/// Installed by web/index.html. Kept as a loose lookup rather than a hard
/// binding so an older index.html (a cached shell, a stale service worker)
/// degrades to today's behaviour instead of throwing on every popup.
@JS('__keepKeyboardOverRect')
external JSFunction? get _setRect;

/// Publish the rectangle that must not steal DOM focus, or null to clear it.
///
/// Coordinates are Flutter logical pixels, which on web are CSS pixels — the
/// same space the listener compares `event.clientX/clientY` against.
void keepKeyboardOverRect(Rect? rect) {
  final fn = _setRect;
  if (fn == null) return;
  if (rect == null) {
    fn.callAsFunction(null);
    return;
  }
  fn.callAsFunction(
    null,
    rect.left.toJS,
    rect.top.toJS,
    rect.right.toJS,
    rect.bottom.toJS,
  );
}
