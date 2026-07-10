import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-selected appearance ??independent of OS system theme, persisted across
/// launches via [SharedPreferences].
class AppThemeController extends ChangeNotifier {
  AppThemeController._();

  static final AppThemeController instance = AppThemeController._();

  static const _prefsKey = 'app_theme_mode';

  ThemeMode _mode = ThemeMode.dark;

  ThemeMode get mode => _mode;

  bool get isDark => _mode == ThemeMode.dark;

  /// Restore the saved choice. Call once before runApp; silently keeps the
  /// dark default if storage is unavailable.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      switch (prefs.getString(_prefsKey)) {
        case 'light':
          _mode = ThemeMode.light;
        case 'dark':
          _mode = ThemeMode.dark;
      }
      notifyListeners();
    } catch (_) {
      // Non-fatal ??fall back to the in-memory default.
    }
  }

  void setMode(ThemeMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    _persist();
  }

  void toggle() {
    setMode(isDark ? ThemeMode.light : ThemeMode.dark);
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, isDark ? 'dark' : 'light');
    } catch (_) {
      // Best-effort ??a failed write just means the choice isn't remembered.
    }
  }
}

final appThemeController = AppThemeController.instance;
