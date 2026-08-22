import 'package:flutter/widgets.dart';

import 'google_rendered_button_stub.dart'
    if (dart.library.js_interop) 'google_rendered_button_web.dart' as impl;

/// Google's own sign-in button, which the web SDK requires — it will not accept
/// a click synthesised from a Flutter widget. Returns null everywhere else, so
/// callers fall back to their own button and `GoogleSignInService.signIn()`.
///
/// [dark] picks between Google's two shipped palettes. The look is not ours to
/// design: Google's branding rules fix the mark, the wording, and the set of
/// themes, so matching the app means choosing the nearer of them rather than
/// styling the button.
Widget? googleRenderedButton({required bool dark}) =>
    impl.googleRenderedButton(dark: dark);
