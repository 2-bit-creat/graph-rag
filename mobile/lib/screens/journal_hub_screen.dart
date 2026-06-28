import 'package:flutter/material.dart';

import '../api/client.dart';
import '../widgets/app_ui.dart';
import '../widgets/entry_hub_layout.dart';
import '../widgets/journal_user_detail_panel.dart';
import 'journal_compose_screen.dart';

/// 사용자용 일기 목록 — 번역·내용 확인 (파이프라인 trace 없음).
class JournalHubScreen extends StatelessWidget {
  const JournalHubScreen({super.key, this.initialEntryId});

  final String? initialEntryId;

  static Future<void> openCompose(BuildContext context) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const JournalComposeScreen()),
    );
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

class _JournalEntryDetailScreenState extends State<JournalEntryDetailScreen> {
  Map<String, dynamic>? _entry;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

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
