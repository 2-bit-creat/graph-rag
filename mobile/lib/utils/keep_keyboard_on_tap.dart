import 'dart:ui' show Rect;

export 'keep_keyboard_on_tap_stub.dart'
    if (dart.library.js_interop) 'keep_keyboard_on_tap_web.dart';

/// Keeps the on-screen keyboard up while the user taps a Flutter-drawn overlay.
///
/// The problem is not Flutter's, it is the DOM's. Flutter web keeps a real,
/// invisible `<textarea>` behind the focused field — that element is what owns
/// the browser's focus, drives the IME, and therefore decides whether the
/// keyboard is up. Everything Flutter paints, including an autocomplete popup,
/// is pixels on a `<canvas>`. Tapping those pixels is, to the browser, a tap
/// outside the textarea, so it blurs it and iOS takes the keyboard down. This
/// was confirmed by elimination: selecting the same popup row with the Enter key
/// never closed the keyboard, only tapping it did.
///
/// [TextFieldTapRegion] cannot help here. It governs Flutter's own focus
/// bookkeeping, and the blur has already happened a layer below it.
///
/// The fix is the standard one for custom dropdowns over a text input on the
/// web: cancel the default action of the pointer-down that would move focus.
/// A capture-phase listener installed in web/index.html calls preventDefault()
/// when the press lands inside the rectangle published here, so the textarea
/// never loses focus and the keyboard never animates away.
///
/// A no-op everywhere except web — on iOS and Android the keyboard is not tied
/// to a DOM element and none of this applies.
///
/// Publish the overlay's screen rect while it is open, and clear it when it
/// closes. Leaving a stale rect behind would swallow presses over a region with
/// nothing in it.
typedef KeepKeyboardRectSetter = void Function(Rect? rect);
