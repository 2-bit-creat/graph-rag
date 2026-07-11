import 'package:flutter/material.dart';

import '../compose/compose_session_controller.dart';
import '../screens/kg_timeline_screen.dart';
import '../screens/menu_screen.dart';
import '../theme/app_theme.dart';
import 'chat_session_controller.dart';
import 'journal_task_controller.dart';

/// Claude-style left rail: new chat, recent rooms, and shortcuts to 기록/메뉴.
///
/// Used both as a fixed rail (wide) and inside a Drawer (narrow). [onNavigate]
/// closes the drawer after a tap on narrow; it's null when docked as a rail.
class ChatSidebar extends StatefulWidget {
  const ChatSidebar({super.key, this.onNavigate, this.onCollapse});

  final VoidCallback? onNavigate;

  /// Wide layout: collapse the docked sidebar to an icon rail.
  final VoidCallback? onCollapse;

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  // Shared calendar-date notifier for the pushed timeline screen.
  final _sharedDate = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _sharedDate.dispose();
    super.dispose();
  }

  void _afterTap() => widget.onNavigate?.call();

  Future<void> _newChat() async {
    await chatSession.newSession();
    _afterTap();
  }

  void _select(String id) {
    chatSession.selectSession(id);
    _afterTap();
  }

  Future<void> _rename(String id, String? current) async {
    final ctrl = TextEditingController(text: current ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('채팅방 이름 변경'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: '이름', border: OutlineInputBorder(), isDense: true),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('저장')),
        ],
      ),
    );
    ctrl.dispose();
    if (title != null) await chatSession.renameSession(id, title.trim());
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('채팅방 삭제'),
        content: const Text('이 채팅방을 삭제할까요? 지식그래프는 유지돼요.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok == true) await chatSession.deleteSession(id);
  }

  void _pushTimeline() {
    _afterTap();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => KgTimelineScreen(
          sharedDate: _sharedDate,
          refreshSignal: composeSession.entriesChanged,
        ),
      ),
    );
  }

  void _pushMenu() {
    _afterTap();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MenuScreen()),
    );
  }

  String? _resolvedPreview(String? preview, {required bool active}) {
    final p = preview?.trim();
    if (p == null || p.isEmpty) return null;
    if (!active || !p.contains('일기 처리')) return p;
    if (journalTask.phase == ComposePhase.done &&
        journalTask.entryId != null) {
      return '📔 지식그래프 완성';
    }
    if (journalTask.phase == ComposePhase.error) {
      return '📔 일기 처리 실패';
    }
    if (journalTask.phase == ComposePhase.needsInput &&
        journalTask.stageLabel.isNotEmpty) {
      return '📔 ${journalTask.stageLabel}';
    }
    return p;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Brand + new chat ─────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
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
              const SizedBox(width: 8),
              const Expanded(
                child: Text('MyLife English',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              if (widget.onCollapse != null)
                IconButton(
                  tooltip: '사이드바 접기',
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: OutlinedButton.icon(
            onPressed: _newChat,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('새 채팅'),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        const SizedBox(height: 6),

        // ── Recent rooms ─────────────────────────────────────────────────
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([chatSession, journalTask]),
            builder: (context, _) {
              final sessions = chatSession.sessions;
              if (sessions.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('아직 채팅방이 없어요.\n"새 채팅"으로 시작하세요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: context.shell.mutedText)),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: sessions.length,
                itemBuilder: (context, i) {
                  final s = sessions[i];
                  final id = s['id'].toString();
                  final active = id == chatSession.activeId;
                  final title = (s['title'] as String?)?.trim();
                  final preview = _resolvedPreview(
                    s['preview']?.toString(),
                    active: active,
                  );
                  return _RoomTile(
                    title: title?.isNotEmpty == true ? title! : '새 대화',
                    subtitle: preview,
                    active: active,
                    onTap: () => _select(id),
                    onRename: () => _rename(id, title),
                    onDelete: () => _delete(id),
                  );
                },
              );
            },
          ),
        ),

        const Divider(height: 1),
        _NavTile(icon: Icons.history_rounded, label: '기록', onTap: _pushTimeline),
        _NavTile(icon: Icons.grid_view_rounded, label: '메뉴', onTap: _pushMenu),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Collapsed left rail (ChatGPT/Gemini-style icon strip).
class ChatSidebarRail extends StatefulWidget {
  const ChatSidebarRail({super.key, required this.onExpand});

  final VoidCallback onExpand;

  @override
  State<ChatSidebarRail> createState() => _ChatSidebarRailState();
}

class _ChatSidebarRailState extends State<ChatSidebarRail> {
  final _sharedDate = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _sharedDate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        IconButton(
          tooltip: '사이드바 펼치기',
          onPressed: widget.onExpand,
          icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
        ),
        IconButton(
          tooltip: '새 채팅',
          onPressed: () => chatSession.newSession(),
          icon: const Icon(Icons.add_rounded),
        ),
        const Spacer(),
        IconButton(
          tooltip: '기록',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => KgTimelineScreen(
                  sharedDate: _sharedDate,
                  refreshSignal: composeSession.entriesChanged,
                ),
              ),
            );
          },
          icon: const Icon(Icons.history_rounded),
        ),
        IconButton(
          tooltip: '메뉴',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MenuScreen()),
            );
          },
          icon: const Icon(Icons.grid_view_rounded),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final String title;
  final String? subtitle;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: active ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.chat_bubble_outline_rounded,
                  size: 16,
                  color: active ? cs.primary : AppColors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: context.shell.mutedText)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '옵션',
                icon: const Icon(Icons.more_horiz_rounded, size: 18),
                padding: EdgeInsets.zero,
                onSelected: (v) {
                  if (v == 'rename') onRename();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('이름 변경')),
                  PopupMenuItem(value: 'delete', child: Text('삭제')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}
