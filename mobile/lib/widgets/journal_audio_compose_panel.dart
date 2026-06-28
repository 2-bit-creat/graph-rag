import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'package:desktop_drop/desktop_drop.dart';

import '../api/client.dart';
import '../screens/record_file_io.dart' if (dart.library.html) '../screens/record_file_stub.dart';
import '../theme/app_theme.dart';
import '../utils/audio_file_import.dart';
import '../utils/audio_mime.dart';
import '../utils/wav_builder.dart';
import 'audio_drop_zone.dart';

class JournalAudioComposePanel extends StatefulWidget {
  const JournalAudioComposePanel({
    super.key,
    required this.onEntryCreated,
    this.sourceType,
  });

  final void Function(String entryId) onEntryCreated;
  final String? sourceType;

  @override
  State<JournalAudioComposePanel> createState() => _JournalAudioComposePanelState();
}

class _JournalAudioComposePanelState extends State<JournalAudioComposePanel> {
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _uploading = false;
  bool _dragging = false;
  String? _filePath;
  Uint8List? _webBytes;
  String? _pickedFilename;
  int _elapsedSec = 0;
  int _pcmBytes = 0;

  Timer? _timer;
  Stopwatch? _stopwatch;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<RecordState>? _stateSub;
  final BytesBuilder _pcmBuilder = BytesBuilder(copy: false);

