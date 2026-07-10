import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../utils/audio_file_import.dart';
import '../utils/audio_mime.dart';
import '../utils/picked_audio_file.dart';
import '../widgets/audio_drop_zone.dart';
import '../utils/wav_builder.dart';
import '../widgets/app_ui.dart';
import 'record_file_io.dart' if (dart.library.html) 'record_file_stub.dart';

// ─── Enums & constants ────────────────────────────────────────────────────────

enum _Stage { input, transcribing, extracting, review }
enum _InputMode { diary, external }
enum _InputSubMode { text, audio }

typedef _SourceCat = ({String key, IconData icon});

const List<_SourceCat> _kSources = [
  (key: '대화',  icon: Icons.forum_outlined),
  (key: '회의록', icon: Icons.people_rounded),
  (key: '책',    icon: Icons.menu_book_rounded),
  (key: '뉴스',  icon: Icons.newspaper_rounded),
  (key: '강연',  icon: Icons.mic_outlined),
  (key: '논문',  icon: Icons.science_outlined),
];

// ─── Claim draft model ────────────────────────────────────────────────────────

class _ClaimDraft {
  _ClaimDraft({
    required String speaker,
    required this.speakerLocked,
    required this.speakerMatched,
    required String title,
    required String statement,
    required this.concepts,
    required this.conceptMatched,
  })  : speakerCtrl = TextEditingController(text: speaker),
        titleCtrl = TextEditingController(text: title),
        statementCtrl = TextEditingController(text: statement);

  final TextEditingController speakerCtrl;
  final bool speakerLocked;
  bool speakerMatched;
  final TextEditingController titleCtrl;   // short node label
  final TextEditingController statementCtrl; // full content stored in description
  List<String> concepts;
  List<bool> conceptMatched;

  void dispose() {
    speakerCtrl.dispose();
    titleCtrl.dispose();
    statementCtrl.dispose();
  }
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class KgBuildScreen extends StatefulWidget {
  const KgBuildScreen({super.key, this.onSaved});

  /// Called after a successful commit. If null, falls back to Navigator.pop.
  final VoidCallback? onSaved;

  @override
  State<KgBuildScreen> createState() => _KgBuildScreenState();
}

class _KgBuildScreenState extends State<KgBuildScreen> {
  _Stage _stage = _Stage.input;
  _InputMode _mode = _InputMode.diary;
  _InputSubMode _subMode = _InputSubMode.text;

  // Text input state
  final _textCtrl = TextEditingController();
  String _sourceCategory = _kSources.first.key;
  List<String> _existingNodes = [];
  bool _nodesLoading = true;

  // Audio input state
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _uploading = false;
  String? _audioFilePath;
  Uint8List? _audioWebBytes;
  String? _audioFilename;
  int _elapsedSec = 0;
  Timer? _timer;
  Stopwatch? _stopwatch;
  StreamSubscription<Uint8List>? _pcmSub;
  final _pcmBuilder = BytesBuilder(copy: false);

  // Review state
  List<_ClaimDraft> _claims = [];
  String _contextType = '개인일기';
  bool _committing = false;

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

  @override
  void initState() {
    super.initState();
    _loadNodes();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _flushClaims();
    _timer?.cancel();
    _pcmSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _flushClaims() {
    for (final c in _claims) {
      c.dispose();
    }
    _claims = [];
  }

  Future<void> _loadNodes() async {
    try {
      final graph = await apiClient.getGraph();
      final raw = graph['nodes'] as List<dynamic>? ?? [];
      final names = raw
          .map((n) => n['name']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (mounted) setState(() { _existingNodes = names; _nodesLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _nodesLoading = false);
    }
  }

  void _setMode(_InputMode m) {
    if (_mode == m) return;
    _flushClaims();
    _clearAudio();
    setState(() { _mode = m; _stage = _Stage.input; });
  }

  void _setSubMode(_InputSubMode s) {
    if (_subMode == s) return;
    _clearAudio();
    setState(() => _subMode = s);
  }

  void _clearAudio() {
    _audioFilePath = null;
    _audioWebBytes = null;
    _audioFilename = null;
    _elapsedSec = 0;
    _pcmBuilder.clear();
  }


  // ── Recording ──────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission || !mounted) return;
    _clearAudio();
    _stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSec = _stopwatch!.elapsed.inSeconds);
    });

