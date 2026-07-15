import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chat/chat_session_controller.dart';
import '../theme/app_theme.dart';
import '../utils/audio_file_import.dart';
import '../utils/audio_mime.dart';
import '../utils/wav_builder.dart';
import 'audio_record_core.dart';
import 'mention_editor_core.dart';

/// Chat input replacement for [ChatMode.journal].
class ChatJournalComposeBar extends StatefulWidget {
  const ChatJournalComposeBar({super.key});

  @override
  State<ChatJournalComposeBar> createState() => _ChatJournalComposeBarState();
}

class _ChatJournalComposeBarState extends State<ChatJournalComposeBar> {
  final _fieldKey = GlobalKey<MentionAutocompleteFieldState>();
  late final AudioRecordController _recorder;
  bool _expanded = false;
  bool _saving = false;
  int _charCount = 0;

  @override
  void initState() {
    super.initState();
    _recorder = AudioRecordController();
    _recorder.attachStateListener();
    _recorder.onMaxDurationReached = () {
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('최대 10분까지 녹음됩니다 — 녹음이 자동으로 중지되었어요.'),
          duration: Duration(seconds: 5),
        ),
      );
      unawaited(_uploadRecording());
    };
    _recorder.onBrowserInterrupted = (msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
        );
        setState(() {});
      }
    };
    _recorder.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _confirmExit() async {
    final field = _fieldKey.currentState;
    final dirty = (field?.text.trim().isNotEmpty ?? false) || _recorder.recording;
    if (dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('작성을 취소할까요?'),
          content: const Text('입력한 내용이 사라집니다.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('계속 쓰기')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('취소')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (_recorder.recording) await _recorder.stop();
    chatSession.exitMode();
  }

  String _labeledFromField() {
    final field = _fieldKey.currentState;
    if (field == null) return '';
    final raw = field.text;
    final text = raw.trim();
    if (text.isEmpty) return '';
    final hits = findMentions(raw, field.matchableNames());
    if (hits.isNotEmpty) {
      return toLabeledLines(splitByMentions(raw, hits));
    }
    final legacy = parseDialogueLines(text);
    if (legacy != null) {
      return toLabeledLines(legacy.lines);
    }
    return toLabeledLines([MapEntry('나', text)]);
  }

  Future<void> _saveText() async {
    final field = _fieldKey.currentState;
    if (field == null) return;
    final text = field.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('텍스트를 입력해 주세요')),
      );
      return;
    }
    if (text.length > kMaxJournalTextChars) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('입력이 너무 깁니다'),
          content: Text(
            '현재 ${text.length}자 / 최대 $kMaxJournalTextChars자입니다.\n'
            '내용을 나눠서 여러 번 입력해 주세요.',
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('확인')),
          ],
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await chatSession.saveJournalText(_labeledFromField());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleMic() async {
    if (_recorder.recording) {
      final result = await _recorder.stop();
      if (!mounted) return;
      setState(() {});
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('녹음된 내용이 없어요')),
        );
        return;
      }
      await _saveAudioResult(result);
      return;
    }
    try {
      final ok = await _recorder.start();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('마이크 권한이 필요합니다. 브라우저 주소창 옆 🔒에서 허용해 주세요.'),
          ),
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('녹음 시작 실패: $e')),
        );
      }
    }
  }

  Future<void> _uploadRecording() async {
    final result = await _recorder.stop();
    if (result == null || !mounted) return;
    await _saveAudioResult(result);
  }

  Future<void> _saveAudioResult(AudioRecordResult result) async {
    setState(() => _saving = true);
    try {
      await chatSession.saveJournalAudio(
        path: result.path,
        bytes: result.bytes,
        filename: result.filename,
        mimeType: result.mimeType,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickFile() async {
    if (_recorder.recording) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('녹음을 먼저 중지한 뒤 파일을 선택해 주세요.')),
      );
      return;
    }
    try {
      final picked = await pickAudioFile();
      if (picked == null || !mounted) return;
      setState(() => _saving = true);
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('파일 데이터를 읽을 수 없습니다.');
        }
        await chatSession.saveJournalAudio(
          bytes: bytes,
          filename: picked.name,
          mimeType: audioMimeTypeForFilename(picked.name),
        );
      } else {
        final path = picked.path;
        if (path == null) throw Exception('파일 경로를 확인할 수 없습니다.');
        await chatSession.saveJournalAudio(
          path: path,
          filename: picked.name,
          mimeType: audioMimeTypeForFilename(picked.name),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('파일 선택 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxLines = _expanded ? 22 : 10;
    final recording = _recorder.recording;
    final shell = context.shell;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: shell.panelBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '취소',
                    onPressed: _saving ? null : _confirmExit,
                    icon: Icon(Icons.close_rounded,
                        color: shell.primaryText, size: 20),
                  ),
                  Expanded(
                    child: Text(
                      '일기 쓰기',
                      style: TextStyle(
                        color: shell.primaryText,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    '$_charCount / $kMaxJournalTextChars',
                    style: TextStyle(
                      fontSize: 11,
                      color: shell.mutedText,
                    ),
                  ),
                  IconButton(
                    tooltip: _expanded ? '축소' : '확장',
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded
                          ? Icons.unfold_less_rounded
                          : Icons.unfold_more_rounded,
                      color: shell.primaryText.withValues(alpha: 0.75),
                      size: 20,
                    ),
                  ),
                ],
              ),
              MentionAutocompleteField(
                key: _fieldKey,
                minLines: 3,
                maxLines: maxLines,
                showCounter: false,
                // Docked at the bottom of the screen — open the @-mention popup
                // upward so it isn't clipped below the viewport.
                openUpward: true,
                enabled: !_saving && !recording,
                onChanged: (t) => setState(() => _charCount = t.length),
                decoration: InputDecoration(
                  hintText: '그냥 쓰면 나의 일기 · @로 화자 지정\n예: @엄마 10시까지 오라고 했어',
                  hintStyle: TextStyle(
                    color: shell.mutedText,
                    fontSize: 13,
                  ),
                  filled: true,
                  fillColor: shell.subtleSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    tooltip: recording ? '녹음 중지·저장' : '음성 녹음',
                    onPressed: _saving ? null : _toggleMic,
                    icon: Icon(
                      recording ? Icons.stop_circle_rounded : Icons.mic_rounded,
                      color: recording ? Colors.redAccent : AppColors.hubVoice,
                    ),
                  ),
                  if (recording)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        formatDuration(_recorder.elapsedSec),
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '음성 파일',
                    onPressed: _saving || recording ? null : _pickFile,
                    icon: Icon(
                      Icons.attach_file_rounded,
                      color: shell.primaryText.withValues(alpha: 0.75),
                    ),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _saving || recording ? null : _saveText,
                    icon: _saving
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.onPrimary),
                          )
                        : const Icon(Icons.save_alt_outlined, size: 18),
                    label: Text(_saving ? '저장 중…' : '저장'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Local unawaited helper (avoid importing dart:async just for this).
void unawaited(Future<void> f) {}
