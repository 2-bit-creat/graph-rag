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
import '../../l10n/app_strings.dart';

class QuizAudioButton extends StatefulWidget {
  const QuizAudioButton({
    super.key,
    this.audioUrl,
    this.answerAudioUrl,
    this.autoPlayOnLoad = false,
    this.preload = false,
    this.iconSize = 28,
  });

  /// The complete target-language sentence.
  final String? audioUrl;

  /// The cloze answer phrase, played before [audioUrl] after a correct answer.
  final String? answerAudioUrl;
  final bool autoPlayOnLoad;

  /// Fetches the clips while the learner reads the question.
  final bool preload;
  final double iconSize;

  @override
  State<QuizAudioButton> createState() => QuizAudioButtonState();
}

class QuizAudioButtonState extends State<QuizAudioButton> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;
  StreamSubscription<void>? _completeSub;
  Completer<void>? _completion;
  int _playSequence = 0;

  // Shared across cards. Native stores each URL once in the temporary cache;
  // web warms the browser HTTP cache before the answer event occurs.
  static final Dio _cacheDio = Dio();
  static final Map<String, Future<String>> _nativeCacheLoads = {};
  static final Map<String, Future<void>> _webWarmups = {};

  static const _loadTimeout = Duration(seconds: 15);
  static const _webPlayStartTimeout = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onPlayerComplete.listen((_) {
      _completion?.complete();
      _completion = null;
      if (mounted) setState(() => _playing = false);
    });
    if (widget.preload) unawaited(prepare());
    if (widget.autoPlayOnLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) => play());
    }
  }

  @override
  void didUpdateWidget(covariant QuizAudioButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioUrl != widget.audioUrl ||
        oldWidget.answerAudioUrl != widget.answerAudioUrl) {
      if (widget.preload) unawaited(prepare());
      if (widget.autoPlayOnLoad) play();
    }
  }

  Future<void> play({bool showError = true}) async {
    final resolved = resolveMediaUrl(widget.audioUrl);
    if (resolved == null) return _showMissing(showError);
    _completion = null;
    await _playResolved(resolved, ++_playSequence, showError: showError);
  }

  /// Correct-answer feedback: exact answer → short pause → natural sentence.
  /// Both clips are re-awaited from [prepare] first — normally an instant,
  /// already-resolved cache hit, but on the rare occasion a card is answered
  /// before its background preload finished, this keeps the network fetch
  /// (which can take far longer than the deliberate pause below) from
  /// silently stretching the gap between the two clips.
  Future<void> playCorrectSequence({bool showError = true}) async {
    final answer = resolveMediaUrl(widget.answerAudioUrl);
    final sentence = resolveMediaUrl(widget.audioUrl);
    if (answer == null || sentence == null) return play(showError: showError);

    await prepare();
    final sequence = ++_playSequence;
    final completion = Completer<void>();
    _completion = completion;
    await _playResolved(answer, sequence, showError: showError);
    try {
      // Never cut a correct answer off just because it is longer than a
      // hard-coded three seconds.  Wait for the player's completion event;
      // the watchdog only covers a genuinely broken browser/media stream.
      await completion.future.timeout(const Duration(seconds: 15));
      if (sequence != _playSequence) return;
      await Future<void>.delayed(const Duration(milliseconds: 90));
      if (sequence != _playSequence) return;
      _completion = null;
      await _playResolved(sentence, sequence, showError: showError);
    } on TimeoutException {
      if (sequence == _playSequence) {
        await _playResolved(sentence, sequence, showError: showError);
      }
    }
  }

  /// Unlocks this player for autoplay on browsers (notably iOS Safari) that
  /// only allow programmatic playback started directly inside a user
  /// gesture's call stack. The correct-answer clip normally plays after an
  /// `await` for server grading — by the time it fires, the tap that
  /// triggered it is no longer "live" as far as the browser is concerned, so
  /// the browser silently drops the call. Playing (and immediately muting +
  /// pausing) this exact player synchronously inside the real tap handler,
  /// before that grading `await`, keeps it unlocked for the rest of the
  /// session — the later programmatic play then goes through normally.
  /// Call this from the very start of a genuine `onPressed`/`onTap` handler,
  /// before any `await`. No-op outside the web target.
  void primeForAutoplay() {
    if (!kIsWeb) return;
    final resolved =
        resolveMediaUrl(widget.answerAudioUrl) ?? resolveMediaUrl(widget.audioUrl);
    if (resolved == null) return;
    unawaited(() async {
      try {
        await _player.setVolume(0);
        await _player.play(UrlSource(resolved));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await _player.pause();
      } catch (_) {
        // Best-effort only — a failed priming attempt must never surface as
        // a user-visible error; the real playback still falls back to its
        // own error handling later.
      } finally {
        await _player.setVolume(1);
      }
    }());
  }

  /// Best-effort warm-up, exactly like [_primeResolved]: a clip that fails to
  /// prefetch must not surface here.
  ///
  /// Two call sites fire this as `unawaited(prepare())`, so a throw had no
  /// handler at all — a slow TTS fetch hitting [_loadTimeout] crashed out as
  /// `Unhandled Exception: TimeoutException` while the learner was mid-card.
  /// The awaited call site ([playCorrectSequence]) was worse: it aborted the
  /// whole playback sequence. Swallowing here is safe because the real fetch
  /// happens again inside [_playResolved], which already reports a timeout to
  /// the learner as a snackbar.
  Future<void> prepare() async {
    final urls = [widget.audioUrl, widget.answerAudioUrl]
        .map(resolveMediaUrl)
        .whereType<String>();
    await Future.wait(
      urls.map((url) => _warmResolved(url).catchError((_) {})),
    );
  }

  Future<void> _playResolved(
    String resolved,
    int sequence, {
    required bool showError,
  }) async {
    if (mounted) setState(() => _loading = true);
    try {
      await _player.stop();
      if (sequence != _playSequence) return;
      if (mounted) setState(() => _playing = true);
      if (kIsWeb) {
        await _player
            .play(UrlSource(resolved))
            .timeout(_webPlayStartTimeout);
      } else {
        final path = await _nativeCachedPath(resolved);
        if (sequence != _playSequence) return;
        await _player.play(DeviceFileSource(path));
      }
    } on MissingPluginException {
      if (mounted) setState(() => _playing = false);
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('quizAudio.pluginNotRegistered'))),
        );
      }
      // This clip will never fire onPlayerComplete — let playCorrectSequence
      // move on to the next clip immediately instead of idling on its timeout.
      _completion?.complete();
      _completion = null;
    } on TimeoutException {
      if (mounted) setState(() => _playing = false);
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('quizAudio.connectionFailed', {'url': resolved}))),
        );
      }
      _completion?.complete();
      _completion = null;
    } catch (e) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('quizAudio.playbackFailed', {'error': e}))),
        );
      }
      if (mounted) setState(() => _playing = false);
      _completion?.complete();
      _completion = null;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showMissing(bool showError) {
    if (showError && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('quizAudio.noAudioFile'))),
      );
    }
  }

  static Future<void> _warmResolved(String resolved) {
    if (kIsWeb) {
      final pending = _webWarmups[resolved];
      if (pending != null) return pending;
      final warm = () async {
        await _cacheDio.get<List<int>>(
          resolved,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: true,
          ),
        ).timeout(_loadTimeout);
      }();
      _webWarmups[resolved] = warm;
      // Same poisoned-cache reasoning as _nativeCachedPath.
      return warm.catchError((Object error) {
        _webWarmups.remove(resolved);
        throw error;
      });
    }
    return _nativeCachedPath(resolved).then((_) {});
  }

  /// Memoised so two buttons racing for the same clip share one download.
  ///
  /// A *failed* future must not stay memoised: the map is static and lives for
  /// the whole process, so one timed-out fetch used to poison that URL for the
  /// rest of the session — every later tap re-awaited the same rejected future
  /// and reported a failure without ever retrying the network.
  static Future<String> _nativeCachedPath(String resolved) {
    final pending = _nativeCacheLoads[resolved];
    if (pending != null) return pending;
    final load = _downloadToCache(resolved);
    _nativeCacheLoads[resolved] = load;
    return load.catchError((Object error) {
      _nativeCacheLoads.remove(resolved);
      throw error;
    });
  }

  static Future<String> _downloadToCache(String resolved) async {
    final resp = await _cacheDio.get<List<int>>(
      resolved,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
      ),
    ).timeout(_loadTimeout);
    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) throw Exception('empty audio response');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/quiz_audio_${resolved.hashCode.abs()}.mp3');
    await file.writeAsBytes(Uint8List.fromList(bytes), flush: true);
    return file.path;
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
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
