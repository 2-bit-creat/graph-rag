import 'dart:js_util' as js_util;

dynamic _dartify(dynamic value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map || value is List) return value;
  return js_util.dartify(value);
}

Map<String, dynamic> jsonMap(dynamic value) {
  final dartValue = _dartify(value);
  if (dartValue is Map<String, dynamic>) return dartValue;
  if (dartValue is Map) return dartValue.cast<String, dynamic>();
  throw FormatException('Expected a JSON object, got ${value.runtimeType}');
}

dynamic jsonValue(dynamic value) => _dartify(value);
