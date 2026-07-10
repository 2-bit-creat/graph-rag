import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';

const _deviceIdKey = 'device_id';
const _authTokenKey = 'auth_token';

/// True when a JWT is loaded and attached to [apiClient].
bool deviceAuthReady = false;

String _newDeviceId() {
  final r = Random();
  final hex = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  return 'device-$hex';
}

/// Ensure the app has a device id and JWT. Never throws ??returns false when
/// the server is unreachable (app can still start; retry after server is up).
Future<bool> ensureDeviceAuth() async {
  final prefs = await SharedPreferences.getInstance();
  var deviceId = prefs.getString(_deviceIdKey);
  if (deviceId == null || deviceId.isEmpty) {
    deviceId = _newDeviceId();
    await prefs.setString(_deviceIdKey, deviceId);
  }

  final existingToken = prefs.getString(_authTokenKey);
  if (existingToken != null && existingToken.isNotEmpty) {
    apiClient.setAuthToken(existingToken);
    deviceAuthReady = true;
    return true;
  }

  try {
    final token = await apiClient.authenticateDevice(deviceId);
    await prefs.setString(_authTokenKey, token);
    apiClient.setAuthToken(token);
    deviceAuthReady = true;
    return true;
  } catch (_) {
    deviceAuthReady = false;
    return false;
  }
}

/// Drop cached JWT (e.g. after changing server URL) and fetch a new one.
Future<bool> refreshDeviceAuth() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_authTokenKey);
  apiClient.clearAuthToken();
  deviceAuthReady = false;
  return ensureDeviceAuth();
}
