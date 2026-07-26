import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_session_controller.dart' show chatSession;
import '../chat/chat_suggestions.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../utils/audio_file_import.dart';
import '../utils/audio_mime.dart';
import '../utils/graph_layout.dart';
import 'audio_record_core.dart';
import 'chat_rich_text.dart';
import 'chat_suggestion_rail.dart';
import 'journal_progress_card.dart';
import 'mention_editor_core.dart';
import 'quiz/quiz_viewport_scope.dart';
import 'thinking_orbs.dart';

/// 지식그래프 화면 위에 떠 있는 바텀시트 형태의 대화 패널 (헤더 + 메시지 피드만).
///
/// 입력바는 여기 포함되지 않는다 — [ChatInputBar]로 분리되어 시트 밖에 항상
/// 도킹된 채 떠 있는다 (최소화 상태에서도 계속 탭 가능해야 하므로). 이 위젯은
/// `DraggableScrollableSheet.builder`가 넘겨주는 콘텐츠로 직접 임베드된다.
class GraphChatPanel extends StatelessWidget {
  const GraphChatPanel({
    super.key,
    required this.messages,
    required this.busy,
    required this.typeColors,
    required this.nodeById,
    required this.scrollController,
    required this.onNodeHighlight,
    required this.onNodeSelect,
    required this.onClearHistory,
    this.title,
    this.listFooter,
    this.onHandleDragUpdate,
    this.onHandleDragEnd,
    this.onPanelTap,
    this.quizMode = false,
    this.listBottomInset = 96,
  });

  final List<GraphChatMessage> messages;
  final bool busy;
  final Map<String, Color> typeColors;
  final Map<String, Map<String, dynamic>> nodeById;
  final ScrollController scrollController;
  final void Function(Set<String> nodeIds) onNodeHighlight;
  final void Function(Map<String, dynamic> node) onNodeSelect;
  final VoidCallback onClearHistory;

  /// Active chat-room title, shown in the sheet header (falls back to a
  /// generic label). The screen no longer has an AppBar to display it.
  final String? title;

  /// Optional block appended after messages inside the chat scroll (e.g. distill draft).
  final Widget? listFooter;

  final ValueChanged<double>? onHandleDragUpdate;
  final VoidCallback? onHandleDragEnd;
  final VoidCallback? onPanelTap;
  final bool quizMode;

