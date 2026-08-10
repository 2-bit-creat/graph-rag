import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../chat/chat_session_controller.dart';

/// ID-entry accounts: no signup form, just a handle. Each handle maps to its own
/// backend space (JWT); bearer tokens are cached in platform secure storage
/// (Keychain/Keystore) so re-entering is one tap without leaving them in plaintext.
///
/// The reserved handle "main" opens the pre-existing local data.
class AccountController extends ChangeNotifier {
  final Map<String, String> _tokens = {}; // handle -> bearer token
  String? _current;

  static const _TokenStore _secure = _TokenStore();

  // Consent state for the current account, fetched from /auth/me. `_consentKnown`
  // gates the app until we know whether the onboarding consent is needed.
  bool _consentKnown = false;
  bool _consented = false;
  bool _speakerIdConsent = false;

  static const _tokensKey = 'account_tokens';
  static const _currentKey = 'account_current';

  List<String> get handles => _tokens.keys.toList()..sort();
  String? get current => _current;
  bool get hasAccount => _current != null && _tokens[_current] != null;

  bool get consentKnown => _consentKnown;
  bool get needsConsent => hasAccount && _consentKnown && !_consented;
  bool get speakerIdConsent => _speakerIdConsent;

  // Whether this account may open the operator/developer tools. The answer
  // comes from the server (LearningProfileOut.is_operator); the app used to
  // decide it locally with `current == 'main'`, so anyone who signed in under
  // that handle got pipeline traces and account administration. Defaults to
  // false so the tools stay hidden until the server has said otherwise.
  bool _isOperator = false;
  bool get isOperator => hasAccount && _isOperator;

  /// Records the server's answer for the account that is currently entered.
  void setOperator(bool value) {
    if (_isOperator == value) return;
    _isOperator = value;
    notifyListeners();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? raw = await _secure.read(key: _tokensKey);
      if (raw == null) {
        // One-time migration: move tokens out of plaintext shared_preferences.
        final legacy = prefs.getString(_tokensKey);
        if (legacy != null) {
          raw = legacy;
          await _secure.write(key: _tokensKey, value: legacy);
          await prefs.remove(_tokensKey);
        }
      }
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _tokens
          ..clear()
          ..addAll(decoded.map((k, v) => MapEntry(k, v.toString())));
      }
      final cur = prefs.getString(_currentKey);
      if (cur != null && _tokens.containsKey(cur)) {
        _current = cur;
        setApiAuthToken(_tokens[cur]);
        // Deliberately NOT awaited: main() gates runApp() on load(), so
        // awaiting a network round trip here held back the very first frame and
        // the launch was a blank window until /auth/me answered. The app
        // already renders a splash for `!consentKnown`, and _refreshConsent
        // notifies when it lands, so let the UI come up now and resolve consent
        // behind it.
        unawaited(_refreshConsent());
      }
    } catch (_) {
      // Non-fatal — start with no accounts (entry screen will show).
    }
  }

  /// Enter a space by handle and make it current. [create] must be true
  /// (the default) only for the developer "create account" tool — the plain
  /// entry screen passes false so an unregistered handle 404s instead of
  /// creating a new account from the login screen.
  Future<void> enter(String handle,
      {String? nativeLanguage, bool create = true}) async {
    final h = handle.trim().toLowerCase();
    final token = await apiClient.simpleLogin(h,
        nativeLanguage: nativeLanguage, create: create);
    _tokens[h] = token;
    _current = h;
    _resetConsent();
    setApiAuthToken(token);
    // chatSession is a single app-wide singleton keyed by nothing but "the
    // current account" — without this it keeps showing the PREVIOUS
    // account's rooms/messages after a switch, since its init() is a
    // one-shot guard that silently no-ops on the new account's remount.
    chatSession.reset();
    await _persist();
    notifyListeners();
    await _refreshConsent();
  }

  /// Switch to an already-saved account (re-uses its cached token).
  Future<void> switchTo(String handle) async {
    if (!_tokens.containsKey(handle)) {
      await enter(handle);
      return;
    }
    _current = handle;
    _resetConsent();
    setApiAuthToken(_tokens[handle]);
    chatSession.reset();
    await _persist();
    notifyListeners();
    await _refreshConsent();
  }

  /// Remove an account from this device (keeps its server data).
  Future<void> forget(String handle) async {
    _tokens.remove(handle);
    if (_current == handle) {
      _current = null;
      _resetConsent();
      setApiAuthToken(null);
    }
    await _persist();
    notifyListeners();
  }

  // ── Consent ────────────────────────────────────────────────────────────────

  void _resetConsent() {
    _consentKnown = false;
    _consented = false;
    _speakerIdConsent = false;
    // Operator access belongs to the account that was entered, so switching or
    // signing out must drop it rather than carry it into the next space.
    _isOperator = false;
  }

  /// Fetch consent state for the current account; never locks the user out on a
  /// transient failure.
  Future<void> _refreshConsent() async {
    if (!hasAccount) return;
    try {
      final me = await apiClient.getMe();
      _consented = me['consented_at'] != null;
      _speakerIdConsent = me['speaker_id_consent_at'] != null;
    } catch (_) {
      _consented = true; // already authenticated; re-checked next launch
      _speakerIdConsent = false;
    } finally {
      _consentKnown = true;
      notifyListeners();
    }
  }

  /// Called by the consent screen once /auth/consent succeeds.
  void markConsented({required bool speakerIdConsent}) {
    _consented = true;
    _speakerIdConsent = speakerIdConsent;
    _consentKnown = true;
    notifyListeners();
  }

  /// Reflect a speaker-id consent toggle made from settings.
  void setSpeakerIdConsent(bool value) {
    _speakerIdConsent = value;
    notifyListeners();
  }

  /// Delete the account's server data (must be the current account) and forget it.
  Future<void> deleteCurrentServerSide() async {
    final h = _current;
    if (h == null) return;
    await apiClient.deleteAccount();
    await forget(h);
  }

  /// Sign out of the current account without deleting anything.
  Future<void> signOut() async {
    _current = null;
    _resetConsent();
    setApiAuthToken(null);
    chatSession.reset();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_currentKey);
    notifyListeners();
  }

  Future<void> _persist() async {
    // Bearer tokens → secure storage; the (non-secret) current handle → prefs.
    await _secure.write(key: _tokensKey, value: jsonEncode(_tokens));
    final prefs = await SharedPreferences.getInstance();
    if (_current != null) {
      await prefs.setString(_currentKey, _current!);
    } else {
      await prefs.remove(_currentKey);
    }
  }
}

/// Secure storage with a web fallback.
///
/// `flutter_secure_storage`'s web backend only works in a secure context
/// (https, or localhost). Serving the dev build over plain http to a phone on
/// the hotspot LAN (e.g. http://172.20.10.6:5435) is *not* a secure context, so
/// every read/write throws and the entry screen can never save a token. There
/// we fall back to `shared_preferences` (localStorage) using the same key, so
/// the value round-trips and the later migration path is a no-op.
///
/// Native platforms always get the real Keychain/Keystore.
class _TokenStore {
  const _TokenStore();

  static bool get _fallback => kIsWeb && !_isSecureContext;

  static bool get _isSecureContext {
    final u = Uri.base;
    return u.scheme == 'https' ||
        u.host == 'localhost' ||
        u.host == '127.0.0.1';
  }

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  Future<String?> read({required String key}) async {
    if (_fallback) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    }
    return _secure.read(key: key);
  }

  Future<void> write({required String key, required String value}) async {
    if (_fallback) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
      return;
    }
    await _secure.write(key: key, value: value);
  }
}

final accountController = AccountController();
