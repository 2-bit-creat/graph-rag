import 'dart:io';
import 'dart:typed_data';

bool fileExists(String path) => File(path).existsSync();

Future<Uint8List> readAudioFile(String path) => File(path).readAsBytes();