  /// Height of the composer docked over this sheet, measured by the screen.
  /// The feed pads its tail by this much so the last message clears it — a
  /// constant used to under-shoot whenever the composer grew (mode chip, a
  /// wrapped input line, the home-indicator inset).
  final double listBottomInset;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: shell.panelBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppSpacing.radiusXl),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Listener(
        onPointerDown: onPanelTap == null ? null : (_) => onPanelTap!(),
        child: Material(
          color: Colors.transparent,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetDragHandle(
              onDragUpdate: onHandleDragUpdate,
              onDragEnd: onHandleDragEnd,
            ),
            Expanded(
              child: quizMode && listFooter != null
                  ? Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        AppSpacing.xs,
                        AppSpacing.md,
                        listBottomInset + 12,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) => Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: double.infinity,
                            child: QuizViewportScope(
                              availableHeight: constraints.maxHeight,
                              child: listFooter!,
                            ),
                          ),
                        ),
                      ),
                    )
                  : Stack(
                      children: [
                        Positioned.fill(child: _buildMessageList(context)),
                        Positioned(
                          right: 14,
                          bottom: 100,
                          child: _ScrollToBottomButton(
                            controller: scrollController,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildMessageList(BuildContext context) {
    final shell = context.shell;
    final hasFooter = listFooter != null;
    if (messages.isEmpty && !busy && !hasFooter) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: onHandleDragUpdate == null
            ? null
            : (details) => onHandleDragUpdate!(details.primaryDelta ?? 0),
        onVerticalDragEnd: onHandleDragEnd == null
            ? null
            : (_) => onHandleDragEnd!(),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Brand orbs, gently breathing — the same "voice" as the
                // assistant avatar and thinking indicator.
                const ThinkingOrbs(size: 56, period: Duration(seconds: 5)),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  tr('chat.emptyTitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: shell.primaryText.withValues(alpha: 0.9),
                    height: 1.4,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('chat.emptySubtitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: shell.mutedText,
                    height: 1.5,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final trailing = (busy ? 1 : 0) + (hasFooter ? 1 : 0);
    return ListView.builder(
      controller: scrollController,
      // Bottom padding clears the floating input pill docked over the sheet —
      // without it the last message hides behind the composer.
      padding: EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, listBottomInset + 12),
      itemCount: messages.length + trailing,
      itemBuilder: (context, i) {
        if (i >= messages.length) {
          if (busy && i == messages.length) return const _ThinkingRow();
          return listFooter!;
        }
        final m = messages[i];
        // Stable per-message key so the entrance animation fires once and never
        // re-triggers as the ListView recycles rows during scroll.
        final entranceKey = m.id ?? '${i}_${m.role}_${m.content.hashCode}';
        Widget child;
        if (m.kind == 'journal_progress') {
          final entryId = m.meta?['entry_id']?.toString();
          if (entryId != null && entryId.isNotEmpty) {
            return JournalProgressCard(entryId: entryId);
          }
          child = const SizedBox.shrink();
        } else if (m.kind == 'journal_mode') {
          child = _JournalModeBanner(text: m.content);
        } else if (m.kind == 'journal_submit' && m.role == 'user') {
          child = _JournalSubmitBubble(text: m.content);
        } else if (m.role == 'user') {
          child = _UserBubble(text: m.content);
        } else {
          // Consecutive assistant turns read as one voice — only the first of
          // a run carries the avatar, the rest indent to align under it.
          final prev = i > 0 ? messages[i - 1] : null;
          child = _AssistantBubble(
            showAvatar: !(prev != null &&
                prev.role == 'assistant' &&
                prev.kind == 'text'),
            text: m.content,
            referencedNodes: [
              for (final id in m.referencedNodeIds)
                if (nodeById[id] != null) nodeById[id]!,
            ],
            typeColors: typeColors,
            onNodeTap: (node) {
              final ids =
                  m.referencedNodeIds.where(nodeById.containsKey).toSet();
              if (ids.isNotEmpty) onNodeHighlight(ids);
            },
            onNodeOpen: onNodeSelect,
          );
        }
        return _MessageEntrance(
          key: ValueKey(entranceKey),
          entranceKey: entranceKey,
          child: child,
        );
      },
    );
  }
}

class GraphChatMessage {
  GraphChatMessage({
    required this.role,
    required this.content,
    this.id,
    this.kind = 'text',
    this.referencedNodeIds = const [],
    this.meta,
  });

  /// Server message id (null for optimistic local echoes not yet persisted).
  final String? id;
  final String role;

  /// text | quiz_prompt | quiz_result | distill_draft — drives which bubble/card
  /// renders in the feed. Non-text kinds carry their payload in [meta].
  final String kind;
  final String content;
  final List<String> referencedNodeIds;
  final Map<String, dynamic>? meta;

  factory GraphChatMessage.fromJson(Map<String, dynamic> m) => GraphChatMessage(
        id: m['id']?.toString(),
        role: m['role']?.toString() ?? 'assistant',
        kind: m['kind']?.toString() ?? 'text',
        content: m['content']?.toString() ?? '',
        referencedNodeIds: ((m['referenced_node_ids'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
        meta: m['meta'] == null
            ? null
            : Map<String, dynamic>.from(m['meta'] as Map),
      );
}

// ── Header & drag handle ───────────────────────────────────────────────────────

/// Visual affordance signaling the sheet is draggable — map-app convention.
/// Not functionally required for the drag itself (DraggableScrollableSheet
/// already recognizes a drag gesture anywhere over its content), but without
/// it there's no visual cue the sheet can be resized.
class _SheetDragHandle extends StatelessWidget {
  const _SheetDragHandle({this.onDragUpdate, this.onDragEnd});

  final ValueChanged<double>? onDragUpdate;
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: onDragUpdate == null
          ? null
          : (details) => onDragUpdate!(details.primaryDelta ?? 0),
      onVerticalDragEnd: onDragEnd == null ? null : (_) => onDragEnd!(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          height: 28,
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.shell.panelBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Persistent input bar (lives OUTSIDE the draggable sheet) ───────────────────

/// Always-docked composer, rendered outside [GraphChatPanel]/the draggable
/// sheet so it stays visible and tappable at every sheet extent — including
/// the minimized state, where the sheet's own content is nearly fully hidden.
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.inputController,
    required this.busy,
    required this.onSend,
    this.modeLabel,
    this.onExitMode,
    this.onModeSelected,
    this.inputEnabled = true,
    this.inputHint = 'Say anything…', // always overridden by callers via tr()
    this.journalMode = false,
    this.inputFocusNode,
    this.suggestions = const [],
    this.onSuggestionPrompt,
  });

  final TextEditingController inputController;
  final bool busy;
  final ValueChanged<String> onSend;

  /// Tappable options rendered in the keypad area above the pill. Prompt chips
  /// route to [onSuggestionPrompt] (falling back to [onSend]); action chips
  /// reuse [onModeSelected], the same path as the "+" menu.
  final List<ChatSuggestion> suggestions;
  final ValueChanged<String>? onSuggestionPrompt;

  /// When non-null, a mode chip is shown with an X that calls [onExitMode].
  final String? modeLabel;
  final VoidCallback? onExitMode;

  /// "+" menu action: 'journal' | 'composition' | 'word' | 'distill'.
  final ValueChanged<String>? onModeSelected;

  final bool inputEnabled;
  final String inputHint;

  /// Journal mode reuses this same docked pill instead of a separate composer
  /// card — the field grows an @-mention popup for speaker tagging, and a
  /// mic/attach pair appears next to send. Only the surface swaps; there is
  /// never a second input competing with this one.
  final bool journalMode;

  /// Owned by the screen so it can re-request focus after a tap elsewhere
  /// in the tree (e.g. a quiz card's "다음 문제" button) steals it away.
  final FocusNode? inputFocusNode;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (modeLabel != null)
              _ModeChip(label: modeLabel!, onExit: onExitMode),
            // Keypad area — the likely next turns, one tap away. Rendered
            // above the pill and inside the same measured block so the feed's
            // bottom inset already accounts for it. Not relevant while writing
            // a diary entry, so it steps aside in journal mode.
            if (!journalMode && onModeSelected != null)
              ChatSuggestionRail(
                suggestions: suggestions,
                onPrompt: onSuggestionPrompt ?? onSend,
                onAction: onModeSelected!,
              ),
            // Gemini-style detached floating pill: opaque, rounded-full, soft
            // shadow — reads as its own surface instead of a bar glued to the
            // sheet (whose content used to show through behind it).
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: shell.barBackground,
              borderRadius: BorderRadius.circular(24),
                border: Border.all(color: shell.panelBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.14),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: _InputBar(
                  controller: inputController,
                  busy: busy,
                  enabled: inputEnabled,
                  hint: inputHint,
                  journalMode: journalMode,
                  onSend: onSend,
                  onModeSelected: onModeSelected,
                  focusNode: inputFocusNode,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Input & bubbles ───────────────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.controller,
    required this.busy,
    required this.enabled,
    required this.hint,
    required this.onSend,
    required this.onModeSelected,
    this.journalMode = false,
    this.focusNode,
  });

  final TextEditingController controller;
  final bool busy;
  final bool enabled;
  final String hint;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onModeSelected;

  /// Swaps the plain [TextField] for a [MentionAutocompleteField] (@-mention
  /// speaker tagging) and adds mic/attach actions; send saves the journal
  /// entry instead of calling [onSend].
  final bool journalMode;

  /// Owned by the screen (not this widget) so it can be re-requested after
  /// an action elsewhere in the tree — e.g. tapping a quiz card's "다음
  /// 문제" button — steals focus away from the composer.
  final FocusNode? focusNode;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  FocusNode? _ownedFocusNode;
  FocusNode get _focusNode => widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  final _mentionFieldKey = GlobalKey<MentionAutocompleteFieldState>();
  AudioRecordController? _recorder;
  bool _journalSaving = false;

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    _recorder?.dispose();
    super.dispose();
  }

  bool get _canType => widget.enabled && !widget.busy && !_journalSaving;

  void _showKeyboardFromTap() {
    // Keep this inside the actual TextField tap. On iOS Safari, focus gained
    // after an async quiz transition can draw a caret but cannot raise the
    // software keyboard; a user-gesture-bound request restores that channel.
    _focusNode.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  void _insertNewline() {
    final value = widget.controller.value;
    final text = value.text;
    var start = value.selection.start;
    var end = value.selection.end;
    if (start < 0 || end < 0) {
      start = text.length;
      end = text.length;
    }
    final updated = text.replaceRange(start, end, '\n');
    widget.controller.value = value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_canType || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      _insertNewline();
      return KeyEventResult.handled;
    }
    widget.onSend(widget.controller.text);
    return KeyEventResult.handled;
  }

  // ── Journal mode: save / mic / attach (folded in from the old standalone
  // ChatJournalComposeBar card so writing a diary entry no longer needs a
  // second input surface — this pill, with its hint + mode chip banner above
  // it, is the whole story). ─────────────────────────────────────────────

  AudioRecordController get _recorderController {
    final existing = _recorder;
    if (existing != null) return existing;
    final created = AudioRecordController();
    created.attachStateListener();
    created.onMaxDurationReached = () {
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('chat.recordingLimitSnackbar')),
          duration: const Duration(seconds: 5),
        ),
      );
      _uploadRecording();
    };
    created.onBrowserInterrupted = (msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
        );
        setState(() {});
      }
    };
    created.addListener(() {
      if (mounted) setState(() {});
    });
    _recorder = created;
    return created;
  }

  Future<void> _saveJournal() async {
    if (_journalSaving) return;
    final field = _mentionFieldKey.currentState;
    if (field == null) return;
    final text = field.text.trim();
    if (text.isEmpty) return;
    if (text.length > kMaxJournalTextChars) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('chat.textTooLongTitle')),
          content: Text(
            tr('chat.textTooLongBody', {
              'current': text.length,
              'max': kMaxJournalTextChars,
            }),
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('common.confirm'))),
          ],
        ),
      );
      return;
    }
    final labeled = labeledTextFromMentionField(field);
    setState(() => _journalSaving = true);
    try {
      await chatSession.saveJournalText(labeled, displayText: text);
    } finally {
      if (mounted) setState(() => _journalSaving = false);
    }
  }

  Future<void> _toggleMic() async {
    final recorder = _recorderController;
    if (recorder.recording) {
      final result = await recorder.stop();
      if (!mounted) return;
      setState(() {});
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('chat.noRecordingSnackbar'))),
        );
        return;
      }
      await _saveAudioResult(result);
      return;
    }
    try {
      final ok = await recorder.start();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('chat.micPermissionSnackbar')),
          ),
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('chat.recordingStartFailed', {'error': e}))),
        );
      }
    }
  }

  Future<void> _uploadRecording() async {
    final result = await _recorderController.stop();
    if (result == null || !mounted) return;
    await _saveAudioResult(result);
  }

  Future<void> _saveAudioResult(AudioRecordResult result) async {
    setState(() => _journalSaving = true);
    try {
      await chatSession.saveJournalAudio(
        path: result.path,
        bytes: result.bytes,
        filename: result.filename,
        mimeType: result.mimeType,
      );
    } finally {
      if (mounted) setState(() => _journalSaving = false);
    }
  }

  Future<void> _pickFile() async {
    if (_recorderController.recording) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('chat.stopRecordingFirstSnackbar'))),
      );
      return;
    }
    try {
      final picked = await pickAudioFile();
      if (picked == null || !mounted) return;
      setState(() => _journalSaving = true);
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception(tr('chat.fileReadError'));
        }
        await chatSession.saveJournalAudio(
          bytes: bytes,
          filename: picked.name,
          mimeType: audioMimeTypeForFilename(picked.name),
        );
      } else {
        final path = picked.path;
        if (path == null) throw Exception(tr('chat.filePathError'));
        await chatSession.saveJournalAudio(
          path: path,
          filename: picked.name,
          mimeType: audioMimeTypeForFilename(picked.name),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('chat.fileSelectFailed', {'error': e}))),
        );
      }
    } finally {
      if (mounted) setState(() => _journalSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canType = _canType;
    final shell = context.shell;
    final journalMode = widget.journalMode;
    final recording = _recorder?.recording ?? false;
    // Chrome (pill surface, shadow, SafeArea) is owned by [ChatInputBar] —
    // this is just the naked row so the pill stays one clean surface.
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 1, 5, 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (widget.onModeSelected != null)
            _ModeMenuButton(onSelected: widget.onModeSelected!),
          if (journalMode) ...[
            _CompactIconButton(
              tooltip:
                  recording ? tr('chat.micTooltipStop') : tr('chat.micTooltipStart'),
              icon: recording ? Icons.stop_rounded : Icons.mic_none_rounded,
              active: recording,
              onTap: _journalSaving ? null : _toggleMic,
            ),
            _CompactIconButton(
              tooltip: tr('chat.attachAudioTooltip'),
              icon: Icons.attach_file_rounded,
              onTap: _journalSaving || recording ? null : _pickFile,
            ),
          ],
          Expanded(
            child: journalMode
                ? MentionAutocompleteField(
                    key: _mentionFieldKey,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 8,
                    showCounter: false,
                    // Docked at the bottom of the screen — open upward so the
                    // popup never renders off-screen below the viewport.
                    openUpward: true,
                    enabled: canType && !recording,
                    decoration: InputDecoration(
                      hintText: widget.hint,
                      hintStyle:
                          TextStyle(color: shell.mutedText, fontSize: 13.5),
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm, vertical: 8),
                    ),
                  )
                : Focus(
                    onKeyEvent: _onKey,
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focusNode,
                      enabled: canType,
                      onTap: _showKeyboardFromTap,
                      minLines: 1,
                      // Auto-grows with content up to ~6 lines, then scrolls —
                      // the standard composer behavior; capped so it never
                      // eats the feed.
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      style: TextStyle(color: shell.primaryText, fontSize: 14),
                      textInputAction: TextInputAction.send,
                      onSubmitted: canType ? widget.onSend : null,
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        hintStyle:
                            TextStyle(color: shell.mutedText, fontSize: 13.5),
                        isDense: true,
                        filled: false,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm, vertical: 2),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: AppSpacing.xs),
          _SendButton(
            enabled: journalMode ? (canType && !recording) : canType,
            busy: journalMode && _journalSaving,
            onSend: () {
              HapticFeedback.lightImpact();
              if (journalMode) {
                _saveJournal();
              } else {
                widget.onSend(widget.controller.text);
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Circular send button with a subtle press-scale + a color/fill transition
/// between its disabled and active states.
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.enabled,
    required this.onSend,
    this.busy = false,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onSend;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final enabled = widget.enabled && !widget.busy;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTap: enabled ? widget.onSend : null,
      child: AnimatedScale(
        scale: _pressed ? 0.86 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: enabled ? AppColors.hubGraph : shell.subtleSurface,
            shape: BoxShape.circle,
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppColors.hubGraph.withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: widget.busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: shell.mutedText),
                )
              : Icon(
                  Icons.send_rounded,
                  size: 18,
                  color: enabled ? Colors.white : shell.mutedText,
                ),
        ),
      ),
    );
  }
}

