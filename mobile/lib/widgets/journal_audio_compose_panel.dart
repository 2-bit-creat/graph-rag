import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';

import '../compose/compose_session_controller.dart';
import '../screens/record_file_io.dart'
    if (dart.library.html) '../screens/record_file_stub.dart';
import '../theme/app_theme.dart';
import '../utils/audio_file_import.dart';
import '../utils/audio_mime.dart';
import '../utils/wav_builder.dart';
import 'audio_drop_zone.dart';
import 'audio_record_core.dart';
import 'audio_waveform.dart';

export 'audio_record_core.dart' show kMaxRecordingSeconds;

class JournalAudioComposePanel extends StatefulWidget {
  const JournalAudioComposePanel({
    super.key,
    required this.onEntryCreated,
    this.sourceType,
    this.onDirtyChanged,
  });

  final void Function(String entryId) onEntryCreated;
  final String? sourceType;

  /// 녹음 중이거나 업로드 안 된 녹음이 있을 때 true — 화면 이탈 확인용.
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<JournalAudioComposePanel> createState() =>
      _JournalAudioComposePanelState();
}

class _JournalAudioComposePanelState extends State<JournalAudioComposePanel> {
  late final AudioRecordController _recorder;
  bool _uploading = false;
  bool _dragging = false;
  String? _filePath;
  Uint8List? _webBytes;
  String? _pickedFilename;
  int _elapsedSec = 0;

  bool _lastDirty = false;

  bool get _recording => _recorder.recording;

