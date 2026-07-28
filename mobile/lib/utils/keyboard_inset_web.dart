import 'dart:html' as html;

import 'package:flutter/foundation.dart';

/// Flutter's MediaQuery supplies the authoritative IME inset. This notifier is
/// retained for the optional keyboard-debug HUD on Flutter web.
final ValueNotifier<double> keyboardInset = ValueNotifier<double>(0);
final ValueNotifier<String> keyboardInsetDebug = ValueNotifier<String>('-');

bool _started = false;

void startKeyboardInsetTracking() {
  if (_started) return;
  _started = true;

  void update() {
    final height = html.window.innerHeight;
    keyboardInset.value = 0;
    keyboardInsetDebug.value =
        'inner=${height?.toStringAsFixed(0) ?? '-'} media-query';
  }

  html.window.onResize.listen((_) => update());
  update();
}
