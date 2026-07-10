import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';
import 'chat_rich_text.dart';
import 'journal_progress_card.dart';

/// ě§?ęˇ¸?í ?ëŠ´ ?¤ëĽ¸ěŞ˝ě ëśë ????¨ë.
///
/// ęˇ¸ë???ě ???ë ?Źě´???¨ë ?í ???ěźëŠ?ęˇ¸ë?ë§ ?ě˛´ ?ëšëĄ?ëł´ě¸??
class GraphChatPanel extends StatelessWidget {
  const GraphChatPanel({
    super.key,
    required this.messages,
    required this.busy,
    required this.typeColors,
    required this.nodeById,
    required this.inputController,
    required this.scrollController,
    required this.onSend,
    required this.onNodeHighlight,
    required this.onNodeSelect,
    required this.onClearHistory,
    required     this.onCollapse,
    this.activeCard,
    this.listFooter,
    this.modeLabel,
    this.onExitMode,
    this.onModeSelected,
    this.inputEnabled = true,
    this.inputHint = '?ëŹ´ ?ę¸°???´ëł´?¸ě??,
    this.inputBarOverride,
    this.pipelineLocked = false,
    this.pipelineLockLabel,
    this.pipelineReviewLabel,
  });

  final List<GraphChatMessage> messages;
  final bool busy;
  final Map<String, Color> typeColors;
  final Map<String, Map<String, dynamic>> nodeById;
  final TextEditingController inputController;
  final ScrollController scrollController;
  final ValueChanged<String> onSend;
  final void Function(Set<String> nodeIds) onNodeHighlight;
  final void Function(Map<String, dynamic> node) onNodeSelect;
  final VoidCallback onClearHistory;
  final VoidCallback onCollapse;

  /// Quiz cards etc. pinned above the input bar.
  final Widget? activeCard;

  /// Optional block appended after messages inside the chat scroll (e.g. distill draft).
  final Widget? listFooter;

  /// When non-null, a mode chip is shown with an X that calls [onExitMode].
  final String? modeLabel;
  final VoidCallback? onExitMode;

  /// "+" menu action: 'journal' | 'composition' | 'word' | 'distill'.
  final ValueChanged<String>? onModeSelected;

  final bool inputEnabled;
  final String inputHint;

  /// When non-null, replaces the default [_InputBar] (e.g. journal compose).
  final Widget? inputBarOverride;

  /// ?źę¸° ?ě´?ëź??ě˛ëŚŹÂˇ?ě¸ ě¤????źë° ????ë Ľ ? ę¸.
  final bool pipelineLocked;
  final String? pipelineLockLabel;

  /// User-review step (speaker confirm / graph review) ??no spinner.
  final String? pipelineReviewLabel;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Material(
      color: shell.panelBackground,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: shell.panelBorder)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelHeader(
              hasMessages: messages.isNotEmpty,
              onCollapse: onCollapse,
              onClear: onClearHistory,
            ),
            Expanded(child: _buildMessageList(context)),
            if (activeCard != null) activeCard!,
            if (modeLabel != null)
              _ModeChip(
                label: modeLabel!,
                onExit: pipelineLocked ? null : onExitMode,
              ),
            if (pipelineLocked && inputBarOverride == null)
              _PipelineLockBar(label: pipelineLockLabel ?? '?źę¸° ě˛ëŚŹ ě¤?),
            if (!pipelineLocked &&
                pipelineReviewLabel != null &&
                inputBarOverride == null)
              _PipelineReviewBar(label: pipelineReviewLabel!),
            inputBarOverride ??
                _InputBar(
                  controller: inputController,
                  busy: busy,
                  enabled: inputEnabled && !pipelineLocked,
                  hint: pipelineLocked ? '?źę¸° ě˛ëŚŹę° ?ë  ?ęšě§ ?ę¸°â? : inputHint,
                  onSend: onSend,
                  onModeSelected:
                      pipelineLocked ? null : onModeSelected,
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(BuildContext context) {
    final shell = context.shell;
    final hasFooter = listFooter != null;
    if (messages.isEmpty && !busy && !hasFooter) {
      return Center(
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
                'ęˇ¸ë?ë? ëł´ëŠ´??ë°ëĄ ëŹźě´ëł´ě¸??\nAIę° ???źę¸°ëĽ?ę¸°ěľ?ęł  ?ľí´??',
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
      );
    }

    final trailing = (busy ? 1 : 0) + (hasFooter ? 1 : 0);
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
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

  /// text | quiz_prompt | quiz_result | distill_draft ??drives which bubble/card
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

// ?? Header & collapsed tab ????????????????????????????????????????????????????

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.hasMessages,
    required this.onCollapse,
    required this.onClear,
  });

  final bool hasMessages;
  final VoidCallback onCollapse;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 8, 4, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: shell.panelBorder)),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.hubGraph, AppColors.hubQuiz],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome_rounded,
                size: 13, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ęˇ¸ë?????,
                    style: TextStyle(
                        color: shell.primaryText,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5)),
                Text('?źę¸° ę¸°ěľ ę¸°ë°',
                    style: TextStyle(
                        color: shell.mutedText,
                        fontSize: 10.5)),
              ],
            ),
          ),
          IconButton(
            tooltip: '???ę¸°ëĄ ?? ',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: shell.primaryText.withValues(alpha: 0.55),
            onPressed: hasMessages ? onClear : null,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: '????¨ë ?ę¸°',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: shell.primaryText.withValues(alpha: 0.7),
            onPressed: onCollapse,
            icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
          ),
        ],
      ),
    );
  }
}

