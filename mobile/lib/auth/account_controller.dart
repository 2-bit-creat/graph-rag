import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';

/// ID-entry accounts: no signup form, just a handle. Each handle maps to its own
/// backend space (JWT); tokens are cached locally so re-entering is one tap.
///
/// The reserved handle "main" opens the pre-existing local data.
class AccountController extends ChangeNotifier {
  final Map<String, String> _tokens = {}; // handle -> bearer token
  String? _current;

  static const _tokensKey = 'account_tokens';
  static const _currentKey = 'account_current';

  List<String> get handles => _tokens.keys.toList()..sort();
  String? get current => _current;
  bool get hasAccount => _current != null && _tokens[_current] != null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tokensKey);
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
    setApiAuthToken(token);
    await _persist();
    notifyListeners();
  }

  /// Switch to an already-saved account (re-uses its cached token).
  Future<void> switchTo(String handle) async {
    if (!_tokens.containsKey(handle)) {
      await enter(handle);
      return;
    }
    _current = handle;
    setApiAuthToken(_tokens[handle]);
    await _persist();
    notifyListeners();
  }

  /// Remove an account from this device (keeps its server data).
  Future<void> forget(String handle) async {
    _tokens.remove(handle);
    if (_current == handle) {
      _current = null;
      setApiAuthToken(null);
    }
    await _persist();
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
    setApiAuthToken(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_currentKey);
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokensKey, jsonEncode(_tokens));
    if (_current != null) {
      await prefs.setString(_currentKey, _current!);
    } else {
      await prefs.remove(_currentKey);
    }
  }
}

final accountController = AccountController();
