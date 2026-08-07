import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'picked_image_file.dart';

export 'picked_image_file.dart';

/// Outcome of [pickImageFile]. A cancel and a rejection both produce no file,
/// but only one of them should raise an error to the learner — collapsing them
/// into a bare null makes "you closed the picker" indistinguishable from "that
/// photo is 12MB".
class ImagePickResult {
  const ImagePickResult.cancelled()
      : file = null,
        rejection = null;
  const ImagePickResult.rejected(this.rejection) : file = null;
  const ImagePickResult.picked(PickedImageFile this.file) : rejection = null;

  final PickedImageFile? file;
  final ImageRejection? rejection;

  bool get isCancelled => file == null && rejection == null;
}

/// Pick an image for OCR.
///
/// Unlike the audio path, this needs no `dart.library.html` conditional import:
/// `withData: true` makes file_picker hand back bytes on every platform,
/// including web, and bytes are all the multipart upload needs.
Future<ImagePickResult> pickImageFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: imageFileExtensions,
    allowMultiple: false,
    withData: true,
  );
  if (result == null || result.files.isEmpty) {
    return const ImagePickResult.cancelled();
  }

  final file = result.files.single;
  final raw = file.bytes;
  if (raw == null) return const ImagePickResult.rejected(ImageRejection.empty);

  final bytes = Uint8List.fromList(raw);
  final rejection = rejectionFor(bytes);
  if (rejection != null) return ImagePickResult.rejected(rejection);

  final picked = pickedImageFromBytes(name: file.name, bytes: bytes);
  return picked == null
      ? const ImagePickResult.rejected(ImageRejection.unsupportedFormat)
      : ImagePickResult.picked(picked);
}
