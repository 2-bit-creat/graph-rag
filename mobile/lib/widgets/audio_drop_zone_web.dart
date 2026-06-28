import 'dart:html' as html;

import 'package:flutter/material.dart';

import '../utils/audio_file_import.dart';
import 'audio_drop_zone_platform.dart';

AudioDropZonePlatform createAudioDropZonePlatform() => _WebAudioDropZone();

class _WebDropSession {
  bool enabled = false;
  ValueChanged<bool>? onDraggingChanged;
  AudioFilePickedCallback? onFilePicked;
  ValueChanged<String>? onError;
}

final _session = _WebDropSession();
bool _hooksInstalled = false;
int _dragDepth = 0;

List<html.File> _collectDroppedFiles(html.MouseEvent event) {
  final seen = <String>{};
  final files = <html.File>[];

  void addFile(html.File file) {
    final key = '${file.name}|${file.size}|${file.lastModified}';
    if (seen.add(key)) files.add(file);
  }

  final list = event.dataTransfer.files;
  if (list != null) {
    for (var i = 0; i < list.length; i++) {
      addFile(list[i]);
    }
  }

  final items = event.dataTransfer.items;
  if (items != null) {
    final count = items.length;
    if (count != null) {
      for (var i = 0; i < count; i++) {
        final item = items[i];
        if (item.kind != 'file') continue;
        final file = item.getAsFile();
        if (file != null) addFile(file);
      }
    }
  }

  return files;
}

void _ensureHooks() {
  if (_hooksInstalled) return;
  _hooksInstalled = true;

  html.document.body?.onDragOver.listen((event) {
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
  });

  html.window.onDragOver.listen((event) {
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
    if (!_session.enabled) return;
    _dragDepth++;
    _session.onDraggingChanged?.call(true);
  });

  html.window.onDragLeave.listen((event) {
    if (!_session.enabled) return;
    _dragDepth = (_dragDepth - 1).clamp(0, 999);
    if (_dragDepth == 0) {
      _session.onDraggingChanged?.call(false);
    }
  });

  html.window.onDrop.listen((event) async {
    event.preventDefault();
    _dragDepth = 0;
    _session.onDraggingChanged?.call(false);
    if (!_session.enabled) return;

    final files = _collectDroppedFiles(event);
    if (files.isEmpty) {
      _session.onError?.call('드롭한 파일을 읽을 수 없습니다.');
      return;
    }

    try {
      final picked = await pickFirstSupportedHtmlFile(files);
      if (picked == null) {
        _session.onError?.call(
          '지원하지 않는 파일입니다. (${audioFileExtensions.join(' · ')})',
        );
        return;
      }
      await _session.onFilePicked?.call(picked);
    } catch (e) {
      _session.onError?.call('파일 불러오기 실패: $e');
    }
  });
}

class _WebAudioDropZone implements AudioDropZonePlatform {
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
    return _WebDropHost(
      enabled: enabled,
      onDraggingChanged: onDraggingChanged,
      onTap: onTap,
      onFilePicked: onFilePicked,
      onError: onError,
      child: child,
    );
  }
}

class _WebDropHost extends StatefulWidget {
  const _WebDropHost({
    required this.enabled,
    required this.onDraggingChanged,
    required this.onTap,
    required this.onFilePicked,
    required this.onError,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<bool> onDraggingChanged;
  final VoidCallback onTap;
  final AudioFilePickedCallback onFilePicked;
  final ValueChanged<String> onError;
  final Widget child;

  @override
  State<_WebDropHost> createState() => _WebDropHostState();
}

class _WebDropHostState extends State<_WebDropHost> {
  @override
  void initState() {
    super.initState();
    _ensureHooks();
    _bindSession();
  }

  @override
  void didUpdateWidget(covariant _WebDropHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindSession();
  }

  void _bindSession() {
    _session.enabled = widget.enabled;
    _session.onDraggingChanged = widget.onDraggingChanged;
    _session.onFilePicked = widget.onFilePicked;
    _session.onError = widget.onError;
  }

  @override
  void dispose() {
    _session.enabled = false;
    _session.onDraggingChanged = null;
    _session.onFilePicked = null;
    _session.onError = null;
    _dragDepth = 0;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.enabled ? widget.onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: widget.child,
      ),
    );
  }
}
