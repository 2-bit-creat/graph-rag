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
      // authenticate() reports a failure BOTH by throwing and by putting the
      // raw exception on this stream, so the classification has to happen here
      // too — otherwise the stream path races the thrown one and wins, and the
      // UI shows Google's developer-facing text after all.
      onError: (Object error) => _idTokens.addError(
        error is GoogleSignInException
            ? GoogleSignInFailure(_classify(error))
            : error,
      ),
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
        throw const GoogleSignInFailure(GoogleSignInProblem.noToken);
      }
      return token;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw GoogleSignInFailure(_classify(e));
    }
  }

  /// Turn the SDK's exception into something the UI can phrase for a person.
  ///
  /// The raw exception is developer text — "GoogleSignInException(code
  /// GoogleSignInExceptionCode.unknownError, No credential available: ...)" —
  /// and showing it verbatim tells the user nothing they can act on.
  ///
  /// The awkward case is a device with no Google account: Android reports it as
  /// `unknownError` with "No credential available" in the description, so the
  /// only way to distinguish it from a genuine fault is that string. It is
  /// worth doing, because the fix ("add a Google account") is entirely in the
  /// user's hands and is otherwise unguessable.
  static GoogleSignInProblem _classify(GoogleSignInException e) {
    final description = (e.description ?? '').toLowerCase();
    if (description.contains('no credential')) {
      return GoogleSignInProblem.noGoogleAccountOnDevice;
    }
    switch (e.code) {
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return GoogleSignInProblem.misconfigured;
      case GoogleSignInExceptionCode.interrupted:
      case GoogleSignInExceptionCode.uiUnavailable:
        return GoogleSignInProblem.interrupted;
      default:
        return GoogleSignInProblem.unknown;
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

/// Why a Google sign-in attempt did not produce a token.
enum GoogleSignInProblem {
  /// The device has no Google account at all. Common on a fresh emulator.
  noGoogleAccountOnDevice,

  /// The OAuth client does not match this build — wrong package name, or a
  /// signing certificate whose SHA-1 is not registered. Note that a release
  /// build signed by Play uses a DIFFERENT certificate than the upload key, so
  /// both fingerprints have to be registered.
  misconfigured,

  /// Something took the flow away before it finished.
  interrupted,

  /// Google reported success but handed back no ID token.
  noToken,

  unknown,
}

/// A sign-in failure already reduced to a cause the UI can phrase.
class GoogleSignInFailure implements Exception {
  const GoogleSignInFailure(this.problem);

  final GoogleSignInProblem problem;
}
