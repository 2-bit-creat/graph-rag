import 'package:flutter/foundation.dart';

/// Whether the browser considers this page a *secure context*.
///
/// Browsers gate the powerful APIs behind this: `getUserMedia` (the
/// microphone), the clipboard, and `flutter_secure_storage`'s web backend all
/// refuse to work — or are missing outright — on a plain-http origin that is
/// not localhost.
///
/// This is the exact shape of the dev setup here: `flutter build web` served
/// off the workstation and opened on a phone at `http://192.168.x.x:5435`.
/// There `navigator.mediaDevices` is not merely permission-denied, it is
/// *undefined*, and the record plugin's JS interop then fails with a bare
/// "type 'Null' is not a subtype of type 'JSObject'" that says nothing about
/// the actual cause.
///
/// Nothing in the app can lift this — it is a browser security rule, not a
/// permission prompt. The only fixes are serving over https, using a tunnel,
/// or opening the page on localhost. So the app's job is to detect it, say so
/// plainly, and not offer controls that cannot work.
bool get isSecureBrowserContext {
  if (!kIsWeb) return true;
  final u = Uri.base;
  return u.scheme == 'https' ||
      u.host == 'localhost' ||
      u.host == '127.0.0.1' ||
      u.host == '::1';
}

/// True when the microphone cannot work at all on this origin, regardless of
/// what the user allows in the permission prompt.
bool get isMicrophoneBlockedByOrigin => kIsWeb && !isSecureBrowserContext;
