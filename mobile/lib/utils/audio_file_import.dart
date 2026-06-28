import 'package:cross_file/cross_file.dart';

import 'picked_audio_file.dart';
import 'audio_file_import_io.dart'
    if (dart.library.html) 'audio_file_import_web.dart' as impl;

export 'picked_audio_file.dart';

Future<PickedAudioFile?> pickAudioFile() => impl.pickAudioFile();

Future<PickedAudioFile?> audioFromXFile(XFile file) => impl.audioFromXFile(file);

Future<PickedAudioFile?> audioFromHtmlFile(dynamic file) =>
    impl.audioFromHtmlFile(file);

Future<PickedAudioFile?> pickFirstSupportedHtmlFile(Iterable<dynamic> files) =>
    impl.pickFirstSupportedHtmlFile(files);
