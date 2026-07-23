import 'package:flutter/material.dart';

import '../api/client.dart';
import '../app_route_observer.dart';
import '../chat/chat_session_controller.dart' show openChatJournalCompose;
import '../widgets/app_ui.dart';
import '../widgets/entry_hub_layout.dart';
import '../widgets/journal_user_detail_panel.dart';

/// 사용자용 일기 목록 — 번역·내용 확인 (파이프라인 trace 없음).
class JournalHubScreen extends StatelessWidget {
  const JournalHubScreen({super.key, this.initialEntryId});

  final String? initialEntryId;

  /// 새 일기 쓰기 — 팝업 작성 창 대신 홈(대화)의 채팅 일기 쓰기 모드로 이동.
  static Future<void> openCompose(BuildContext context) {
    openChatJournalCompose();
    return Future.value();
  }

  /// Open a single entry's detail directly (e.g. from the Timeline), so pressing
  /// back returns to the caller (timeline/calendar) — NOT the journal list.
  static Future<void> openEntryDetail(BuildContext context, String entryId) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JournalEntryDetailScreen(entryId: entryId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (initialEntryId != null) {
      return JournalEntryDetailScreen(entryId: initialEntryId!);
    }
    return EntryHubNavigator(
      title: '내 일기',
      initialEntryId: initialEntryId,
      emptyHint: '아직 일기가 없습니다',
      emptySubtitle: '일기 쓰기에서 첫 기록을 남겨 보세요',
      onNewEntry: () => openCompose(context),
      entryDeletable: true,
      allDeletable: true,
      detailBuilder: (context, entry, entryId, refresh) {
        return JournalUserDetailPanel(
          entryId: entryId,
          entry: entry,
          onRefresh: refresh,
        );
      },
    );
  }
}

/// Standalone journal entry detail — pushed directly so back returns to caller.
class JournalEntryDetailScreen extends StatefulWidget {
  const JournalEntryDetailScreen({super.key, required this.entryId});

  final String entryId;

  @override
  State<JournalEntryDetailScreen> createState() =>
      _JournalEntryDetailScreenState();
}

class _JournalEntryDetailScreenState extends State<JournalEntryDetailScreen>
    with RouteAware {
  Map<String, dynamic>? _entry;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// Returned from a pushed screen (graph review / knowledge graph) — refresh
  /// silently so speaker/graph updates show without a loading flash.
  @override
  void didPopNext() => _load(silent: true);

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final entry = await apiClient.getEntry(widget.entryId);
      if (mounted) {
        setState(() {
          _entry = entry;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 일기'),
        actions: [
          if (_entry != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: '일기 삭제',
              onPressed: () async {
                final deleted =
                    await confirmAndDeleteEntry(context, widget.entryId);
                if (deleted && context.mounted) Navigator.of(context).pop();
              },
            ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen()
          : _entry == null
              ? const AppEmptyState(
                  icon: Icons.error_outline_rounded,
                  title: '불러오기 실패',
                )
              : JournalUserDetailPanel(
                  entryId: widget.entryId,
                  entry: _entry!,
                  onRefresh: _load,
                ),
    );
  }
}
