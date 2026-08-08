import 'package:flutter/foundation.dart';

/// Required for a production web build. The deployment workflow injects the
/// HTTPS Lambda Function URL. Local development may instead point at the
/// backend running on the workstation.
///
/// Example: --dart-define=API_BASE_URL=http://192.168.x.x:8000
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

String get resolvedApiBaseUrl {
  if (apiBaseUrl.isNotEmpty) return apiBaseUrl;
  // Production web bundles must be built with API_BASE_URL. Keep the fallback
  // exclusively useful for local runs, where Flutter's dev server host is
  // reachable on port 8000. The CI/CD workflow validates and injects an HTTPS
  // value before it publishes any web bundle — this is a second line of
  // defense against a release build ever produced outside that pipeline (e.g.
  // a manual `flutter build` without --dart-define), which would otherwise
  // silently ship pointed at localhost/10.0.2.2 over plain HTTP. A plain
  // `assert` would be stripped from release binaries, so this throws instead.
  if (kReleaseMode) {
    throw StateError(
      'API_BASE_URL must be set via --dart-define for a release build.',
    );
  }
  // Flutter web must call the same host that served the app.  `localhost`
  // means the phone itself when a development server is opened through its
  // LAN address (e.g. http://192.168.x.x:5435), so requests never reach the
  // laptop backend in that case.
  if (kIsWeb) return 'http://${Uri.base.host}:8000';
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:8000';
  }
  return 'http://localhost:8000';
}

/// Turn backend relative paths (e.g. /static/audio/uuid.mp3) into full URLs.
String? resolveMediaUrl(String? path) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  final base = resolvedApiBaseUrl.replaceAll(RegExp(r'/$'), '');
  final rel = path.startsWith('/') ? path : '/$path';
  return '$base$rel';
}
