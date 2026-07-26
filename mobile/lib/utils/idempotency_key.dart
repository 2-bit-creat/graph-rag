import 'dart:math';

/// Generates a client request key safe for Dart VM and dart2js.
///
/// JavaScript bit shifts are 32-bit and make `1 << 32` evaluate to zero, so
/// keep [Random.nextInt] below its documented cross-platform upper bound.
String newIdempotencyKey(String prefix, {Random? random}) {
  final entropy = (random ?? Random()).nextInt(0x7fffffff).toRadixString(16);
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$entropy';
}
