import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/google_sign_in_web.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

/// The GSI button. Its result does not come back from here — the SDK reports it
/// on `GoogleSignIn.authenticationEvents`, which `GoogleSignInService` forwards
/// as `idTokens`.
///
/// Only the theme is chosen. Google ships three (outline, filled blue, filled
/// black) and permits no custom colours, so a dark app takes the black fill;
/// the white `outline` button that ships by default is the one that reads
/// correctly on a pale background and glares on a dark one.
Widget? googleRenderedButton({required bool dark}) => web.renderButton(
      configuration: GSIButtonConfiguration(
        theme: dark ? GSIButtonTheme.filledBlack : GSIButtonTheme.outline,
        size: GSIButtonSize.large,
        shape: GSIButtonShape.rectangular,
        text: GSIButtonText.continueWith,
      ),
    );
