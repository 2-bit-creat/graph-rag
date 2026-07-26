import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/idempotency_key.dart';

void main() {
  test('creates non-empty, server-valid keys with web-safe random bounds', () {
    final random = Random(7);
    final keys = <String>{};

    for (var index = 0; index < 100; index++) {
      final key = newIdempotencyKey('manual', random: random);
      expect(key, startsWith('manual-'));
      expect(key.length, greaterThanOrEqualTo(8));
      keys.add(key);
    }

    expect(keys.length, 100);
  });

  test('supports retry prefixes', () {
    final key = newIdempotencyKey('retry-run-id', random: Random(1));
    expect(key, startsWith('retry-run-id-'));
    expect(key.length, greaterThanOrEqualTo(8));
  });
}
