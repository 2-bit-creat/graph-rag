import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';
import 'chat_rich_text.dart';
import 'journal_progress_card.dart';

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
    this.statusPill,
    this.onHandleDragUpdate,
    this.onHandleDragEnd,
    this.onPanelTap,
    this.quizMode = false,
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

  /// Floating status pill overlaid at the top of the chat feed while a journal
  /// pipeline runs (Feature C — non-invasive background processing). Chat stays
  /// usable; the pill reports progress and, when tapped, opens review.
  final Widget? statusPill;
  final ValueChanged<double>? onHandleDragUpdate;
  final VoidCallback? onHandleDragEnd;
  final VoidCallback? onPanelTap;
  final bool quizMode;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final safeTop = MediaQuery.paddingOf(context).top;
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
                  ? SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          AppSpacing.sm + safeTop,
                          AppSpacing.md,
                          108),
                      child: listFooter,
                    )
                  : Stack(
                      children: [
                        Positioned.fill(child: _buildMessageList(context)),
                        if (statusPill != null)
                          Positioned(
                            top: 8,
                            left: 0,
                            right: 0,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: statusPill,
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
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forum_rounded,
                    size: 32,
                    color: shell.mutedText.withValues(alpha: 0.6)),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  tr('chat.emptyTitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: shell.mutedText,
                    height: 1.45,
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
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, 96),
      itemCount: messages.length + trailing,
      itemBuilder: (context, i) {
        if (i >= messages.length) {
          if (busy && i == messages.length) return const _ThinkingRow();
          return listFooter!;
        }
        final m = messages[i];
        if (m.kind == 'journal_progress') {
          final entryId = m.meta?['entry_id']?.toString();
          if (entryId != null && entryId.isNotEmpty) {
            return JournalProgressCard(entryId: entryId);
          }
        }
        if (m.kind == 'journal_mode') {
          return _JournalModeBanner(text: m.content);
        }
        if (m.kind == 'journal_submit' && m.role == 'user') {
          return _JournalSubmitBubble(text: m.content);
        }
        return m.role == 'user'
            ? _UserBubble(text: m.content)
            : _AssistantBubble(
                text: m.content,
                referencedNodes: [
                  for (final id in m.referencedNodeIds)
                    if (nodeById[id] != null) nodeById[id]!,
                ],
                typeColors: typeColors,
                onNodeTap: (node) {
                  final ids = m.referencedNodeIds
                      .where(nodeById.containsKey)
                      .toSet();
                  if (ids.isNotEmpty) onNodeHighlight(ids);
                },
                onNodeOpen: onNodeSelect,
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

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    this.title,
    required this.hasMessages,
    required this.onClear,
  });

  final String? title;
  final bool hasMessages;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final resolvedTitle =
        (title?.trim().isNotEmpty ?? false) ? title!.trim() : '그래프 대화';
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.sm, 6),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.hubGraph, AppColors.hubQuiz],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome_rounded,
                size: 14, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              resolvedTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: shell.primaryText,
                  fontWeight: FontWeight.w700,
                  fontSize: 15),
            ),
          ),
          IconButton(
            tooltip: '대화 기록 삭제',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: shell.primaryText.withValues(alpha: 0.55),
            onPressed: hasMessages ? onClear : null,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
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
    this.inputHint = '아무 얘기나 해보세요…',
    this.inputBarOverride,
    this.inputFocusNode,
  });

  final TextEditingController inputController;
  final bool busy;
  final ValueChanged<String> onSend;

  /// When non-null, a mode chip is shown with an X that calls [onExitMode].
  final String? modeLabel;
  final VoidCallback? onExitMode;

  /// "+" menu action: 'journal' | 'composition' | 'word' | 'distill'.
  final ValueChanged<String>? onModeSelected;

  final bool inputEnabled;
  final String inputHint;

  /// When non-null, replaces the default [_InputBar] (e.g. journal compose).
  final Widget? inputBarOverride;

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
                child: inputBarOverride ??
                    _InputBar(
                      controller: inputController,
                      busy: busy,
                      enabled: inputEnabled,
                      hint: inputHint,
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
    this.focusNode,
  });

  final TextEditingController controller;
  final bool busy;
  final bool enabled;
  final String hint;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onModeSelected;

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

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  bool get _canType => widget.enabled && !widget.busy;

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

  @override
  Widget build(BuildContext context) {
    final canType = _canType;
    final shell = context.shell;
    // Chrome (pill surface, shadow, SafeArea) is owned by [ChatInputBar] —
    // this is just the naked row so the pill stays one clean surface.
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 1, 5, 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (widget.onModeSelected != null)
            PopupMenuButton<String>(
              tooltip: '모드',
              icon: Icon(Icons.add_circle_outline_rounded,
                  color: shell.primaryText.withValues(alpha: 0.75)),
              color: shell.barBackground,
              elevation: 10,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              menuPadding: const EdgeInsets.symmetric(vertical: 6),
              offset: const Offset(0, -8),
              onSelected: widget.onModeSelected,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'journal',
                  child: _ModeMenuRow(
                      icon: Icons.auto_stories_rounded,
                      label: tr('chat.menu.journal')),
                ),
                PopupMenuItem(
                  value: 'distill',
                  child: _ModeMenuRow(
                      icon: Icons.playlist_add_check_rounded,
                      label: tr('chat.menu.distill')),
                ),
                PopupMenuItem(
                  value: 'composition',
                  child: _ModeMenuRow(
                      icon: Icons.edit_note_rounded,
                      label: tr('chat.menu.composition')),
                ),
                PopupMenuItem(
                  value: 'word',
                  child: _ModeMenuRow(
                      icon: Icons.style_rounded,
                      label: tr('chat.menu.word')),
                ),
              ],
            ),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                enabled: canType,
                minLines: 1,
                maxLines: 2,
                style: TextStyle(color: shell.primaryText, fontSize: 14),
                textInputAction: TextInputAction.send,
                onSubmitted: canType ? widget.onSend : null,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: TextStyle(color: shell.mutedText, fontSize: 13.5),
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
          Material(
            color: canType ? AppColors.hubGraph : shell.subtleSurface,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap:
                  canType ? () => widget.onSend(widget.controller.text) : null,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.send_rounded,
                    size: 18, color: canType ? Colors.white : shell.mutedText),
              ),
            ),
          ),
        ],
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
  });

  final String text;
  final List<Map<String, dynamic>> referencedNodes;
  final Map<String, Color> typeColors;
  final void Function(Map<String, dynamic> node) onNodeTap;
  final void Function(Map<String, dynamic> node) onNodeOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
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
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChatRichText(text: text),
                const SizedBox(height: 2),
                // AI Basic Act (2026) generated-content marking.
                Text(
                  'AI 생성',
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
                if (referencedNodes.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final node in referencedNodes.take(5))
                        _NodeChip(
                          node: node,
                          color: colorForType(
                              node['type']?.toString() ?? '', typeColors),
                          onTap: () => onNodeTap(node),
                          onLongPress: () => onNodeOpen(node),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeChip extends StatelessWidget {
  const _NodeChip({
    required this.node,
    required this.color,
    required this.onTap,
    required this.onLongPress,
  });

  final Map<String, dynamic> node;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final name = node['name']?.toString() ?? '';
    return Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text('기억을 뒤적이는 중…',
              style: TextStyle(
                  color: context.shell.mutedText,
                  fontSize: 11.5)),
        ],
      ),
    );
  }
}

class _JournalModeBanner extends StatelessWidget {
  const _JournalModeBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.hubVoice.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.hubVoice.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.auto_stories_rounded,
                size: 16, color: AppColors.hubVoice),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: context.shell.primaryText,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.hubVoice.withValues(alpha: 0.22),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppSpacing.radiusMd),
              topRight: Radius.circular(AppSpacing.radiusMd),
              bottomLeft: Radius.circular(AppSpacing.radiusMd),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(
              color: AppColors.hubVoice.withValues(alpha: 0.35),
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
                      color: AppColors.hubVoice.withValues(alpha: 0.95)),
                  const SizedBox(width: 4),
                  Text(
                    '일기 저장',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.hubVoice.withValues(alpha: 0.95),
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