/// "+" mode menu — anchored to the button via a composited-layer follower
/// (the same [LayerLink]/[OverlayPortal] mechanism [MentionAutocompleteField]
/// already uses for its own @-mention popup) instead of [PopupMenuButton]'s
/// built-in [showMenu] route. showMenu's RelativeRect is computed against the
/// Navigator's overlay bounds, which drifted from this bar's actual on-screen
/// position inside its nested Positioned/SafeArea/AnimatedPositioned stack —
/// the menu rendered detached from the button instead of docked above it. A
/// follower layer tracks the button's real RenderBox directly, so it can't drift.
class _ModeMenuButton extends StatefulWidget {
  const _ModeMenuButton({required this.onSelected});
  final ValueChanged<String> onSelected;

  @override
  State<_ModeMenuButton> createState() => _ModeMenuButtonState();
}

class _ModeMenuButtonState extends State<_ModeMenuButton> {
  final _link = LayerLink();
  final _popupController = OverlayPortalController();

  void _toggle() {
    if (_popupController.isShowing) {
      _popupController.hide();
    } else {
      _popupController.show();
    }
  }

  void _select(String value) {
    _popupController.hide();
    widget.onSelected(value);
  }

  Widget _item(String value, IconData icon, String label) {
    return InkWell(
      onTap: () => _select(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: _ModeMenuRow(icon: icon, label: label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _popupController,
        overlayChildBuilder: (context) {
          // A full-screen dimmed barrier BEHIND the menu — same role as the
          // ModalRoute PopupMenuButton's showMenu() used to draw for us. Without
          // it the menu just sat on top of the live chat feed with nothing
          // separating "menu" from "page behind it", which read as broken/stray
          // rather than as a floating menu. Tapping it (or anywhere outside the
          // menu) dismisses, same as before.
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _popupController.hide,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.32),
                  ),
                ),
              ),
              // Follower's bottom-left docks to the button's top-left, nudged
              // up a hair — the menu grows upward, pinned to the button itself.
              CompositedTransformFollower(
                link: _link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.bottomLeft,
                offset: const Offset(0, -8),
                child: Material(
                  color: shell.barBackground,
                  elevation: 10,
                  shadowColor: Colors.black.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: 210,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _item('journal', Icons.auto_stories_rounded,
                              tr('chat.menu.journal')),
                          _item('distill', Icons.playlist_add_check_rounded,
                              tr('chat.menu.distill')),
                          _item('composition', Icons.edit_note_rounded,
                              tr('chat.menu.composition')),
                          _item('word', Icons.style_rounded,
                              tr('chat.menu.word')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: IconButton(
          tooltip: tr('chat.modeTooltip'),
          onPressed: _toggle,
          icon: Icon(Icons.add_circle_outline_rounded,
              color: shell.primaryText.withValues(alpha: 0.75)),
        ),
      ),
    );
  }
}

class _ModeMenuRow extends StatelessWidget {
  const _ModeMenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = context.shell.primaryText;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }
}

