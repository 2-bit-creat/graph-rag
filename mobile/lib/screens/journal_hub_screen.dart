import 'package:flutter/material.dart';

import '../api/client.dart';
import '../app_route_observer.dart';
import '../l10n/app_strings.dart';
import '../widgets/app_ui.dart';
import '../widgets/entry_hub_layout.dart';
import '../widgets/journal_user_detail_panel.dart';

/// Standalone journal entry detail — pushed directly so back returns to caller.
///
/// There used to be a `JournalHubScreen` list above this: a full record list
/// with its own search, delete-all and split-pane detail. Nothing in the app
/// ever constructed it. The sidebar's 내 일기 opens [KgTimelineScreen], and the
/// only paths into journal content push this detail screen straight from the
/// timeline or the progress card. The list was removed rather than wired up,
/// since the timeline already answers "what have I recorded" with more (type
/// filters, per-day grouping, speakers, calendar).
class JournalEntryDetailScreen extends StatefulWidget {
  const JournalEntryDetailScreen({super.key, required this.entryId});

  /// Open a single entry's detail, so pressing back returns to the caller
  /// (timeline / calendar / progress card).
  static Future<void> open(BuildContext context, String entryId) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JournalEntryDetailScreen(entryId: entryId),
      ),
    );
  }

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
        title: Text(tr('journalHub.pageTitle')),
        actions: [
          if (_entry != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: tr('journalHub.deleteTooltip'),
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
              ? AppEmptyState(
                  icon: Icons.error_outline_rounded,
                  title: tr('journalHub.loadFailed'),
                  action: FilledButton.icon(
                    onPressed: () => _load(),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(tr('common.retry')),
                  ),
                )
              : JournalUserDetailPanel(
                  entryId: widget.entryId,
                  entry: _entry!,
                  onRefresh: _load,
                ),
    );
  }
}
