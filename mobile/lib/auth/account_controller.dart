import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';

/// ID-entry accounts: no signup form, just a handle. Each handle maps to its own
/// backend space (JWT); bearer tokens are cached in platform secure storage
/// (Keychain/Keystore) so re-entering is one tap without leaving them in plaintext.
///
/// The reserved handle "main" opens the pre-existing local data.
class AccountController extends ChangeNotifier {
  final Map<String, String> _tokens = {}; // handle -> bearer token
  String? _current;

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

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
        await _refreshConsent();
      }
    } catch (_) {
      // Non-fatal — start with no accounts (entry screen will show).
    }
  }

  /// Enter (or create) a space by handle and make it current.
  Future<void> enter(String handle) async {
    final h = handle.trim().toLowerCase();
    final token = await apiClient.simpleLogin(h);
    _tokens[h] = token;
    _current = h;
    _resetConsent();
    setApiAuthToken(token);
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

final accountController = AccountController();