/// Small tappable icon (mic / attach) shown beside the composer in journal
/// mode — the compact-bar equivalent of the old compose card's action row.
class _CompactIconButton extends StatelessWidget {
  const _CompactIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final color = onTap == null
        ? shell.mutedText
        : (active ? Colors.redAccent : shell.primaryText.withValues(alpha: 0.72));
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 19, color: color),
        ),
      ),
    );
  }
}

/// Chip above the input showing the active non-chat mode, with an X to exit.
class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.onExit});
  final String label;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final onChip = context.shell.primaryText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: context.shell.barBackground,
          elevation: 3,
          shadowColor: Colors.black.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        color: onChip,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                if (onExit != null)
                  InkWell(
                    onTap: onExit,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: onChip),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    // Keep the subtle translucent bubble in dark mode; go solid indigo in light
    // mode so the white text stays readable over the near-white panel.
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: 24),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              // Keep long user messages readable on narrow phones instead of
              // letting the bubble consume the entire chat width.
              maxWidth: constraints.maxWidth.clamp(240.0, 520.0) * 0.84,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: 7),
              decoration: BoxDecoration(
                color: dark
                    ? AppColors.hubGraph.withValues(alpha: 0.28)
                    : AppColors.hubGraph,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppSpacing.radiusMd),
                  topRight: Radius.circular(AppSpacing.radiusMd),
                  bottomLeft: Radius.circular(AppSpacing.radiusMd),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: ChatRichText(
                text: text,
                style: const TextStyle(
                  color: AppColors.graphLabelLight,
                  height: 1.4,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.text,
    required this.referencedNodes,
    required this.typeColors,
    required this.onNodeTap,
    required this.onNodeOpen,
    this.showAvatar = true,
  });

  final String text;
  final List<Map<String, dynamic>> referencedNodes;
  final Map<String, Color> typeColors;
  final void Function(Map<String, dynamic> node) onNodeTap;
  final void Function(Map<String, dynamic> node) onNodeOpen;

  /// False for the 2nd+ message of a consecutive assistant run — the gutter
  /// stays reserved so the bubbles still line up under the first avatar.
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: showAvatar
                ? Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppColors.hubGraph, AppColors.hubQuiz],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.auto_awesome_rounded,
                        size: 12, color: Colors.white),
                  )
                : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A real surface for the answer — the assistant's turn used to
                // be bare text floating on the panel, which read as chrome
                // rather than as one side of a conversation.
                Container(
                  padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
                  decoration: BoxDecoration(
                    color: shell.subtleSurface,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(AppSpacing.radiusMd),
                      bottomLeft: Radius.circular(AppSpacing.radiusMd),
                      bottomRight: Radius.circular(AppSpacing.radiusMd),
                    ),
                    border: Border.all(
                      color: shell.panelBorder
                          .withValues(alpha: isDark ? 0.55 : 0.75),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ChatRichText(text: text),
                      if (referencedNodes.isNotEmpty) ...[
                        const SizedBox(height: 9),
                        _SourceCardRail(
                          nodes: referencedNodes,
                          typeColors: typeColors,
                          onNodeTap: onNodeTap,
                          onNodeOpen: onNodeOpen,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    // AI Basic Act (2026) generated-content marking.
                    Text(
                      tr('chat.aiGeneratedLabel'),
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.2,
                        letterSpacing: 0.3,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _CopyMessageButton(text: text),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The nodes an answer was grounded in, as a scrollable card rail.
///
/// These used to be 10px name-only chips — technically the same information,
/// but too small to convey what the answer actually stood on. Cards give each
/// source its type color, its kind, and room for the statement behind it, so
/// the grounding is legible at a glance instead of decorative.
class _SourceCardRail extends StatelessWidget {
  const _SourceCardRail({
    required this.nodes,
    required this.typeColors,
    required this.onNodeTap,
    required this.onNodeOpen,
  });

  final List<Map<String, dynamic>> nodes;
  final Map<String, Color> typeColors;
  final void Function(Map<String, dynamic> node) onNodeTap;
  final void Function(Map<String, dynamic> node) onNodeOpen;

  @override
  Widget build(BuildContext context) {
    final muted = context.shell.mutedText;
    final shown = nodes.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.hub_outlined, size: 11, color: muted),
            const SizedBox(width: 4),
            Text(
              '${tr('chat.sources.title')} ${shown.length}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                color: muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: shown.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) => _SourceCard(
              node: shown[i],
              color:
                  colorForType(shown[i]['type']?.toString() ?? '', typeColors),
              onTap: () => onNodeTap(shown[i]),
              onOpen: () => onNodeOpen(shown[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.node,
    required this.color,
    required this.onTap,
    required this.onOpen,
  });

  final Map<String, dynamic> node;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback onOpen;

  static Map<String, String> get _typeLabels => {
        'Statement': tr('chat.typeStatement'),
        'Concept': tr('chat.typeConcept'),
        'Identity': tr('chat.typeIdentity'),
        'Person': tr('chat.typePerson'),
        'Source': tr('chat.typeSource'),
      };

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final name = node['name']?.toString() ?? '';
    final type = node['type']?.toString() ?? '';
    final label = _typeLabels[type] ?? type;
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 96, maxWidth: 190),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Type stripe — same color language as the canvas, so a card
              // and its node on the graph are recognizably the same thing.
              Container(width: 3, height: 52, color: color),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 7, 9, 7),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (label.isNotEmpty)
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            color: color,
                          ),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: shell.primaryText.withValues(alpha: 0.92),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Subtle "copy" affordance under an assistant message. Flips to a check for a
/// moment on tap — the standard commercial-chat confirmation.
class _CopyMessageButton extends StatefulWidget {
  const _CopyMessageButton({required this.text});
  final String text;

  @override
  State<_CopyMessageButton> createState() => _CopyMessageButtonState();
}

class _CopyMessageButtonState extends State<_CopyMessageButton> {
  bool _copied = false;

  Future<void> _copy() async {
    HapticFeedback.selectionClick();
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.shell.mutedText;
    return InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 12,
              color: _copied ? AppColors.accent : muted.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 3),
            Text(
              _copied ? tr('chat.copiedLabel') : tr('chat.copyLabel'),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: _copied ? AppColors.accent : muted.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow();

  @override
  Widget build(BuildContext context) {
    return const ThinkingIndicator();
  }
}

/// One-shot fade + rise for a freshly appended message. Keyed by a stable
/// message id and gated by [_seen] so scrolling never replays the animation on
/// recycled rows — only genuinely new messages animate in.
class _MessageEntrance extends StatefulWidget {
  const _MessageEntrance({
    super.key,
    required this.entranceKey,
    required this.child,
  });

  final String entranceKey;
  final Widget child;

  static final Set<String> _seen = <String>{};

  @override
  State<_MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<_MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final bool _animate;

  @override
  void initState() {
    super.initState();
    _animate = !_MessageEntrance._seen.contains(widget.entranceKey);
    _MessageEntrance._seen.add(widget.entranceKey);
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: _animate ? 0 : 1,
    );
    if (_animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animate) return widget.child;
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (1 - curve.value) * 8),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Floating "jump to latest" pill — appears only when the feed is scrolled up
/// away from the bottom, fades/scales in, and animates back down on tap.
class _ScrollToBottomButton extends StatefulWidget {
  const _ScrollToBottomButton({required this.controller});

  final ScrollController controller;

  @override
  State<_ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<_ScrollToBottomButton> {
  static const _threshold = 260.0;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final pos = widget.controller.position;
    // Normal (non-reversed) list: bottom == maxScrollExtent.
    final show = pos.maxScrollExtent - pos.pixels > _threshold;
    if (show != _visible) setState(() => _visible = show);
  }

  void _jump() {
    if (!widget.controller.hasClients) return;
    HapticFeedback.selectionClick();
    widget.controller.animateTo(
      widget.controller.position.maxScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedScale(
        scale: _visible ? 1 : 0.6,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: Container(
            decoration: BoxDecoration(
              color: shell.barBackground,
              shape: BoxShape.circle,
              border: Border.all(color: shell.panelBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.14),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _jump,
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: shell.primaryText.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _JournalModeBanner extends StatelessWidget {
  const _JournalModeBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cleanText = text.replaceAll(
        RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true), '').trim();
    final lines = cleanText.split('\n');
    final title = lines.isEmpty ? '' : lines.first.trim();
    final body = lines.skip(1).join('\n').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.48),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: scheme.secondary.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_stories_rounded,
                    size: 18, color: scheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: context.shell.primaryText,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 7),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  body,
                style: TextStyle(
                  color: context.shell.primaryText,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _JournalSubmitBubble extends StatelessWidget {
  const _JournalSubmitBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 11),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.72),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppSpacing.radiusMd),
              topRight: Radius.circular(AppSpacing.radiusMd),
              bottomLeft: Radius.circular(AppSpacing.radiusMd),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.22),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_note_rounded,
                      size: 14,
                      color: scheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    tr('chat.journalSavedLabel'),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                text,
                style: TextStyle(
                  color: context.shell.primaryText,
                  height: 1.45,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

