import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/picked_image_file.dart';

Uint8List _bytes(List<int> head, {int pad = 32}) =>
    Uint8List.fromList([...head, ...List<int>.filled(pad, 0)]);

final _jpeg = _bytes([0xFF, 0xD8, 0xFF, 0xE0]);
final _png = _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

void main() {
  group('sniffImageMime', () {
    test('recognises JPEG and PNG', () {
      expect(sniffImageMime(_jpeg), 'image/jpeg');
      expect(sniffImageMime(_png), 'image/png');
    });

    test('rejects formats Textract cannot read synchronously', () {
      // WEBP and GIF are real images; the sync DetectDocumentText API is
      // JPEG/PNG only, so they must not reach AWS.
      expect(sniffImageMime(_bytes([0x52, 0x49, 0x46, 0x46])), isNull);
      expect(sniffImageMime(_bytes([0x47, 0x49, 0x46, 0x38])), isNull);
      expect(sniffImageMime(_bytes([0x25, 0x50, 0x44, 0x46])), isNull);
    });

    test('does not read past the end of a truncated file', () {
      expect(sniffImageMime(Uint8List.fromList([0xFF, 0xD8])), isNull);
      expect(sniffImageMime(Uint8List(0)), isNull);
    });
  });

  group('rejectionFor', () {
    test('accepts a normal image', () {
      expect(rejectionFor(_jpeg), isNull);
    });

    test('flags empty, oversized, and unsupported bytes distinctly', () {
      expect(rejectionFor(Uint8List(0)), ImageRejection.empty);
      expect(
        rejectionFor(_bytes([0xFF, 0xD8, 0xFF], pad: maxImageBytes)),
        ImageRejection.tooLarge,
      );
      expect(
        rejectionFor(_bytes([0x52, 0x49, 0x46, 0x46])),
        ImageRejection.unsupportedFormat,
      );
    });

    test('size is checked before format, so a huge non-image reads as too large',
        () {
      expect(
        rejectionFor(Uint8List(maxImageBytes + 1)),
        ImageRejection.tooLarge,
      );
    });
  });

  group('pickedImageFromBytes', () {
    test('keeps the original filename when it already has an extension', () {
      final file = pickedImageFromBytes(name: 'page-3.jpg', bytes: _jpeg);
      expect(file!.name, 'page-3.jpg');
      expect(file.mimeType, 'image/jpeg');
    });

    test('appends an extension derived from the real bytes, not the name', () {
      // A PNG named without an extension must not be sent as .jpg.
      final file = pickedImageFromBytes(name: 'scan', bytes: _png);
      expect(file!.name, 'scan.png');
      expect(file.mimeType, 'image/png');
    });

    test('strips any directory component from the supplied name', () {
      final file = pickedImageFromBytes(
        name: r'C:\Users\me\Pictures\note.jpg',
        bytes: _jpeg,
      );
      expect(file!.name, 'note.jpg');
    });

    test('falls back to a default name when none is given', () {
      expect(pickedImageFromBytes(name: '  ', bytes: _png)!.name, 'scan.png');
    });

    test('returns null for anything rejectionFor would reject', () {
      expect(pickedImageFromBytes(name: 'x.gif', bytes: _bytes([0x47, 0x49, 0x46, 0x38])), isNull);
      expect(pickedImageFromBytes(name: 'x.jpg', bytes: Uint8List(0)), isNull);
    });
  });
}
