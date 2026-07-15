import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/config.dart';

class QuizAudioButton extends StatefulWidget {
  const QuizAudioButton({
    super.key,
    this.audioUrl,
    this.autoPlayOnLoad = false,
    this.iconSize = 28,
  });

  final String? audioUrl;
  final bool autoPlayOnLoad;
  final double iconSize;

  @override
  State<QuizAudioButton> createState() => QuizAudioButtonState();
}

class QuizAudioButtonState extends State<QuizAudioButton> {
  final AudioPlayer _player = AudioPlayer();
  final Dio _dio = Dio();
  bool _playing = false;
  bool _loading = false;
  String? _loadedUrl;
  String? _cachedFilePath;
  StreamSubscription<void>? _completeSub;

  static const _loadTimeout = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
    if (widget.autoPlayOnLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) => play());
    }
  }

  @override
  void didUpdateWidget(covariant QuizAudioButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioUrl != widget.audioUrl) {
      _loadedUrl = null;
      _cachedFilePath = null;
      if (widget.autoPlayOnLoad) {
        play();
      }
    }
  }

  Future<void> play({bool showError = true}) async {
    final resolved = resolveMediaUrl(widget.audioUrl);
    if (resolved == null) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이 문제에는 음성 파일이 없습니다.')),
        );
      }
      return;
    }

    setState(() => _loading = true);
    try {
      await _player.stop();
      setState(() => _playing = true);
      if (kIsWeb) {
        // On web, dart:io File/getTemporaryDirectory is unavailable — play from URL directly.
        await _player.play(UrlSource(resolved));
      } else {
        if (_loadedUrl != resolved || _cachedFilePath == null) {
          _cachedFilePath = await _downloadToCache(resolved);
          _loadedUrl = resolved;
        }
        await _player.play(DeviceFileSource(_cachedFilePath!));
      }
    } on MissingPluginException {
      if (mounted) setState(() => _playing = false);
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '음성 플러그인이 등록되지 않았습니다.\n'
              '앱을 완전히 종료한 뒤 run_windows.ps1로 다시 실행하세요.',
            ),
          ),
        );
      }
    } on TimeoutException {
      if (mounted) setState(() => _playing = false);
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '음성 서버에 연결할 수 없습니다.\n$resolved\n'
              '백엔드가 실행 중인지 확인하세요.',
            ),
          ),
        );
      }
    } catch (e) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('음성 재생 실패: $e')),
        );
      }
      if (mounted) setState(() => _playing = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String> _downloadToCache(String resolved) async {
    final resp = await _dio.get<List<int>>(
      resolved,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
      ),
    ).timeout(_loadTimeout);
    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('empty audio response');
    }
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/quiz_audio_${resolved.hashCode.abs()}.mp3',
    );
    await file.writeAsBytes(Uint8List.fromList(bytes), flush: true);
    return file.path;
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
    _dio.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.audioUrl != null && widget.audioUrl!.isNotEmpty;
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: available
          ? colorScheme.primaryContainer.withValues(alpha: 0.45)
          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: available && !_loading ? () => play() : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: _loading
              ? SizedBox(
                  width: widget.iconSize,
                  height: widget.iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                )
              : Icon(
                  _playing ? Icons.volume_up_rounded : Icons.volume_up_outlined,
                  size: widget.iconSize,
                  color: available
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.35),
                ),
        ),
      ),
    );
  }
}