  /// 이탈 시 유실될 수 있는 입력(녹음 중 / 미업로드 녹음)이 있는지 부모에 알림.
  void _notifyDirty() {
    final dirty = _recording || _hasRecording;
    if (dirty != _lastDirty) {
      _lastDirty = dirty;
      widget.onDirtyChanged?.call(dirty);
    }
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      try {
        final result = await _recorder.stop();
        if (!mounted) return;
        setState(() {
          _webBytes = result?.bytes;
          _filePath = result?.path;
          _pickedFilename = null;
          _elapsedSec = _recorder.elapsedSec;
        });
        composeSession.setRecording(false);
        _notifyDirty();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('녹음 중지 실패: $e')),
          );
        }
        composeSession.setRecording(false);
      }
      return;
    }

    try {
      final ok = await _recorder.start();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('마이크 권한이 필요합니다. 브라우저 주소창 옆 🔒에서 허용해 주세요.'),
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _webBytes = null;
        _filePath = null;
        _pickedFilename = null;
        _elapsedSec = 0;
      });
      composeSession.setRecording(true);
      _notifyDirty();
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
      _notifyDirty();
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
    _notifyDirty();
  }

  /// Best-effort length gate for picked/dropped files: only WAV duration is
  /// decodable client-side without a new dependency (see wavDurationMs). Other
  /// formats (m4a/mp3/…) pass through — the recording timer is the primary cap.
  Future<bool> _rejectIfTooLong(PickedAudioFile picked) async {
    final bytes = picked.bytes;
    if (bytes == null || bytes.isEmpty) return false;
    final ms = wavDurationMs(bytes);
    if (ms == null || ms <= kMaxRecordingSeconds * 1000) return false;
    if (!mounted) return true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('음성이 너무 깁니다'),
        content: Text(
          '${picked.name}은(는) ${formatDuration((ms / 1000).round())}로, '
          '최대 ${formatDuration(kMaxRecordingSeconds)}를 넘습니다.\n'
          '분량을 나눠서 업로드해 주세요.',
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('확인')),
        ],
      ),
    );
    return true;
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
    if (await _rejectIfTooLong(picked)) return;
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
    // Re-entrancy guard: drop-zone/file-pick paths and double-taps can fire
    // _upload() twice in quick succession (observed ~126ms apart), creating
    // duplicate journal entries from one audio. _uploading is set synchronously
    // below, so any concurrent second call returns here.
    if (_uploading || !_hasRecording) return;
    setState(() => _uploading = true);
    try {
      late Map<String, dynamic> result;
      final filename = _uploadFilename;
      // 전역 세션을 통해 업로드 — Fast Path 대기 동안 작성 창이 자동 최소화되고
      // 우하단 미니 카드가 진행 상황을 보여준다. 완료되면 세션이 엔트리를 넘겨받는다.
      if (kIsWeb) {
        result = await composeSession.uploadAudioBytes(
          _webBytes!,
          filename: filename,
          mimeType: audioMimeTypeForFilename(filename),
          sourceType: widget.sourceType,
        );
      } else {
        result = await composeSession.uploadAudio(
          _filePath!,
          filename: filename,
          sourceType: widget.sourceType,
        );
      }
      if (mounted) {
        // 업로드 성공 — 더 이상 유실될 입력이 없으니 이탈 가드 해제 후 이동.
        _lastDirty = false;
        widget.onDirtyChanged?.call(false);
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
    _recorder = AudioRecordController();
    _recorder.attachStateListener();
    _recorder.onMaxDurationReached = () {
      if (mounted) {
        setState(() => _elapsedSec = _recorder.elapsedSec);
        composeSession.setRecording(false);
        _notifyDirty();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('최대 10분까지 녹음됩니다 — 녹음이 자동으로 중지되었어요.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    };
    _recorder.onBrowserInterrupted = (msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
        );
      }
    };
    _recorder.addListener(() {
      if (!mounted) return;
      if (_recorder.elapsedSec != _elapsedSec || _recording) {
        setState(() => _elapsedSec = _recorder.elapsedSec);
      }
    });
  }

  @override
  void dispose() {
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
            color: _dragging ? colorScheme.primary : colorScheme.outlineVariant,
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
              style:
                  TextStyle(fontSize: 10, height: 1.2, color: Colors.grey[600]),
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
            color: _recording
                ? null
                : Theme.of(context).colorScheme.surfaceContainerHighest,
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
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: AudioWaveform(levels: _recorder.levels),
          ),
        ],
        Text(
          _recording
              ? '녹음 중… 탭하여 중지'
              : _hasRecording
                  ? '탭하면 처음부터 다시 녹음해요'
                  : '탭하여 녹음 시작',
        ),
        if (!_recording && !_hasRecording)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '한 번에 최대 10분까지 기록할 수 있어요',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
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
      onDragEntered: (_) {
        if (mounted) setState(() => _dragging = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _dragging = false);
      },
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
          // 업로드 중에는 단계 카드만 — 어떤 처리가 진행되는지 보여주고 오조작 방지.
          child: _uploading
              ? const _UploadStagesCard()
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 모바일 기본 동작 = 녹음. 파일 업로드는 보조 수단으로 아래에.
                    _buildRecordSection(context),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Row(
                        children: [
                          Expanded(child: Divider(color: dividerColor)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              '또는 음성 파일 업로드',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          Expanded(child: Divider(color: dividerColor)),
                        ],
                      ),
                    ),
                    _buildAudioDropZone(context),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 업로드 중 표시되는 처리 단계 카드.
///
/// 서버의 Fast Path(STT → 정제)는 하나의 동기 요청이라 실제 단계 진행률을
/// 알 수 없다 — 그래서 "어느 단계일 것"이라고 속이지 않고, 어떤 일들이 순서대로
/// 일어나는지 보여주며 하이라이트만 순환시킨다 (Otter/Speechify류 대기 UX).
class _UploadStagesCard extends StatefulWidget {
  const _UploadStagesCard();

  @override
  State<_UploadStagesCard> createState() => _UploadStagesCardState();
}

class _UploadStagesCardState extends State<_UploadStagesCard> {
  static const _stages = [
    (Icons.cloud_upload_outlined, '음성 업로드'),
    (Icons.hearing_outlined, '받아쓰기 (STT)'),
    (Icons.auto_fix_high_outlined, '문장 다듬기'),
  ];

  int _highlight = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      if (mounted) {
        setState(() => _highlight = (_highlight + 1) % _stages.length);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 56,
          height: 56,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(height: 24),
        Text('일기를 만드는 중이에요',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          '음성 길이에 따라 최대 1분 정도 걸릴 수 있어요.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _stages.length; i++)
                Padding(
                  padding:
                      EdgeInsets.only(bottom: i == _stages.length - 1 ? 0 : 12),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 400),
                    opacity: i == _highlight ? 1.0 : 0.45,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _stages[i].$1,
                          size: 18,
                          color: i == _highlight
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _stages[i].$2,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: i == _highlight
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: i == _highlight
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
