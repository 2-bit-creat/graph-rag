import 'package:flutter/foundation.dart';

/// Override at build time: --dart-define=API_BASE_URL=http://192.168.x.x:8000
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

String get resolvedApiBaseUrl {
  if (apiBaseUrl.isNotEmpty) return apiBaseUrl;
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
