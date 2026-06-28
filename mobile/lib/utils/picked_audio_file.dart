import 'dart:typed_data';

class PickedAudioFile {
  const PickedAudioFile({
    required this.name,
    this.bytes,
    this.path,
  });

  final String name;
  final Uint8List? bytes;
  final String? path;
}

const audioFileExtensions = [
  'wav',
  'mp3',
  'm4a',
  'aac',
  'ogg',
  'webm',
  'flac',
];

const _mimeToExtension = <String, String>{
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/wave': 'wav',
  'audio/vnd.wave': 'wav',
  'audio/mpeg': 'mp3',
  'audio/mp3': 'mp3',
  'audio/mp4': 'm4a',
  'audio/x-m4a': 'm4a',
  'audio/aac': 'aac',
  'audio/ogg': 'ogg',
  'audio/webm': 'webm',
  'audio/flac': 'flac',
  'audio/x-flac': 'flac',
};

String? extensionFromMime(String? mimeType) {
  if (mimeType == null || mimeType.isEmpty) return null;
  final mime = mimeType.toLowerCase().split(';').first.trim();
  if (_mimeToExtension.containsKey(mime)) {
    return _mimeToExtension[mime];
  }
  if (mime.startsWith('audio/')) {
    final tail = mime.substring('audio/'.length);
    if (audioFileExtensions.contains(tail)) return tail;
  }
  return null;
}

bool isSupportedAudioFilename(String name) {
  final normalized = normalizeDroppedFilename(name);
  final dot = normalized.lastIndexOf('.');
  if (dot < 0 || dot >= normalized.length - 1) return false;
  final ext = normalized.substring(dot + 1).toLowerCase();
  return audioFileExtensions.contains(ext);
}

bool isSupportedAudioFile(String name, {String? mimeType}) {
  if (isSupportedAudioFilename(name)) return true;
  if (extensionFromMime(mimeType) != null) return true;
  final mime = (mimeType ?? '').toLowerCase().split(';').first.trim();
  return mime == 'application/octet-stream' && isSupportedAudioFilename(name);
}

String normalizeDroppedFilename(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  final normalized = trimmed.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  if (slash >= 0 && slash < normalized.length - 1) {
    return normalized.substring(slash + 1);
  }
  return trimmed;
}

String resolveAudioFilename(String name, {String? mimeType, String? sniffedExt}) {
  final trimmed = normalizeDroppedFilename(name);
  if (isSupportedAudioFilename(trimmed)) return trimmed;

  final ext = extensionFromMime(mimeType) ?? sniffedExt ?? 'wav';
  if (trimmed.isEmpty) return 'upload.$ext';
  if (!trimmed.contains('.')) return '$trimmed.$ext';
  return trimmed;
}

PickedAudioFile? pickedAudioFromBytes({
  required String name,
  String? mimeType,
  required Uint8List bytes,
  String? path,
}) {
  if (bytes.isEmpty) return null;

  final normalizedName = normalizeDroppedFilename(name);
  final sniffed = sniffAudioExtension(bytes);
  if (sniffed != null) {
    final resolvedName = resolveAudioFilename(
      normalizedName,
      mimeType: mimeType,
      sniffedExt: sniffed,
    );
    return PickedAudioFile(name: resolvedName, bytes: bytes, path: path);
  }

  final resolvedName = resolveAudioFilename(
    normalizedName,
    mimeType: mimeType,
  );
  if (!isSupportedAudioFile(normalizedName, mimeType: mimeType) &&
      !isSupportedAudioFilename(resolvedName)) {
    return null;
  }

  return PickedAudioFile(name: resolvedName, bytes: bytes, path: path);
}

String? sniffAudioExtension(Uint8List bytes) {
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x41 &&
      bytes[10] == 0x56 &&
      bytes[11] == 0x45) {
    return 'wav';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x49 &&
      bytes[1] == 0x44 &&
      bytes[2] == 0x33) {
    return 'mp3';
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
    return 'mp3';
  }
  if (bytes.length >= 8 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12.clamp(0, bytes.length)));
    if (brand.startsWith('M4A') || brand.startsWith('mp4')) return 'm4a';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x4F &&
      bytes[1] == 0x67 &&
      bytes[2] == 0x67 &&
      bytes[3] == 0x53) {
    return 'ogg';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x66 &&
      bytes[1] == 0x4C &&
      bytes[2] == 0x61 &&
      bytes[3] == 0x43) {
    return 'flac';
  }
  return null;
}
