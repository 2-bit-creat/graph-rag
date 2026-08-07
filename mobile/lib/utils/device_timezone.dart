import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

/// The device's IANA timezone name ("Asia/Seoul", "Europe/Berlin"), or null if
/// the platform won't tell us.
///
/// Dart's own `DateTime` exposes only a UTC offset and a localized abbreviation
/// ("KST", "대한민국 표준시"), neither of which the server can resolve into a real
/// zone — and an offset alone can't express DST rules. The server needs the IANA
/// id to decide when the learner's day rolls over, which is what streaks, the
/// daily goal reset, and the daily XP cap all key off.
Future<String?> deviceTimezoneName() async {
  try {
    final id = (await FlutterTimezone.getLocalTimezone()).trim();
    return id.isEmpty ? null : id;
  } catch (error) {
    // Never fatal: the server keeps whatever zone it already had.
    debugPrint('timezone detection failed: $error');
    return null;
  }
}
