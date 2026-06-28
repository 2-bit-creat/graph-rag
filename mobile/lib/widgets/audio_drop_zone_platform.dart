import 'audio_drop_zone_impl.dart'
    if (dart.library.html) 'audio_drop_zone_web.dart' as platform;

import 'package:flutter/material.dart';

import '../utils/picked_audio_file.dart';

typedef AudioFilePickedCallback = Future<void> Function(PickedAudioFile file);

abstract class AudioDropZonePlatform {
  Widget build({
    required bool enabled,
    required bool dragging,
    required ValueChanged<bool> onDraggingChanged,
    required VoidCallback onTap,
    required AudioFilePickedCallback onFilePicked,
    required ValueChanged<String> onError,
    required Widget child,
  });
}

AudioDropZonePlatform createAudioDropZonePlatform() =>
    platform.createAudioDropZonePlatform();