    if (kIsWeb) {
      _pcmBuilder.clear();
      final stream = await _recorder.startStream(_webStreamConfig);
      _pcmSub = stream.listen((chunk) {
        _pcmBuilder.add(chunk);
      });
    } else {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/kg_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(_nativeRecordConfig, path: path);
    }
    if (mounted) setState(() => _recording = true);
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
    _stopwatch?.stop();
    setState(() => _recording = false);

    if (kIsWeb) {
      await _recorder.stop();
      _pcmSub?.cancel();
      _pcmSub = null;
      final pcm = _pcmBuilder.takeBytes();
      final wav = buildWavFromPcm(pcm, sampleRate: 16000, numChannels: 1);
      setState(() {
        _audioWebBytes = wav;
        _audioFilename = 'kg_recording.wav';
      });
    } else {
      final path = await _recorder.stop();
      if (path != null && mounted) {
        setState(() {
          _audioFilePath = path;
          _audioFilename = 'kg_recording.m4a';
        });
      }
    }
  }

  Future<void> _pickAudioFile() async {
    final picked = await pickAudioFile();
    if (picked == null || !mounted) return;
    await _applyPickedAudioFile(picked);
  }

  Future<void> _applyPickedAudioFile(PickedAudioFile picked) async {
    if (!mounted) return;
    _clearAudio();
    setState(() {
      _audioWebBytes = picked.bytes;
      _audioFilePath = picked.path;
      _audioFilename = picked.name;
    });
  }

  // ── Transcribe + smart routing ─────────────────────────────────────────────

