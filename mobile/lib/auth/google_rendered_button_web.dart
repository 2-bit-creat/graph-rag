import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

/// The GSI button. Its result does not come back from here — the SDK reports it
/// on `GoogleSignIn.authenticationEvents`, which `GoogleSignInService` forwards
/// as `idTokens`.
Widget? googleRenderedButton() => web.renderButton();