/// ?¨ë???í?????¤ëĽ¸ěŞ?ę°?ĽěëŚŹě ëł´ě´????
class GraphChatCollapsedTab extends StatelessWidget {
  const GraphChatCollapsedTab({super.key, required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Material(
      color: shell.panelBackground,
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onExpand,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: shell.panelBorder),
            borderRadius:
                const BorderRadius.horizontal(left: Radius.circular(14)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_rounded,
                  size: 18, color: AppColors.hubGraph),
              const SizedBox(height: 6),
              RotatedBox(
                quarterTurns: 3,
                child: Text('???,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: shell.primaryText.withValues(alpha: 0.7))),
              ),
              const SizedBox(height: 4),
              Icon(Icons.keyboard_double_arrow_left_rounded,
                  size: 14,
                  color: shell.mutedText),
            ],
          ),
        ),
      ),
    );
  }
}

// ?? Input & bubbles ???????????????????????????????????????????????????????????

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.controller,
    required this.busy,
    required this.enabled,
    required this.hint,
    required this.onSend,
    required this.onModeSelected,
  });

  final TextEditingController controller;
  final bool busy;
  final bool enabled;
  final String hint;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onModeSelected;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
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
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: shell.panelBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xs, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.onModeSelected != null)
                PopupMenuButton<String>(
                  tooltip: 'ëŞ¨ë',
                  icon: Icon(Icons.add_circle_outline_rounded,
                      color: shell.primaryText.withValues(alpha: 0.75)),
                  color: shell.barBackground,
                  onSelected: widget.onModeSelected,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'journal',
                      child: _ModeMenuRow(
                          icon: Icons.auto_stories_rounded, label: '?źę¸° ?°ę¸°'),
                    ),
                    PopupMenuItem(
                      value: 'distill',
                      child: _ModeMenuRow(
                          icon: Icons.playlist_add_check_rounded,
                          label: '??????źę¸°ëĄ??ëŚŹ'),
                    ),
                    PopupMenuItem(
                      value: 'composition',
                      child: _ModeMenuRow(
                          icon: Icons.edit_note_rounded, label: '?ëŹ¸ ?´ěŚ'),
                    ),
                    PopupMenuItem(
                      value: 'word',
                      child: _ModeMenuRow(
                          icon: Icons.spellcheck_rounded, label: '?¨ě´ ?´ěŚ'),
                    ),
                  ],
                ),
              Expanded(
                child: Focus(
                  focusNode: _focusNode,
                  onKeyEvent: _onKey,
                  child: TextField(
                    controller: widget.controller,
                    enabled: canType,
                    minLines: 1,
                    maxLines: 4,
                    style: TextStyle(
                        color: shell.primaryText, fontSize: 13.5),
                    textInputAction: TextInputAction.send,
                    onSubmitted: canType ? widget.onSend : null,
                    decoration: InputDecoration(
                      hintText: widget.hint,
                      hintStyle: TextStyle(
                          color: shell.mutedText,
                          fontSize: 13),
                      isDense: true,
                      filled: true,
                      fillColor: shell.subtleSurface,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: 9),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpacing.radiusMd),
                        borderSide: BorderSide.none,
                      ),
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
                  onTap: canType ? () => widget.onSend(widget.controller.text) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(Icons.send_rounded,
                        size: 18,
                        color: canType ? Colors.white : shell.mutedText),
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
          color: AppColors.hubGraph.withValues(alpha: 0.18),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: 24),
      child: Align(
        alignment: Alignment.centerRight,
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
          Text('ę¸°ěľ???¤ě ?´ë ě¤â?,
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
                    '?źę¸° ???,
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

class _PipelineReviewBar extends StatelessWidget {
  const _PipelineReviewBar({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: shell.barBackground,
        border: Border(top: BorderSide(color: shell.panelBorder)),
      ),
      child: Row(
        children: [
          Icon(Icons.touch_app_rounded,
              size: 16, color: AppColors.accentWarm.withValues(alpha: 0.9)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: shell.primaryText.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(Icons.lock_outline_rounded,
              size: 14,
              color: shell.mutedText),
        ],
      ),
    );
  }
}

class _PipelineLockBar extends StatelessWidget {
  const _PipelineLockBar({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: shell.barBackground,
        border: Border(top: BorderSide(color: shell.panelBorder)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: shell.primaryText.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(Icons.lock_outline_rounded,
              size: 14,
              color: shell.mutedText),
        ],
      ),
    );
  }
}
