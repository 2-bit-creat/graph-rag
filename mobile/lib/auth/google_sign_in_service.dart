import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../api/config.dart';

/// Google sign-in, reduced to the one thing this app needs: an ID token to hand
/// to `POST /auth/google`.
///
/// Two platform facts shape everything here.
///
/// * **One client id, two roles.** Android must send the *web* client id as
///   `serverClientId` — Credential Manager mints the ID token with that as its
///   audience, so the backend allowlist needs the web id and not the Android
///   one. The Android OAuth client (package name + signing SHA-1) still has to
///   exist for the flow to run at all; it just never appears in the token. On
///   web the same id is passed as `clientId`.
/// * **Web has no `authenticate()`.** `google_sign_in_web` returns false from
///   `supportsAuthenticate()` and requires Google's own rendered button, which
///   reports its result through [GoogleSignIn.authenticationEvents] rather than
///   by returning it. So the token arrives on a stream, and the button-tap path
///   feeds the same stream to keep one code path for callers.
class GoogleSignInService {
  GoogleSignInService._();

  static final GoogleSignInService instance = GoogleSignInService._();

  Future<void>? _initialization;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  final StreamController<String> _idTokens = StreamController<String>.broadcast();

  /// ID tokens as sign-ins complete, from either platform path.
  Stream<String> get idTokens => _idTokens.stream;

  /// Whether this build was given a client id at all. False means the sign-in
  /// UI is not offered, rather than offered and failing on tap.
  bool get isConfigured => googleWebClientId.isNotEmpty;

  /// Whether the platform can start sign-in from our own button. False on web,
  /// where Google's rendered button must be shown instead.
  bool get supportsOwnButton =>
      isConfigured && GoogleSignIn.instance.supportsAuthenticate();

  Future<void> ensureInitialized() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    await GoogleSignIn.instance.initialize(
      clientId: kIsWeb ? googleWebClientId : null,
      serverClientId: kIsWeb ? null : googleWebClientId,
    );
    _events ??= GoogleSignIn.instance.authenticationEvents.listen(
      (GoogleSignInAuthenticationEvent event) {
        if (event is! GoogleSignInAuthenticationEventSignIn) return;
        final token = event.user.authentication.idToken;
        if (token != null && token.isNotEmpty) _idTokens.add(token);
      },
      onError: (Object error) => _idTokens.addError(error),
    );
  }

  /// Start the native account picker. Web callers must render Google's button
  /// instead and wait on [idTokens].
  ///
  /// Returns null when the user dismisses the picker — a cancel is not an
  /// error and must not surface as one.
  Future<String?> signIn() async {
    await ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw StateError('Google returned no ID token');
      }
      return token;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Forget the Google session so the next sign-in shows the account picker.
  /// Signing out of Daynode must not leave the device silently re-authenticating
  /// as the same person.
  Future<void> signOut() async {
    if (_initialization == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Best effort: our own session is already gone either way.
    }
  }
}
