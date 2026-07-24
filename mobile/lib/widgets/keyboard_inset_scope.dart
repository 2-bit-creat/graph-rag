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

  /// `?kbdebug=1` in the URL overlays the raw viewport numbers. Diagnosing this
  /// needs the device's own readings — a desktop browser never reproduces it.
  static final bool _debugHud =
      Uri.base.queryParameters['kbdebug'] == '1';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: keyboardInset,
      builder: (context, inset, _) {
        Widget content = child;
        final media = MediaQuery.of(context);
        // Some browsers (measured: iOS 26 Safari) do report the keyboard to
        // Flutter already. Take whichever inset is larger rather than
        // substituting ours: never shrink a value the engine got right, and
        // never stack the two into a double-counted gap.
        final effective =
            inset > media.viewInsets.bottom ? inset : media.viewInsets.bottom;
        if (effective > 0) {
          content = MediaQuery(
            data: media.copyWith(
              viewInsets: media.viewInsets.copyWith(bottom: effective),
              // The keyboard covers the home indicator too, so its safe-area
              // padding would otherwise stack on top of the inset as dead space.
              padding: media.padding.copyWith(bottom: 0),
              viewPadding: media.viewPadding.copyWith(bottom: 0),
            ),
            child: child,
          );
        }
        if (!_debugHud) return content;
        return Stack(
          children: [content, _KeyboardDebugHud(inset: inset)],
        );
      },
    );
  }
}

/// Read-only overlay: browser numbers on top, what Flutter concluded below.
class _KeyboardDebugHud extends StatelessWidget {
  const _KeyboardDebugHud({required this.inset});

  final double inset;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: IgnorePointer(
        child: ValueListenableBuilder<String>(
          valueListenable: keyboardInsetDebug,
          builder: (context, raw, _) => Container(
            color: const Color(0xCC000000),
            padding: const EdgeInsets.fromLTRB(8, 28, 8, 6),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: Color(0xFF7CFF9E),
                fontSize: 11,
                height: 1.35,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(raw),
                  Text('dpr=${media.devicePixelRatio.toStringAsFixed(2)} '
                      'mqSize=${media.size.width.toStringAsFixed(0)}x'
                      '${media.size.height.toStringAsFixed(0)}'),
                  Text('injected=${inset.toStringAsFixed(0)} '
                      'mqInsetBottom=${media.viewInsets.bottom.toStringAsFixed(0)} '
                      'mqPadBottom=${media.padding.bottom.toStringAsFixed(0)}'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
