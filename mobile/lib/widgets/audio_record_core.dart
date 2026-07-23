import 'dart:async';
import 'dart:math' as math;
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
  StreamSubscription<Amplitude>? _ampSub;
  final BytesBuilder _pcmBuilder = BytesBuilder(copy: false);

  /// Rolling buffer of normalized mic levels (0..1), newest last — drives the
  /// live recording waveform. Native uses `onAmplitudeChanged`; web derives RMS
  /// from the PCM stream (amplitude events aren't reliable in-browser).
  static const _waveformWindow = 48;
  final List<double> _levels = <double>[];
  List<double> get levels => List.unmodifiable(_levels);

  void _pushLevel(double v) {
    _levels.add(v.clamp(0.0, 1.0));
    if (_levels.length > _waveformWindow) {
      _levels.removeRange(0, _levels.length - _waveformWindow);
    }
    notifyListeners();
  }

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
        _pushLevel(_rmsLevelFromPcm16(chunk));
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

  /// Normalized 0..1 loudness of a PCM16 chunk (RMS, lightly gained).
  /// Reads via [ByteData] so it's safe for chunks at any byte offset.
  double _rmsLevelFromPcm16(Uint8List chunk) {
    final count = chunk.length ~/ 2;
    if (count == 0) return 0;
    final data = ByteData.sublistView(chunk);
    var sum = 0.0;
    for (var i = 0; i < count; i++) {
      final v = data.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    final rms = math.sqrt(sum / count);
    // Gain up quiet speech; RMS of normal speech sits well under 0.3.
    return (rms * 3.2).clamp(0.0, 1.0);
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

    _levels.clear();
    if (kIsWeb) {
      await _startWebStreamRecording();
    } else {
      final dir = await getTemporaryDirectory();
      _filePath =
          '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(_nativeRecordConfig, path: _filePath!);
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 90))
          .listen((amp) {
        // `current` is dBFS (<= 0); map a ~50 dB window onto 0..1.
        _pushLevel(((amp.current + 50) / 50).clamp(0.0, 1.0));
      });
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
    await _ampSub?.cancel();
    _ampSub = null;

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
    _ampSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
