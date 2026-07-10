import 'package:flutter/material.dart';

import '../api/client.dart';

/// Drives UI locale from the user's profile `native_language`.
class NativeLanguageController extends ChangeNotifier {
  NativeLanguageController({String nativeLanguage = 'korean'})
      : _nativeLanguage = nativeLanguage;

  String _nativeLanguage;

  String get nativeLanguage => _nativeLanguage;

  Locale get locale =>
      _nativeLanguage == 'english' ? const Locale('en') : const Locale('ko');

  Future<void> loadFromProfile() async {
    try {
      final profile = await apiClient.getQuizProfile();
      final raw = profile['native_language']?.toString() ?? 'korean';
      if (raw != _nativeLanguage) {
        _nativeLanguage = raw;
        notifyListeners();
      }
    } catch (_) {}
  }

  void setNativeLanguage(String code) {
    final next = code.trim().toLowerCase();
    if (next == _nativeLanguage) return;
    _nativeLanguage = next;
    notifyListeners();
  }
}

class NativeLanguageScope extends InheritedNotifier<NativeLanguageController> {
  const NativeLanguageScope({
    super.key,
    required NativeLanguageController controller,
    required super.child,
  }) : super(notifier: controller);

  static NativeLanguageController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<NativeLanguageScope>();
    assert(scope != null, 'NativeLanguageScope not found');
    return scope!.notifier!;
  }
}
