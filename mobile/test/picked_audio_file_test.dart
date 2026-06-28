import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/picked_audio_file.dart';

void main() {
  test('accepts wav extension', () {
    expect(isSupportedAudioFile('test.wav'), isTrue);
    expect(resolveAudioFilename('clip.WAV'), 'clip.WAV');
  });

  test('accepts audio mime without extension', () {
    expect(isSupportedAudioFile('', mimeType: 'audio/wav'), isTrue);
    expect(isSupportedAudioFile('recording', mimeType: 'audio/wave'), isTrue);
    expect(resolveAudioFilename('', mimeType: 'audio/wav'), 'upload.wav');
    expect(resolveAudioFilename('foo', mimeType: 'audio/mpeg'), 'foo.mp3');
  });

  test('rejects unknown types', () {
    expect(isSupportedAudioFile('notes.txt'), isFalse);
    expect(isSupportedAudioFile('', mimeType: 'text/plain'), isFalse);
  });

  test('sniffs wav header without extension', () {
    final bytes = Uint8List.fromList([
      0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
      0x57, 0x41, 0x56, 0x45,
    ]);
    expect(sniffAudioExtension(bytes), 'wav');
    final picked = pickedAudioFromBytes(name: '', bytes: bytes);
    expect(picked?.name, 'upload.wav');
  });

  test('normalizes windows path filenames', () {
    expect(normalizeDroppedFilename(r'C:\Users\test\clip.wav'), 'clip.wav');
    expect(isSupportedAudioFile(r'C:\Users\test\clip.wav'), isTrue);
  });
}