  static const _webStreamConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    autoGain: true,
    echoCancel: false,
    noiseSuppress: false,
  );

  static const _nativeRecordConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    sampleRate: 44100,
    numChannels: 1,
  );

  void _syncElapsedFromStopwatch() {
    final sw = _stopwatch;
    if (sw == null || !sw.isRunning) return;
    final sec = sw.elapsed.inSeconds;
    if (sec != _elapsedSec && mounted) {
      setState(() => _elapsedSec = sec);
    }
  }

  Future<void> _startWebStreamRecording() async {
    _pcmBuilder.clear();
    _pcmBytes = 0;
    final stream = await _recorder.startStream(_webStreamConfig);
    _pcmSub = stream.listen(
      (chunk) {
        _pcmBuilder.add(chunk);
        _pcmBytes += chunk.length;
      },
      onError: (Object e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('녹음 스트림 오류: $e')),
          );
        }
      },
    );
  }

  Future<Uint8List?> _stopWebStreamRecording() async {
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _recorder.stop();

    final pcm = _pcmBuilder.toBytes();
    if (pcm.isEmpty) return null;
    return buildWavFromPcm(
      pcm,
      sampleRate: _webStreamConfig.sampleRate,
      numChannels: _webStreamConfig.numChannels,
    );
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      _timer?.cancel();
      _timer = null;
      _stopwatch?.stop();
      try {
        Uint8List? bytes;
        if (kIsWeb) {
          bytes = await _stopWebStreamRecording();
        } else {
          await _recorder.stop();
        }
        if (!mounted) return;
        setState(() {
          _recording = false;
          _webBytes = bytes;
          _pickedFilename = null;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('녹음 중지 실패: $e')),
          );
        }
        setState(() => _recording = false);
      }
      return;
    }

    final permitted = await _recorder.hasPermission();
    if (!permitted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('마이크 권한이 필요합니다. 브라우저 주소창 옆 🔒에서 허용해 주세요.'),
          ),
        );
      }
      return;
    }

    try {
      if (kIsWeb) {
        await _startWebStreamRecording();
      } else {
        final dir = await getTemporaryDirectory();
        _filePath =
            '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _recorder.start(_nativeRecordConfig, path: _filePath!);
      }
      if (!mounted) return;

      _stopwatch = Stopwatch()..start();
      setState(() {
        _recording = true;
        _webBytes = null;
        _pickedFilename = null;
        _elapsedSec = 0;
        _pcmBytes = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        _syncElapsedFromStopwatch();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('녹음 시작 실패: $e')),
        );
      }
    }
  }

  bool get _hasRecording {
    if (_recording) return false;
    if (kIsWeb) return _webBytes != null && _webBytes!.isNotEmpty;
    return _filePath != null && fileExists(_filePath!);
  }

  String get _uploadFilename {
    if (_pickedFilename != null && _pickedFilename!.isNotEmpty) {
      return _pickedFilename!;
    }
    return kIsWeb ? 'recording.wav' : 'recording.m4a';
  }

  String get _recordingInfo {
    if (_pickedFilename != null) {
      if (kIsWeb && _webBytes != null) {
        final kb = (_webBytes!.length / 1024).toStringAsFixed(1);
        final wavMs = wavDurationMs(_webBytes!);
        final dur = wavMs != null
            ? formatDuration((wavMs / 1000).round())
            : null;
        return dur != null
            ? '파일 $_pickedFilename · $dur · ${kb}KB'
            : '파일 $_pickedFilename · ${kb}KB';
      }
      return '파일 $_pickedFilename';
    }
    if (kIsWeb && _webBytes != null) {
      final kb = (_webBytes!.length / 1024).toStringAsFixed(1);
      final wavMs = wavDurationMs(_webBytes!);
      final dur = wavMs != null
          ? formatDuration((wavMs / 1000).round())
          : formatDuration(_elapsedSec);
      return '녹음 $dur · ${kb}KB';
    }
    if (_elapsedSec > 0) return '녹음 ${formatDuration(_elapsedSec)}';
    return '';
  }

  void _applyPickedAudio(PickedAudioFile picked) {
    if (kIsWeb) {
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('파일 데이터를 읽을 수 없습니다.');
      }
      setState(() {
        _webBytes = bytes;
        _filePath = null;
        _pickedFilename = picked.name;
        _elapsedSec = 0;
      });
      return;
    }

    final path = picked.path;
    if (path == null || !fileExists(path)) {
      throw Exception('파일 경로를 확인할 수 없습니다.');
    }
    setState(() {
      _filePath = path;
      _webBytes = null;
      _pickedFilename = picked.name;
      _elapsedSec = 0;
    });
  }

  Future<void> _importPickedAudio(PickedAudioFile? picked) async {
    if (picked == null) return;
    if (kIsWeb) {
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('파일 데이터를 읽을 수 없습니다.');
      }
    } else {
      final path = picked.path;
      if ((path == null || !fileExists(path)) &&
          (picked.bytes == null || picked.bytes!.isEmpty)) {
        throw Exception('파일을 확인할 수 없습니다.');
      }
    }
    if (!mounted) return;
    _applyPickedAudio(picked);
  }

  Future<void> _pickAudioFile() async {
    if (_recording) {
      _showSnack('녹음을 먼저 중지한 뒤 파일을 선택해 주세요.');
      return;
    }

    try {
      final picked = await pickAudioFile();
      await _importPickedAudio(picked);
      if (!mounted || picked == null || !_hasRecording) return;
      _showSnack('${picked.name} 불러옴 — 분석을 시작합니다');
      await _upload();
    } catch (e) {
      _showSnack('파일 선택 실패: $e');
    }
  }

  Future<void> _onFilePicked(PickedAudioFile picked) async {
    if (_recording) {
      _showSnack('녹음을 먼저 중지한 뒤 파일을 놓아 주세요.');
      return;
    }
    try {
      await _importPickedAudio(picked);
      if (!mounted || !_hasRecording) return;
      _showSnack('${picked.name} 불러옴 — 분석을 시작합니다');
      await _upload();
    } catch (e) {
      _showSnack('파일 불러오기 실패: $e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _upload() async {
    if (!_hasRecording) return;
    setState(() => _uploading = true);
    try {
      late Map<String, dynamic> result;
      final filename = _uploadFilename;
      if (kIsWeb) {
        result = await apiClient.uploadAudioBytes(
          _webBytes!,
          filename: filename,
          mimeType: audioMimeTypeForFilename(filename),
          sourceType: widget.sourceType,
        );
      } else {
        result = await apiClient.uploadAudio(
          _filePath!,
          filename: filename,
          sourceType: widget.sourceType,
        );
      }
      if (mounted) {
        widget.onEntryCreated(result['id'].toString());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('업로드 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _stateSub = _recorder.onStateChanged().listen((state) {
      if (state == RecordState.stop && _recording && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '브라우저가 녹음을 중단했습니다. 탭을 활성 상태로 유지하고 다시 시도해 주세요.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pcmSub?.cancel();
    _stateSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Widget _buildAudioDropZone(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = !_uploading && !_recording;
    final dragHint = AudioDropZone.supportsDrag
        ? '드래그하거나 탭하여 음성 파일 선택'
        : '탭하여 음성 파일 선택';

    return AudioDropZone(
      enabled: enabled,
      dragging: _dragging,
      onDraggingChanged: (value) {
        if (mounted) setState(() => _dragging = value);
      },
      onTap: _pickAudioFile,
      onFilePicked: _onFilePicked,
      onError: _showSnack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _dragging
                ? colorScheme.primary
                : colorScheme.outlineVariant,
            width: _dragging ? 2.5 : 1.5,
          ),
          color: _dragging
              ? colorScheme.primaryContainer.withValues(alpha: 0.45)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _dragging ? Icons.download_done : Icons.audio_file_outlined,
              size: 32,
              color: _dragging ? colorScheme.primary : colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              _dragging ? '여기에 놓으세요' : dragHint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              'wav · mp3 · m4a · aac · ogg · webm · flac',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, height: 1.2, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordSection(BuildContext context) {
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: _recording ? 128 : 108,
          height: _recording ? 128 : 108,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: _recording
                ? LinearGradient(
                    colors: [
                      AppColors.hubRecord.withValues(alpha: 0.25),
                      AppColors.hubRecord.withValues(alpha: 0.08),
                    ],
                  )
                : null,
            color: _recording ? null : Theme.of(context).colorScheme.surfaceContainerHighest,
            boxShadow: _recording
                ? [
                    BoxShadow(
                      color: AppColors.hubRecord.withValues(alpha: 0.25),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: IconButton(
            iconSize: 52,
            icon: Icon(
              _recording ? Icons.stop_rounded : Icons.mic_rounded,
              color: _recording ? AppColors.hubRecord : AppColors.primary,
            ),
            onPressed: _uploading ? null : _toggleRecord,
          ),
        ),
        const SizedBox(height: 24),
        if (_recording) ...[
          Text(
            formatDuration(_elapsedSec),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
          ),
          if (kIsWeb && _pcmBytes > 0)
            Text(
              '${(_pcmBytes / 32000).toStringAsFixed(1)}s captured',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
        ],
        Text(_recording ? '녹음 중… 탭하여 중지' : '탭하여 녹음 시작'),
        if (kIsWeb)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '녹음 중에는 탭을 활성 상태로 유지해 주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.orange[800], fontSize: 12),
            ),
          ),
        if (_hasRecording && _recordingInfo.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_recordingInfo, style: TextStyle(color: Colors.grey[600])),
        ],
        if (_hasRecording) ...[
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _uploading ? null : _upload,
            icon: _uploading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload),
            label: Text(_uploading ? '처리 중…' : '업로드 & 분석'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).colorScheme.outlineVariant;
    final canDrop = !_uploading && !_recording && AudioDropZone.supportsDrag;
    return DropTarget(
      enable: canDrop,
      onDragEntered: (_) { if (mounted) setState(() => _dragging = true); },
      onDragExited: (_) { if (mounted) setState(() => _dragging = false); },
      onDragDone: (details) async {
        if (mounted) setState(() => _dragging = false);
        if (!canDrop || details.files.isEmpty) return;
        try {
          PickedAudioFile? picked;
          for (final file in details.files) {
            picked = await audioFromXFile(file);
            if (picked != null) break;
          }
          if (picked == null) {
            _showSnack('지원하지 않는 파일입니다.');
            return;
          }
          await _onFilePicked(picked);
        } catch (e) {
          _showSnack('파일 불러오기 실패: $e');
        }
      },
      child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAudioDropZone(context),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Row(
                children: [
                  Expanded(child: Divider(color: dividerColor)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '또는 바로 녹음',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Expanded(child: Divider(color: dividerColor)),
                ],
              ),
            ),
            _buildRecordSection(context),
            if (_uploading && _pickedFilename != null)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
      ),
    );
  }
}
