import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import 'picked_audio_file.dart';

Future<PickedAudioFile?> pickAudioFile() async {
  final input = html.FileUploadInputElement()
    ..accept = 'audio/*,.wav,.mp3,.m4a,.aac,.ogg,.webm,.flac'
    ..multiple = false
    ..style.display = 'none';

  html.document.body?.append(input);

  final completer = Completer<PickedAudioFile?>();
  late StreamSubscription<html.Event> sub;

  sub = input.onChange.listen((_) async {
    await sub.cancel();
    input.remove();

    final files = input.files;
    if (files == null || files.isEmpty) {
      completer.complete(null);
      return;
    }

    completer.complete(await audioFromHtmlFile(files.first));
  });

  input.click();
  return completer.future;
}

Future<PickedAudioFile?> audioFromXFile(XFile file) async {
  final bytes = await file.readAsBytes();
  return pickedAudioFromBytes(
    name: file.name,
    mimeType: file.mimeType,
    bytes: bytes,
  );
}

Future<Uint8List?> readHtmlFileBytes(html.Blob file) async {
  final reader = html.FileReader();
  final completer = Completer<Uint8List?>();

  void finish(Uint8List? bytes) {
    if (!completer.isCompleted) {
      completer.complete(bytes != null && bytes.isNotEmpty ? bytes : null);
    }
  }

  reader.onError.listen((_) => finish(null));
  reader.onAbort.listen((_) => finish(null));
  reader.onLoadEnd.listen((_) {
    final result = reader.result;
    if (result is ByteBuffer) {
      finish(result.asUint8List());
      return;
    }
    if (result is Uint8List) {
      finish(result);
      return;
    }
    finish(null);
  });

  reader.readAsArrayBuffer(file);
  return completer.future;
}

Future<PickedAudioFile?> audioFromHtmlFile(html.File file) async {
  final bytes = await readHtmlFileBytes(file);
  if (bytes == null) return null;
  return pickedAudioFromBytes(
    name: file.name,
    mimeType: file.type,
    bytes: bytes,
  );
}

Future<PickedAudioFile?> pickFirstSupportedHtmlFile(
  Iterable<dynamic> files,
) async {
  for (final raw in files) {
    if (raw is! html.File) continue;
    final picked = await audioFromHtmlFile(raw);
    if (picked != null) return picked;
  }
  return null;
}
