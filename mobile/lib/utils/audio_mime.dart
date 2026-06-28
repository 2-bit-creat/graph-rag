String audioMimeTypeForFilename(String filename) {
  final ext = filename.contains('.')
      ? filename.split('.').last.toLowerCase()
      : '';
  switch (ext) {
    case 'wav':
      return 'audio/wav';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
    case 'mp4':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'ogg':
      return 'audio/ogg';
    case 'webm':
      return 'audio/webm';
    case 'flac':
      return 'audio/flac';
    default:
      return 'application/octet-stream';
  }
}
