import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../screens/record_file_io.dart'
    if (dart.library.html) '../screens/record_file_stub.dart';
import '../utils/wav_builder.dart';

/// Max 10 minutes — client-side cap (compressed formats lack reliable length
/// on the server, so the recording timer is the primary gate).
const kMaxRecordingSeconds = 600;

/// Result of a completed recording (mic stop).
typedef AudioRecordResult = ({
  Uint8List? bytes,
  String? path,
  String filename,
  String mimeType,
});

/// Thin wrapper around `package:record` for journal voice capture.
///
/// Web: PCM16 @ 16 kHz → WAV. Native: AAC `.m4a` @ 44.1 kHz.
/// Callers own upload / UI; this only manages start/stop + elapsed timer.
class AudioRecordController extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  int _elapsedSec = 0;
  int _pcmBytes = 0;

  Timer? _timer;
  Stopwatch? _stopwatch;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<RecordState>? _stateSub;
  final BytesBuilder _pcmBuilder = BytesBuilder(copy: false);

  String? _filePath;
  VoidCallback? onMaxDurationReached;
  void Function(String message)? onBrowserInterrupted;

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

  bool get recording => _recording;
  int get elapsedSec => _elapsedSec;
  int get pcmBytes => _pcmBytes;
  String? get filePath => _filePath;

  void attachStateListener() {
    _stateSub ??= _recorder.onStateChanged().listen((state) {
      if (state == RecordState.stop && _recording) {
        onBrowserInterrupted?.call(
          '브라우저가 녹음을 중단했습니다. 탭을 활성 상태로 유지하고 다시 시도해 주세요.',
        );
      }
    });
  }

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> _startWebStreamRecording() async {
    _pcmBuilder.clear();
    _pcmBytes = 0;
    final stream = await _recorder.startStream(_webStreamConfig);
    _pcmSub = stream.listen(
      (chunk) {
        _pcmBuilder.add(chunk);
        _pcmBytes += chunk.length;
        notifyListeners();
      },
      onError: (Object e) {
        // Surface via caller snackbars if needed — keep recording state honest.
        debugPrint('AudioRecordController stream error: $e');
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

  void _syncElapsedFromStopwatch() {
    final sw = _stopwatch;
    if (sw == null || !sw.isRunning) return;
    final sec = sw.elapsed.inSeconds;
    if (sec != _elapsedSec) {
      _elapsedSec = sec;
      notifyListeners();
    }
  }

  /// Start mic capture. Throws on failure; returns false if permission denied.
  Future<bool> start() async {
    if (_recording) return true;

    final permitted = await _recorder.hasPermission();
    if (!permitted) return false;

    if (kIsWeb) {
      await _startWebStreamRecording();
    } else {
      final dir = await getTemporaryDirectory();
      _filePath =
          '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(_nativeRecordConfig, path: _filePath!);
    }

    _stopwatch = Stopwatch()..start();
    _recording = true;
    _elapsedSec = 0;
    _pcmBytes = 0;
    notifyListeners();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _syncElapsedFromStopwatch();
      if (_recording && _elapsedSec >= kMaxRecordingSeconds) {
        unawaited(_autoStopForMaxDuration());
      }
    });
    return true;
  }

  Future<void> _autoStopForMaxDuration() async {
    await stop();
    onMaxDurationReached?.call();
  }

  /// Stop mic and return captured audio. Null if nothing was captured.
  Future<AudioRecordResult?> stop() async {
    if (!_recording) return null;

    _timer?.cancel();
    _timer = null;
    _stopwatch?.stop();

    Uint8List? bytes;
    String? path = _filePath;
    if (kIsWeb) {
      bytes = await _stopWebStreamRecording();
      path = null;
    } else {
      await _recorder.stop();
    }

    _recording = false;
    notifyListeners();

    if (kIsWeb) {
      if (bytes == null || bytes.isEmpty) return null;
      return (
        bytes: bytes,
        path: null,
        filename: 'recording.wav',
        mimeType: 'audio/wav',
      );
    }
    if (path == null || !fileExists(path)) return null;
    return (
      bytes: null,
      path: path,
      filename: 'recording.m4a',
      mimeType: 'audio/mp4',
    );
  }

  /// Toggle: stop if recording, else start. Returns stop result when stopping.
  Future<AudioRecordResult?> toggle() async {
    if (_recording) return stop();
    await start();
    return null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pcmSub?.cancel();
    _stateSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
