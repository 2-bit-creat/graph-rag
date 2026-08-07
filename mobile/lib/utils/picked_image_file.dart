import 'dart:typed_data';

/// An image chosen for OCR. Always carries bytes: the backend takes a multipart
/// upload, and on web there is no path to read from anyway.
class PickedImageFile {
  const PickedImageFile({
    required this.name,
    required this.bytes,
    required this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;
}

/// Textract's synchronous DetectDocumentText takes JPEG and PNG only. Keeping
/// this list in step with `backend/app/routers/ocr.py` is what stops a picked
/// WEBP from travelling all the way to AWS just to come back a 415.
const imageFileExtensions = ['jpg', 'jpeg', 'png'];

/// Max upload size, mirroring MAX_IMAGE_BYTES on the server.
const maxImageBytes = 5 * 1024 * 1024;

/// Identify an image from its magic bytes, or null when it is not one we send.
///
/// The filename extension is not trusted: a photo exported as `.jpg` by one app
/// and re-encoded by another is a routine way for the two to disagree, and the
/// server sniffs the bytes regardless — so failing here gives a better message
/// than failing there.
String? sniffImageMime(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return 'image/png';
  }
  return null;
}

/// Why a picked file cannot be sent, or null when it can.
enum ImageRejection { empty, tooLarge, unsupportedFormat }

ImageRejection? rejectionFor(Uint8List bytes) {
  if (bytes.isEmpty) return ImageRejection.empty;
  if (bytes.length > maxImageBytes) return ImageRejection.tooLarge;
  if (sniffImageMime(bytes) == null) return ImageRejection.unsupportedFormat;
  return null;
}

/// Build a sendable image, or null if [rejectionFor] would reject the bytes.
PickedImageFile? pickedImageFromBytes({
  required String name,
  required Uint8List bytes,
}) {
  final mime = sniffImageMime(bytes);
  if (mime == null || bytes.isEmpty || bytes.length > maxImageBytes) return null;

  final trimmed = name.trim().replaceAll('\\', '/').split('/').last;
  final ext = mime == 'image/png' ? 'png' : 'jpg';
  final resolved = trimmed.isEmpty
      ? 'scan.$ext'
      : (trimmed.contains('.') ? trimmed : '$trimmed.$ext');

  return PickedImageFile(name: resolved, bytes: bytes, mimeType: mime);
}
