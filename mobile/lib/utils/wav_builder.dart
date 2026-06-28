import 'dart:typed_data';

/// Build a mono/stereo 16-bit PCM WAV from raw PCM bytes.
Uint8List buildWavFromPcm(
  Uint8List pcm, {
  int sampleRate = 16000,
  int numChannels = 1,
}) {
  const bitsPerSample = 16;
  const headerSize = 44;
  final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
  final blockAlign = numChannels * (bitsPerSample ~/ 8);

  final header = ByteData(headerSize);
  void writeString(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  header.setUint32(4, headerSize + pcm.length - 8, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, numChannels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  writeString(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);

  return Uint8List.fromList(header.buffer.asUint8List() + pcm);
}

int? wavDurationMs(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final byteRate = bytes[28] |
      (bytes[29] << 8) |
      (bytes[30] << 16) |
      (bytes[31] << 24);
  if (byteRate <= 0) return null;
  var dataSize = bytes.length - 44;
  for (var i = 12; i + 8 < bytes.length; ) {
    final id = String.fromCharCodes(bytes.sublist(i, i + 4));
    final size = bytes[i + 4] |
        (bytes[i + 5] << 8) |
        (bytes[i + 6] << 16) |
        (bytes[i + 7] << 24);
    if (id == 'data') {
      dataSize = size;
      break;
    }
    i += 8 + size;
  }
  return (dataSize * 1000 / byteRate).round();
}

String formatDuration(int totalSeconds) {
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
