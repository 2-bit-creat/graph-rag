import 'package:flutter/foundation.dart';

/// Always 0 on native — Flutter's own `MediaQuery.viewInsets` is authoritative
/// there, and adding to it would double-count the keyboard.
final ValueNotifier<double> keyboardInset = ValueNotifier<double>(0);

void startKeyboardInsetTracking() {}
