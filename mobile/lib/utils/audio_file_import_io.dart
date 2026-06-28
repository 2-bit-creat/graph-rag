import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';

import 'picked_audio_file.dart';
import '../screens/record_file_io.dart'
    if (dart.library.html) '../screens/record_file_stub.dart';

Future<PickedAudioFile?> pickAudioFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: audioFileExtensions,
    allowMultiple: false,
  );
  if (result == null || result.files.isEmpty) return null;
  return audioFromPlatformFile(result.files.single);
}

Future<PickedAudioFile?> audioFromHtmlFile(dynamic file) async => null;

Future<PickedAudioFile?> pickFirstSupportedHtmlFile(Iterable<dynamic> files) async =>
    null;

Future<PickedAudioFile?> audioFromXFile(XFile file) async {
  final path = file.path;
  if (path.isNotEmpty && fileExists(path)) {
    final resolvedName = resolveAudioFilename(file.name, mimeType: file.mimeType);
    if (!isSupportedAudioFile(resolvedName, mimeType: file.mimeType)) {
      return null;
    }
    return PickedAudioFile(name: resolvedName, path: path);
  }

  final bytes = await file.readAsBytes();
  return pickedAudioFromBytes(
    name: file.name,
    mimeType: file.mimeType,
    bytes: bytes,
  );
}

Future<PickedAudioFile?> audioFromPlatformFile(PlatformFile file) async {
  final path = file.path;
  final bytes = file.bytes;

  if (bytes != null && bytes.isNotEmpty) {
    return pickedAudioFromBytes(
      name: file.name,
      bytes: Uint8List.fromList(bytes),
      path: path,
    );
  }

  if (path != null && fileExists(path)) {
    final resolvedName = resolveAudioFilename(file.name);
    if (!isSupportedAudioFile(resolvedName)) return null;
    return PickedAudioFile(name: resolvedName, path: path);
  }

  return null;
}
