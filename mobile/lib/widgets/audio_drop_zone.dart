import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/picked_audio_file.dart';
import 'audio_drop_zone_platform.dart';

typedef AudioFilePickedCallback = Future<void> Function(PickedAudioFile file);

class AudioDropZone extends StatelessWidget {
  const AudioDropZone({
    super.key,
    required this.enabled,
    required this.dragging,
    required this.onDraggingChanged,
    required this.onTap,
    required this.onFilePicked,
    required this.onError,
    required this.child,
  });

  final bool enabled;
  final bool dragging;
  final ValueChanged<bool> onDraggingChanged;
  final VoidCallback onTap;
  final AudioFilePickedCallback onFilePicked;
  final ValueChanged<String> onError;
  final Widget child;

  static bool get supportsDrag =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    return createAudioDropZonePlatform().build(
      enabled: enabled,
      dragging: dragging,
      onDraggingChanged: onDraggingChanged,
      onTap: onTap,
      onFilePicked: onFilePicked,
      onError: onError,
      child: child,
    );
  }
}
