/// Keyboard height, measured for platforms where Flutter can't report it.
///
/// On native, `MediaQuery.viewInsets.bottom` already shrinks the layout when the
/// IME opens. On web it does not: mobile Safari leaves the *layout* viewport at
/// full height and only shrinks the *visual* viewport, so Flutter sees no inset
/// and the keyboard sits on top of the UI. The web implementation derives the
/// covered height from `window.visualViewport`; the stub reports 0 so native
/// builds keep using Flutter's own value untouched.
library;

export 'keyboard_inset_stub.dart'
    if (dart.library.js_util) 'keyboard_inset_web.dart';
