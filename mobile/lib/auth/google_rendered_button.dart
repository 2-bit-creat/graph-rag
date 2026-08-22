import 'package:flutter/widgets.dart';

import 'google_rendered_button_stub.dart'
    if (dart.library.js_interop) 'google_rendered_button_web.dart' as impl;

/// Google's own sign-in button, which the web SDK requires (it will not accept
/// a click synthesised from a Flutter widget). Returns null everywhere else, so
/// callers fall back to their own button and `GoogleSignInService.signIn()`.
Widget? googleRenderedButton() => impl.googleRenderedButton();
