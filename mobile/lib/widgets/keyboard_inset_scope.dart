import 'package:flutter/material.dart';

import '../utils/keyboard_inset.dart';

/// Folds the web-measured keyboard height into `MediaQuery.viewInsets` so the
/// whole app can keep asking Flutter for the inset the normal way.
///
/// Without this, every `MediaQuery.viewInsetsOf(context).bottom` in the app
/// reads 0 on mobile web and the keyboard covers whatever is at the bottom of
/// the screen — the chat feed, the composer, bottom sheets. Injecting it once at
/// the root fixes all of them at the same time instead of patching each surface.
///
/// The measured value is *substituted*, not added: on native the notifier is
/// always 0 and Flutter's own inset passes through unchanged, and on web
/// Flutter's value is the one that's wrong.
class KeyboardInsetScope extends StatelessWidget {
  const KeyboardInsetScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: keyboardInset,
      builder: (context, inset, _) {
        if (inset <= 0) return child;
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            viewInsets: media.viewInsets.copyWith(bottom: inset),
            // The keyboard covers the home indicator too, so its safe-area
            // padding would otherwise stack on top of the inset as dead space.
            padding: media.padding.copyWith(bottom: 0),
            viewPadding: media.viewPadding.copyWith(bottom: 0),
          ),
          child: child,
        );
      },
    );
  }
}
