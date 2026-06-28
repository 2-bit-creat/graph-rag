import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../utils/audio_file_import.dart';
import '../utils/picked_audio_file.dart';
import 'audio_drop_zone_platform.dart';

AudioDropZonePlatform createAudioDropZonePlatform() => _AudioDropZoneImpl();

class _AudioDropZoneImpl implements AudioDropZonePlatform {
  @override
  Widget build({
    required bool enabled,
    required bool dragging,
    required ValueChanged<bool> onDraggingChanged,
    required VoidCallback onTap,
    required AudioFilePickedCallback onFilePicked,
    required ValueChanged<String> onError,
    required Widget child,
  }) {
    return DropTarget(
      onDragEntered: (_) {
        if (!enabled) return;
        onDraggingChanged(true);
      },
      onDragExited: (_) => onDraggingChanged(false),
      onDragDone: (details) async {
        onDraggingChanged(false);
        if (!enabled || details.files.isEmpty) return;
        try {
          PickedAudioFile? picked;
          for (final file in details.files) {
            picked = await audioFromXFile(file);
            if (picked != null) break;
          }
          if (picked == null) {
            onError('지원하지 않는 파일입니다. (${audioFileExtensions.join(' · ')})');
            return;
          }
          await onFilePicked(picked);
        } catch (e) {
          onError('파일 불러오기 실패: $e');
        }
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: child,
        ),
      ),
    );
  }
}
