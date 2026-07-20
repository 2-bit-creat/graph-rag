Map<String, dynamic> jsonMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  throw FormatException('Expected a JSON object, got ${value.runtimeType}');
}

dynamic jsonValue(dynamic value) => value;
