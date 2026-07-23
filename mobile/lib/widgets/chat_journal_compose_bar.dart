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
    final maxLines = _expanded ? 20 : 7;
    final recording = _recorder.recording;
    final shell = context.shell;
    final scheme = Theme.of(context).colorScheme;
    // An inline card that lives IN the chat feed (not a docked bar) — rounded
    // surface, subtle border, no full-width top divider.
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: shell.panelBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: brand badge + title + counter + expand + close.
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.hubVoice, AppColors.accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.auto_stories_rounded,
                    size: 13, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Text(
                '일기 쓰기',
                style: TextStyle(
                  color: shell.primaryText,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
              const Spacer(),
              Text(
                '$_charCount / $kMaxJournalTextChars',
                style: TextStyle(fontSize: 11, color: shell.mutedText),
              ),
              const SizedBox(width: 2),
              _HeaderIcon(
                tooltip: _expanded ? '축소' : '확장',
                icon: _expanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                onTap: () => setState(() => _expanded = !_expanded),
              ),
              _HeaderIcon(
                tooltip: '닫기',
                icon: Icons.close_rounded,
                onTap: _saving ? null : _confirmExit,
              ),
            ],
          ),
          const SizedBox(height: 10),
          MentionAutocompleteField(
            key: _fieldKey,
            minLines: 3,
            maxLines: maxLines,
            showCounter: false,
            // The card sits near the bottom of the feed, so open the @-mention
            // popup upward to avoid clipping below the viewport.
            openUpward: true,
            enabled: !_saving && !recording,
            onChanged: (t) => setState(() => _charCount = t.length),
            decoration: InputDecoration(
              hintText: '그냥 쓰면 나의 일기 · @로 화자 지정\n예: @엄마 10시까지 오라고 했어',
              hintStyle: TextStyle(color: shell.mutedText, fontSize: 13),
              filled: true,
              fillColor: shell.subtleSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // Mic — pill that turns into a recording indicator.
              _ActionButton(
                onTap: _saving ? null : _toggleMic,
                active: recording,
                activeColor: Colors.redAccent,
                idleColor: AppColors.hubVoice,
                icon: recording
                    ? Icons.stop_rounded
                    : Icons.mic_none_rounded,
                label: recording ? formatDuration(_recorder.elapsedSec) : null,
              ),
              const SizedBox(width: 6),
              _ActionButton(
                onTap: _saving || recording ? null : _pickFile,
                idleColor: shell.primaryText.withValues(alpha: 0.7),
                icon: Icons.attach_file_rounded,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saving || recording ? null : _saveText,
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                ),
                icon: _saving
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: scheme.onPrimary),
                      )
                    : const Icon(Icons.arrow_upward_rounded, size: 18),
                label: Text(_saving ? '저장 중…' : '저장'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small square header affordance (expand / close) for the compose card.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon(
      {required this.tooltip, required this.icon, required this.onTap});
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      iconSize: 19,
      color: context.shell.primaryText.withValues(alpha: 0.7),
      icon: Icon(icon),
    );
  }
}

/// Rounded icon (optionally with a label) for the mic / file actions.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.onTap,
    required this.icon,
    required this.idleColor,
    this.active = false,
    this.activeColor,
    this.label,
  });

  final VoidCallback? onTap;
  final IconData icon;
  final Color idleColor;
  final bool active;
  final Color? activeColor;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = active ? (activeColor ?? idleColor) : idleColor;
    return Material(
      color: active
          ? color.withValues(alpha: 0.12)
          : context.shell.subtleSurface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: label != null ? 12 : 10, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              if (label != null) ...[
                const SizedBox(width: 6),
                Text(
                  label!,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Local unawaited helper (avoid importing dart:async just for this).
void unawaited(Future<void> f) {}