  Future<void> _transcribeAndRoute() async {
    final hasAudio = (_audioWebBytes != null && _audioWebBytes!.isNotEmpty) ||
        (_audioFilePath != null);
    if (!hasAudio) return;

    setState(() { _uploading = true; _stage = _Stage.transcribing; });
    try {
      List<int> bytes;
      String filename;
      String mime;

      if (_audioWebBytes != null) {
        bytes = _audioWebBytes!;
        filename = _audioFilename ?? 'audio.wav';
        mime = audioMimeTypeForFilename(filename);
      } else {
        bytes = await readAudioFile(_audioFilePath!);
        filename = _audioFilename ?? _audioFilePath!.split('/').last;
        mime = audioMimeTypeForFilename(filename);
      }

      final result = await apiClient.transcribeAudioForKg(
        bytes,
        filename: filename,
        mimeType: mime,
      );

      final speakerCount = (result['speaker_count'] as num?)?.toInt() ?? 1;
      final transcript = result['plain_transcript']?.toString() ?? '';
      final segments = result['segments'] as List<dynamic>? ?? [];

      if (!mounted) return;

      if (_mode == _InputMode.diary && speakerCount > 1) {
        // Warn and offer to switch to external mode
        final switchNow = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('화자가 여러 명 감지됨'),
            content: Text(
              '음성에서 $speakerCount명의 화자가 감지되었습니다.\n'
              '개인 일기는 나 혼자(단일 화자)만 지원합니다.\n'
              '대화·소스 모드로 전환하여 화자별로 처리하시겠습니까?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('대화·소스로 전환'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (switchNow == true) {
          // Switch to external mode and populate text with labeled transcript
          _flushClaims();
          setState(() {
            _mode = _InputMode.external;
            _stage = _Stage.input;
            _subMode = _InputSubMode.text;
            _textCtrl.text = result['transcript']?.toString() ?? transcript;
          });
        } else {
          setState(() => _stage = _Stage.input);
        }
        return;
      }

      if (_mode == _InputMode.diary) {
        // Single speaker — fill text and proceed to LLM extraction
        _textCtrl.text = transcript;
        setState(() => _stage = _Stage.input);
        await _extract();
      } else {
        // External mode — build speaker-labeled text for LLM
        // If diarization ran, use labeled transcript; else plain
        final labeled = speakerCount > 1
            ? _buildLabeledText(segments)
            : transcript;
        _textCtrl.text = labeled;
        setState(() => _stage = _Stage.input);
        await _extract();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('음성 변환 실패: $e')),
        );
        setState(() { _uploading = false; _stage = _Stage.input; });
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String _buildLabeledText(List<dynamic> segments) {
    final buf = StringBuffer();
    for (final seg in segments) {
      final speaker = seg['speaker']?.toString() ?? 'Speaker';
      final text = seg['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) buf.writeln('[$speaker] $text');
    }
    return buf.toString().trim();
  }

  Future<void> _extract() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _stage = _Stage.extracting);
    try {
      final result = await apiClient.extractKgFromText(
        mode: _mode == _InputMode.diary ? 'diary' : 'external',
        fixedSpeaker: _mode == _InputMode.diary ? '나' : null,
        sourceCategory: _mode == _InputMode.external ? _sourceCategory : null,
        text: text,
        existingNodes: _existingNodes,
      );
      _applyDraft(result);
      setState(() => _stage = _Stage.review);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('추출 실패: $e')),
        );
        setState(() => _stage = _Stage.input);
      }
    }
  }

  void _applyDraft(Map<String, dynamic> d) {
    _flushClaims();
    if (_mode == _InputMode.diary) {
      final nodes = (d['nodes'] as Map?)?.cast<String, dynamic>() ?? {};
      final concepts = (d['concepts'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList();
      final matchedMap = d['isExistingNodeMatched'];
      final mList = (matchedMap is Map)
          ? (matchedMap['concepts'] as List<dynamic>? ?? [])
          : <dynamic>[];
      _claims = [
        _ClaimDraft(
          speaker: '나',
          speakerLocked: true,
          speakerMatched: true,
          title: nodes['title']?.toString() ?? '',
          statement: nodes['statement']?.toString() ?? '',
          concepts: concepts,
          conceptMatched: List.generate(
            concepts.length,
            (i) => i < mList.length ? mList[i] == true : false,
          ),
        ),
      ];
      _contextType = '개인일기';
    } else {
      final rawList = d['claims'] as List<dynamic>? ?? [];
      _claims = rawList.map((raw) {
        final c = (raw as Map).cast<String, dynamic>();
        final concepts = (c['concepts'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
        final cm = c['concepts_matched'] as List<dynamic>? ?? [];
        return _ClaimDraft(
          speaker: c['speaker']?.toString() ?? '',
          speakerLocked: false,
          speakerMatched: c['speaker_matched'] == true,
          title: c['title']?.toString() ?? '',
          statement: c['statement']?.toString() ?? '',
          concepts: concepts,
          conceptMatched: List.generate(
            concepts.length,
            (i) => i < cm.length ? cm[i] == true : false,
          ),
        );
      }).toList();
      final opts = (d['contextTypeOptions'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList();
      _contextType = opts.isNotEmpty ? opts.first : _sourceCategory;
    }
  }

  Future<void> _commit() async {
    if (_committing || _claims.isEmpty) return;
    setState(() => _committing = true);
    try {
      final payload = _claims
          .map((c) => {
                'speaker': c.speakerCtrl.text.trim(),
                'title': c.titleCtrl.text.trim(),
                'statement': c.statementCtrl.text.trim(),
                'concepts': c.concepts,
              })
          .toList();
      await apiClient.commitKgDraft(
        claims: payload,
        contextType: _contextType,
        originalText: _textCtrl.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_claims.length}개 클레임을 그래프에 저장했습니다.'),
          ),
        );
        if (widget.onSaved != null) {
          widget.onSaved!();
        } else {
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReview = _stage == _Stage.review;
    final subtitle = isReview
        ? (_mode == _InputMode.diary
            ? '내용을 확인하고 저장하세요'
            : '${_claims.length}개 클레임을 확인하고 저장하세요')
        : null;

    return Scaffold(
      appBar: AppHubAppBar(title: '지식 소스 등록', subtitle: subtitle),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.transcribing => const AppLoadingScreen(message: '음성을 텍스트로 변환하는 중…'),
          _Stage.extracting => AppLoadingScreen(
              message: _mode == _InputMode.diary
                  ? '핵심 명제를 정제하는 중…'
                  : '텍스트에서 화자와 클레임을 분리하는 중…',
            ),
          _Stage.input => _InputView(
              mode: _mode,
              subMode: _subMode,
              textCtrl: _textCtrl,
              sourceCategory: _sourceCategory,
              existingNodes: _existingNodes,
              nodesLoading: _nodesLoading,
              recording: _recording,
              uploading: _uploading,
              elapsedSec: _elapsedSec,
              hasAudio: (_audioWebBytes?.isNotEmpty == true) || _audioFilePath != null,
              audioFilename: _audioFilename,
              onModeChanged: _setMode,
              onSubModeChanged: _setSubMode,
              onSourceCategoryChanged: (cat) => setState(() => _sourceCategory = cat),
              onExtract: _extract,
              onStartRecording: _startRecording,
              onStopRecording: _stopRecording,
              onPickFile: _pickAudioFile,
              onFilePicked: _applyPickedAudioFile,
              onTranscribe: _transcribeAndRoute,
            ),
          _Stage.review => _ReviewView(
              mode: _mode,
              claims: _claims,
              contextType: _contextType,
              committing: _committing,
              onClaimDeleted: (i) => setState(() {
                _claims[i].dispose();
                _claims.removeAt(i);
              }),
              onConceptsChanged: (i, c, m) => setState(() {
                _claims[i].concepts = c;
                _claims[i].conceptMatched = m;
              }),
              onBack: () => setState(() => _stage = _Stage.input),
              onCommit: _commit,
            ),
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Input view
// ─────────────────────────────────────────────────────────────────────────────

class _InputView extends StatelessWidget {
  const _InputView({
    required this.mode,
    required this.subMode,
    required this.textCtrl,
    required this.sourceCategory,
    required this.existingNodes,
    required this.nodesLoading,
    required this.recording,
    required this.uploading,
    required this.elapsedSec,
    required this.hasAudio,
    required this.audioFilename,
    required this.onModeChanged,
    required this.onSubModeChanged,
    required this.onSourceCategoryChanged,
    required this.onExtract,
    required this.onStartRecording,
    required this.onStopRecording,
    required this.onPickFile,
    required this.onFilePicked,
    required this.onTranscribe,
  });

  final _InputMode mode;
  final _InputSubMode subMode;
  final TextEditingController textCtrl;
  final String sourceCategory;
  final List<String> existingNodes;
  final bool nodesLoading;
  final bool recording;
  final bool uploading;
  final int elapsedSec;
  final bool hasAudio;
  final String? audioFilename;
  final void Function(_InputMode) onModeChanged;
  final void Function(_InputSubMode) onSubModeChanged;
  final void Function(String) onSourceCategoryChanged;
  final VoidCallback onExtract;
  final VoidCallback onStartRecording;
  final VoidCallback onStopRecording;
  final VoidCallback onPickFile;
  final AudioFilePickedCallback onFilePicked;  // drag-drop callback
  final VoidCallback onTranscribe;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageH, AppSpacing.pageV,
        AppSpacing.pageH, AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Mode toggle ──────────────────────────────────────────────────
          SegmentedButton<_InputMode>(
            segments: const [
              ButtonSegment(
                value: _InputMode.diary,
                icon: Icon(Icons.edit_note_rounded),
                label: Text('개인 일기'),
              ),
              ButtonSegment(
                value: _InputMode.external,
                icon: Icon(Icons.forum_outlined),
                label: Text('대화·소스'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onModeChanged(s.first),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ── Text / Audio sub-mode toggle ─────────────────────────────────
          SegmentedButton<_InputSubMode>(
            segments: const [
              ButtonSegment(
                value: _InputSubMode.text,
                icon: Icon(Icons.text_fields_rounded),
                label: Text('텍스트'),
              ),
              ButtonSegment(
                value: _InputSubMode.audio,
                icon: Icon(Icons.mic_rounded),
                label: Text('음성'),
              ),
            ],
            selected: {subMode},
            onSelectionChanged: (s) => onSubModeChanged(s.first),
          ),
          const SizedBox(height: AppSpacing.lg),

          // ── Mode-specific content ─────────────────────────────────────────
          if (subMode == _InputSubMode.audio)
            _AudioInputContent(
              mode: mode,
              recording: recording,
              uploading: uploading,
              elapsedSec: elapsedSec,
              hasAudio: hasAudio,
              audioFilename: audioFilename,
              onStartRecording: onStartRecording,
              onStopRecording: onStopRecording,
              onPickFile: onPickFile,
              onFilePicked: onFilePicked,
              onTranscribe: onTranscribe,
            )
          else if (mode == _InputMode.diary)
            _DiaryInputContent(textCtrl: textCtrl)
          else
            _ExternalInputContent(
              textCtrl: textCtrl,
              sourceCategory: sourceCategory,
              existingNodes: existingNodes,
              nodesLoading: nodesLoading,
              onSourceCategoryChanged: onSourceCategoryChanged,
            ),

          if (subMode == _InputSubMode.text) ...[
            const SizedBox(height: AppSpacing.xxl),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: textCtrl,
              builder: (context, value, _) => FilledButton.icon(
                onPressed: value.text.trim().isNotEmpty ? onExtract : null,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: Text(
                  mode == _InputMode.diary ? '핵심 명제 추출하기' : '화자 및 클레임 분석하기',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Audio input content ─────────────────────────────────────────────────────

class _AudioInputContent extends StatefulWidget {
  const _AudioInputContent({
    required this.mode,
    required this.recording,
    required this.uploading,
    required this.elapsedSec,
    required this.hasAudio,
    required this.audioFilename,
    required this.onStartRecording,
    required this.onStopRecording,
    required this.onPickFile,
    required this.onFilePicked,
    required this.onTranscribe,
  });

  final _InputMode mode;
  final bool recording;
  final bool uploading;
  final int elapsedSec;
  final bool hasAudio;
  final String? audioFilename;
  final VoidCallback onStartRecording;
  final VoidCallback onStopRecording;
  final VoidCallback onPickFile;
  final AudioFilePickedCallback onFilePicked;
  final VoidCallback onTranscribe;

  @override
  State<_AudioInputContent> createState() => _AudioInputContentState();
}

class _AudioInputContentState extends State<_AudioInputContent> {
  bool _dragging = false;

  String _fmtTime(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Info banner
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.07),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.primary.withOpacity(0.15)),
          ),
          child: Text(
            widget.mode == _InputMode.diary
                ? '개인 일기: 나 혼자(단일 화자)로 처리합니다. 음성에서 다른 화자가 감지되면 대화·소스 모드로 자동 안내합니다.'
                : '대화·소스: 나 외 화자가 1명이라도 있으면 사용합니다. 화자 분리(diarization) 후 각 화자별 클레임을 추출합니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.primary),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // Record button
        Center(
          child: GestureDetector(
            onTap: widget.recording ? widget.onStopRecording : widget.onStartRecording,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.recording ? Colors.red : cs.primary,
                boxShadow: widget.recording
                    ? [BoxShadow(color: Colors.red.withOpacity(0.4), blurRadius: 18, spreadRadius: 4)]
                    : [BoxShadow(color: cs.primary.withOpacity(0.3), blurRadius: 12, spreadRadius: 2)],
              ),
              child: Icon(
                widget.recording ? Icons.stop_rounded : Icons.mic_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Center(
          child: Text(
            widget.recording ? '녹음 중… ${_fmtTime(widget.elapsedSec)}' : '탭하여 녹음 시작',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: widget.recording ? Colors.red : context.mutedText,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // Divider with "or"
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text('또는', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText)),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),

        // Drop zone + file pick button
        AudioDropZone(
          enabled: !widget.recording && !widget.uploading,
          dragging: _dragging,
          onDraggingChanged: (v) => setState(() => _dragging = v),
          onTap: widget.onPickFile,
          onFilePicked: widget.onFilePicked,
          onError: (msg) => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), backgroundColor: Colors.red),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            decoration: BoxDecoration(
              color: _dragging
                  ? cs.primary.withOpacity(0.08)
                  : cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
              border: Border.all(
                color: _dragging ? cs.primary : cs.outlineVariant,
                width: _dragging ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _dragging
                      ? Icons.file_download_rounded
                      : (widget.audioFilename != null
                          ? Icons.audio_file_rounded
                          : Icons.upload_file_rounded),
                  size: 32,
                  color: _dragging ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(height: 8),
                Text(
                  _dragging
                      ? '여기에 놓으세요'
                      : (widget.audioFilename != null
                          ? widget.audioFilename!
                          : '드래그하거나 탭하여 파일 선택'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _dragging ? cs.primary : cs.onSurfaceVariant,
                    fontWeight: _dragging ? FontWeight.w600 : FontWeight.normal,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (!_dragging && widget.audioFilename == null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'wav · mp3 · m4a · aac',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant.withOpacity(0.6),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        if (widget.hasAudio) ...[
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: widget.uploading ? null : widget.onTranscribe,
            icon: widget.uploading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.transcribe_rounded, size: 18),
            label: Text(widget.uploading ? '변환 중…' : 'STT 변환 후 추출하기'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          ),
        ],
      ],
    );
  }
}

// ─── Diary input content ─────────────────────────────────────────────────────

class _DiaryInputContent extends StatelessWidget {
  const _DiaryInputContent({required this.textCtrl});
  final TextEditingController textCtrl;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Locked speaker badge
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Icon(Icons.lock_rounded, size: 15, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                '화자: 나 (자동 고정)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
              const Spacer(),
              Text(
                'LLM이 명제와 개념만 정제합니다',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.accent.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppSurfaceCard(
          child: TextField(
            controller: textCtrl,
            maxLines: 10,
            minLines: 6,
            decoration: const InputDecoration(
              hintText: '오늘 있었던 일이나 생각을 자유롭게 적어주세요…',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── External input content ──────────────────────────────────────────────────

class _ExternalInputContent extends StatelessWidget {
  const _ExternalInputContent({
    required this.textCtrl,
    required this.sourceCategory,
    required this.existingNodes,
    required this.nodesLoading,
    required this.onSourceCategoryChanged,
  });

  final TextEditingController textCtrl;
  final String sourceCategory;
  final List<String> existingNodes;
  final bool nodesLoading;
  final void Function(String) onSourceCategoryChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('소스 유형', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final s in _kSources)
              FilterChip(
                avatar: Icon(s.icon, size: 14),
                label: Text(s.key),
                selected: sourceCategory == s.key,
                onSelected: (_) => onSourceCategoryChanged(s.key),
                selectedColor: AppColors.primary.withValues(alpha: 0.15),
                checkmarkColor: AppColors.primary,
                side: BorderSide(
                  color: sourceCategory == s.key
                      ? AppColors.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                  width: sourceCategory == s.key ? 1.5 : 1,
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        AppSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LLM이 텍스트에서 화자별로 클레임을 자동 분리합니다.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.mutedText,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: textCtrl,
                maxLines: 10,
                minLines: 6,
                decoration: const InputDecoration(
                  hintText: '텍스트를 붙여넣으세요 (대화록, 책 구절, 뉴스 기사 등)…',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ],
          ),
        ),
        if (!nodesLoading && existingNodes.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            '등록된 인물/출처 ${existingNodes.length}개 — LLM이 Entity Resolution에 활용합니다',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.mutedText,
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Review view
// ─────────────────────────────────────────────────────────────────────────────

class _ReviewView extends StatelessWidget {
  const _ReviewView({
    required this.mode,
    required this.claims,
    required this.contextType,
    required this.committing,
    required this.onClaimDeleted,
    required this.onConceptsChanged,
    required this.onBack,
    required this.onCommit,
  });

  final _InputMode mode;
  final List<_ClaimDraft> claims;
  final String contextType;
  final bool committing;
  final void Function(int) onClaimDeleted;
  final void Function(int, List<String>, List<bool>) onConceptsChanged;
  final VoidCallback onBack;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageH, AppSpacing.pageV,
        AppSpacing.pageH, AppSpacing.xxl,
      ),
      children: [
        // Review banner
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Icon(Icons.rate_review_outlined, color: AppColors.primary, size: 20),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'AI 초안입니다. 확인·수정 후 저장하세요. '
                  '최종 저장 전까지 DB에 기록되지 않습니다.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Context type indicator
        Row(
          children: [
            Icon(Icons.category_outlined, size: 14, color: context.mutedText),
            const SizedBox(width: 6),
            Text(
              '매체 유형: $contextType',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.mutedText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),

        // Claim cards
        if (claims.isEmpty)
          AppEmptyState(
            icon: Icons.inbox_outlined,
            title: '추출된 클레임이 없습니다',
            subtitle: '다시 입력을 눌러 텍스트를 수정해 보세요.',
          )
        else
          for (var i = 0; i < claims.length; i++) ...[
            _ClaimCard(
              index: i,
              draft: claims[i],
              canDelete: mode == _InputMode.external && claims.length > 1,
              onDelete: () => onClaimDeleted(i),
              onConceptsChanged: (c, m) => onConceptsChanged(i, c, m),
            ),
            const SizedBox(height: AppSpacing.md),
          ],

        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: committing ? null : onBack,
                icon: const Icon(Icons.arrow_back_outlined, size: 18),
                label: const Text('다시 입력'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: (committing || claims.isEmpty) ? null : onCommit,
                icon: committing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: Text(committing ? '저장 중…' : '최종 컨펌 및 저장'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Claim card ───────────────────────────────────────────────────────────────

class _ClaimCard extends StatelessWidget {
  const _ClaimCard({
    required this.index,
    required this.draft,
    required this.canDelete,
    required this.onDelete,
    required this.onConceptsChanged,
  });

  final int index;
  final _ClaimDraft draft;
  final bool canDelete;
  final VoidCallback onDelete;
  final void Function(List<String>, List<bool>) onConceptsChanged;

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.hubGraph.withValues(alpha: 0.12),
                ),
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.hubGraph,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('클레임 ${index + 1}',
                  style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              if (canDelete)
                IconButton(
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  tooltip: '이 클레임 제외',
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),

          // Speaker
          _FieldLabel(
            icon: Icons.person_outline,
            label: '화자',
            badge: _Badge(
              label: draft.speakerLocked
                  ? '고정'
                  : (draft.speakerMatched ? '기존 노드' : '신규'),
              color: draft.speakerLocked || draft.speakerMatched
                  ? AppColors.accent
                  : AppColors.accentWarm,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          draft.speakerLocked
              ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Text(
                    draft.speakerCtrl.text,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                )
              : TextField(
                  controller: draft.speakerCtrl,
                  decoration: const InputDecoration(isDense: true),
                ),
          const SizedBox(height: AppSpacing.lg),

          // Title (short node label)
          _FieldLabel(icon: Icons.title_rounded, label: '노드 제목'),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: draft.titleCtrl,
            maxLines: 1,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '그래프에서 표시될 짧은 제목',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Statement
          _FieldLabel(icon: Icons.format_quote_rounded, label: '핵심 진술 (전문)'),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: draft.statementCtrl,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(isDense: true),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Concepts
          _FieldLabel(icon: Icons.label_outline, label: '개념 태그'),
          const SizedBox(height: AppSpacing.sm),
          _ConceptTagEditor(
            concepts: draft.concepts,
            matched: draft.conceptMatched,
            onChanged: onConceptsChanged,
          ),
        ],
      ),
    );
  }
}

// ─── Concept tag editor ───────────────────────────────────────────────────────

class _ConceptTagEditor extends StatefulWidget {
  const _ConceptTagEditor({
    required this.concepts,
    required this.matched,
    required this.onChanged,
  });

  final List<String> concepts;
  final List<bool> matched;
  final void Function(List<String>, List<bool>) onChanged;

  @override
  State<_ConceptTagEditor> createState() => _ConceptTagEditorState();
}

class _ConceptTagEditorState extends State<_ConceptTagEditor> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _remove(int i) {
    final c = List<String>.from(widget.concepts)..removeAt(i);
    final m = List<bool>.from(widget.matched)..removeAt(i);
    widget.onChanged(c, m);
  }

  void _add() {
    final tag = _ctrl.text.trim();
    if (tag.isEmpty || widget.concepts.contains(tag)) return;
    widget.onChanged([...widget.concepts, tag], [...widget.matched, false]);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.concepts.isEmpty)
          Text(
            '추출된 개념이 없습니다. 아래에서 직접 추가하세요.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (var i = 0; i < widget.concepts.length; i++)
                _ConceptChip(
                  label: widget.concepts[i],
                  matched: i < widget.matched.length ? widget.matched[i] : false,
                  onDelete: () => _remove(i),
                ),
            ],
          ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '새 개념 태그 입력 후 추가',
                  prefixIcon: Icon(Icons.add, size: 18),
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton.tonal(
              onPressed: _add,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: 14,
                ),
              ),
              child: const Text('추가'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            _Legend(color: AppColors.accent, label: '기존 노드 매칭'),
            const SizedBox(width: AppSpacing.lg),
            _Legend(color: AppColors.accentWarm, label: '신규 생성'),
          ],
        ),
      ],
    );
  }
}

// ─── Small helpers ────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.icon, required this.label, this.badge});
  final IconData icon;
  final String label;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: context.mutedText),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: context.mutedText,
          ),
        ),
        if (badge != null) ...[const SizedBox(width: AppSpacing.sm), badge!],
      ],
    );
  }
}

class _ConceptChip extends StatelessWidget {
  const _ConceptChip({
    required this.label,
    required this.matched,
    required this.onDelete,
  });
  final String label;
  final bool matched;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final color = matched ? AppColors.accent : AppColors.accentWarm;
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
      deleteIcon: Icon(Icons.close, size: 15, color: color.withValues(alpha: 0.8)),
      onDeleted: onDelete,
      visualDensity: VisualDensity.compact,
      labelPadding: const EdgeInsets.only(left: 4),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.35),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.mutedText,
          ),
        ),
      ],
    );
  }
}
