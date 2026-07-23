import 'package:flutter/material.dart';

import '../auth/account_controller.dart';
import '../compose/compose_session_controller.dart';
import '../screens/kg_insight_screen.dart';
import '../screens/kg_timeline_screen.dart';
import '../screens/menu_screen.dart';
import '../screens/quiz_queue_screen.dart';
import '../screens/vocabulary_hub_screen.dart';
import '../theme/app_theme.dart';
import 'chat_session_controller.dart';
import 'journal_task_controller.dart';

/// Gemini-style left rail: new chat, a fixed block of compact nav shortcuts
/// (기록·내 일기·돌아보기·단어장·퀴즈 큐 — each opens its destination directly,
/// no intermediate "메뉴" hub page), a 45%-height scrollable recent-rooms
/// list, and a profile/account row pinned to the very bottom.
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
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
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

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (_searching) {
      _searchFocusNode.requestFocus();
    } else {
      _searchController.clear();
      _searchFocusNode.unfocus();
    }
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
        // sharedDate omitted — the timeline owns its own notifier now. A
        // notifier owned by this State would be disposed the moment the drawer
        // closes, crashing the still-live pushed screen.
        builder: (_) => KgTimelineScreen(
          refreshSignal: composeSession.entriesChanged,
        ),
      ),
    );
  }

  void _push(Widget screen) {
    _afterTap();
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  void _pushInsight() => _push(
        Scaffold(
          appBar: AppBar(title: const Text('돌아보기')),
          body: const KgInsightScreen(),
        ),
      );

  void _pushVocab() => _push(const VocabularyHubScreen());

  void _pushQuizQueue() => _push(const QuizQueueScreen());

  /// Single destination for the bottom profile row — a "계정 · 설정" hub
  /// (theme, account switch/delete, dev tools) with the profile/level editor
  /// one tap further in via its own header. One tap target, not two, mirrors
  /// how Gemini's bottom account row opens a single settings surface.
  void _pushAccountMenu() => _push(const MenuScreen());

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
    final shell = context.shell;
    // Gemini-style: a fixed-height nav block on top, then whatever height
    // remains splits 45/55 between the scrollable history and blank space —
    // via nested Expanded/flex rather than a raw `totalHeight * 0.45`
    // SizedBox. The earlier percent-of-*total*-height version didn't account
    // for the fixed top+bottom chrome's own height, so on a typical drawer
    // it silently overflowed off the bottom of the screen (hiding the
    // profile row entirely instead of just looking a bit cramped). Flex only
    // ever claims space actually left over, so it can't overflow.
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
              if (widget.onCollapse != null || widget.onNavigate != null)
                IconButton(
                  tooltip: '사이드바 접기',
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  onPressed: widget.onCollapse ?? widget.onNavigate,
                  icon: Icon(
                    widget.onCollapse != null
                        ? Icons.keyboard_double_arrow_left_rounded
                        : Icons.close_rounded,
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: FilledButton.tonalIcon(
            onPressed: _newChat,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('새 채팅'),
            style: FilledButton.styleFrom(
              foregroundColor: shell.primaryText,
              backgroundColor: shell.subtleSurface,
              alignment: Alignment.centerLeft,
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        const SizedBox(height: 2),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: _searching
              ? TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '채팅 검색',
                    prefixIcon: const Icon(Icons.search_rounded, size: 19),
                    suffixIcon: IconButton(
                      onPressed: _toggleSearch,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                    isDense: true,
                    filled: true,
                    fillColor: shell.subtleSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                      borderSide: BorderSide.none,
                    ),
                  ),
                )
              : _CompactNavTile(
                  icon: Icons.search_rounded,
                  label: '채팅 검색',
                  onTap: _toggleSearch,
                ),
        ),

        // ── Gemini-style compact nav block (fixed, small) ────────────────
        // Each item opens its destination directly — no intermediate "메뉴"
        // hub page to pass through first. ("내 일기" = the timeline/기록 view;
        // the old separate JournalHub "내 일기" was near-duplicate and removed.)
        _CompactNavTile(
            icon: Icons.auto_stories_outlined,
            label: '내 일기',
            onTap: _pushTimeline),
        _CompactNavTile(
            icon: Icons.bar_chart_rounded, label: '돌아보기', onTap: _pushInsight),
        _CompactNavTile(
            icon: Icons.menu_book_rounded,
            label: '단어장 · 표현 은행',
            onTap: _pushVocab),
        _CompactNavTile(
            icon: Icons.playlist_add_check_rounded,
            label: '퀴즈 큐',
            onTap: _pushQuizQueue),
        const SizedBox(height: 4),
        Divider(height: 1, color: shell.panelBorder),

        // ── Recent rooms — fills ALL remaining space and scrolls internally
        // (Gemini pattern). Earlier this was capped at 45% with 55% left
        // blank, which on web/tall windows made the list look truncated even
        // with plenty of room. Expanded claims exactly what's left, so the
        // profile row stays pinned and the list never overflows. ───────────
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Text('최근 대화',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: shell.mutedText,
              )),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([chatSession, journalTask]),
            builder: (context, _) {
              final query = _searchController.text.trim().toLowerCase();
              final sessions = query.isEmpty
                  ? chatSession.sessions
                  : chatSession.sessions.where((s) {
                      final title = s['title']?.toString().toLowerCase() ?? '';
                      final preview =
                          s['preview']?.toString().toLowerCase() ?? '';
                      return title.contains(query) || preview.contains(query);
                    }).toList();
              if (sessions.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('아직 채팅방이 없어요.\n"새 채팅"으로 시작하세요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5, color: context.shell.mutedText)),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
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

        Divider(height: 1, color: shell.panelBorder),
        _ProfileFooterRow(onTap: _pushAccountMenu),
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
          tooltip: '내 일기',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => KgTimelineScreen(
                  refreshSignal: composeSession.entriesChanged,
                ),
              ),
            );
          },
          icon: const Icon(Icons.auto_stories_outlined),
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
      color: active ? cs.primary.withValues(alpha: 0.16) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Icon(active ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
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

/// Gemini-style compact nav row — single line, small icon, no subtitle.
/// Deliberately smaller than [_RoomTile]/`AppHubTile` since this block is
/// meant to sit as fixed chrome above the scrollable history, not compete
/// with it for visual weight.
class _CompactNavTile extends StatelessWidget {
  const _CompactNavTile(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: shell.primaryText.withValues(alpha: 0.8)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: shell.primaryText,
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

/// Bottom-pinned account row (Gemini's account switcher analog). Tapping the
/// row opens profile settings; the trailing icon opens the small secondary
/// page for rarely-used account actions (계정 전환 · 데이터 삭제 · 개발자 도구).
class _ProfileFooterRow extends StatelessWidget {
  const _ProfileFooterRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final cs = Theme.of(context).colorScheme;
    final current = accountController.current;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: cs.primary,
                child: Icon(Icons.person_rounded, size: 18, color: cs.onPrimary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('내 프로필',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: shell.primaryText,
                        )),
                    if (current != null && current.isNotEmpty)
                      Text(current,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: shell.mutedText)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 19, color: shell.mutedText),
            ],
          ),
        ),
      ),
    );
  }
}
