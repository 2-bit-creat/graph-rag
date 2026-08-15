import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../app_route_observer.dart';
import '../compose/compose_session_controller.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

typedef EntryDetailBuilder = Widget Function(
  BuildContext context,
  Map<String, dynamic> entry,
  String entryId,
  Future<void> Function({bool silent}) refresh,
);

/// Confirm + delete an entry. Returns true when the entry was deleted.
Future<bool> confirmAndDeleteEntry(BuildContext context, String entryId) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('entryHub.deleteDialogTitle')),
      content: Text(
        tr('entryHub.deleteDialogBody'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(tr('common.delete')),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await apiClient.deleteEntry(entryId);
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
    return false;
  }
}

/// Confirm + delete ALL entries. Returns true when the records were deleted.
Future<bool> confirmAndDeleteAllEntries(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('entryHub.deleteAllDialogTitle')),
      content: Text(
        tr('entryHub.deleteAllDialogBody'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(tr('entryHub.deleteAllDialogTitle')),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    final deleted = await apiClient.deleteAllEntries();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('entryHub.deleteAllSnackbar', {'count': deleted}))),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
    return false;
  }
}

/// Master–detail: 녹음 기록 목록 → 선택한 기록 상세.
class EntryHubLayout extends StatefulWidget {
  const EntryHubLayout({
    super.key,
    required this.title,
    required this.detailBuilder,
    this.initialEntryId,
    this.emptyHint,
    this.emptySubtitle,
    this.onNewEntry,
    this.showEntrySourceBadge = false,
    this.entryDeletable = false,
    this.allDeletable = false,
  });

  final String title;
  final EntryDetailBuilder detailBuilder;
  final String? initialEntryId;
  final String? emptyHint;
  final String? emptySubtitle;
  final VoidCallback? onNewEntry;
  final bool showEntrySourceBadge;
  final bool entryDeletable;
  final bool allDeletable;

  @override
  State<EntryHubLayout> createState() => EntryHubLayoutState();
}

class EntryHubLayoutState extends State<EntryHubLayout> with RouteAware {
  List<dynamic> _entries = [];
  Map<String, dynamic>? _selected;
  bool _loading = true;
  bool _detailLoading = false;

  Future<void> reload() => _load();

  Future<void> selectEntry(String id) => _select(id);

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

  /// Returned from a pushed screen (e.g. graph review). Refresh both the list
  /// and the open detail quietly, without blanking the master–detail view.
  @override
  void didPopNext() {
    _silentReload();
  }

  Future<void> _silentReload() async {
    try {
      final entries = await apiClient.listEntries();
      if (mounted) setState(() => _entries = entries);
    } catch (_) {}
    await _refreshSelected(silent: true);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final entries = await apiClient.listEntries();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      if (entries.isEmpty) return;
      final initial = widget.initialEntryId;
      Map<String, dynamic>? pick;
      if (initial != null) {
        for (final e in entries) {
          if (e['id']?.toString() == initial) {
            pick = Map<String, dynamic>.from(e as Map);
            break;
          }
        }
      }
      pick ??= Map<String, dynamic>.from(entries.first as Map);
      await _select(pick['id']?.toString() ?? '', cached: pick);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(String id, {Map<String, dynamic>? cached, bool silent = false}) async {
    if (!silent) {
      setState(() {
        _detailLoading = true;
        if (cached != null) _selected = cached;
      });
    }
    try {
      final entry = await apiClient.getEntry(id);
      if (mounted) {
        setState(() {
          _selected = entry;
          _detailLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _detailLoading = false);
    }
  }

  Future<void> _refreshSelected({bool silent = false}) async {
    final id = _selected?['id']?.toString();
    if (id == null) return;
    await _select(id, silent: silent);
  }

  Future<void> _deleteSelected() async {
    final id = _selected?['id']?.toString();
    if (id == null) return;
    final deleted = await confirmAndDeleteEntry(context, id);
    if (deleted && mounted) {
      setState(() => _selected = null);
      await _load();
    }
  }

  Future<void> _deleteAll() async {
    final deleted = await confirmAndDeleteAllEntries(context);
    if (deleted && mounted) {
      setState(() => _selected = null);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (widget.allDeletable && _entries.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.delete_sweep_outlined),
          tooltip: tr('entryHub.deleteAllTooltip'),
          onPressed: _deleteAll,
        ),
      if (widget.entryDeletable && _selected != null)
        IconButton(
          icon: const Icon(Icons.delete_outline_rounded),
          tooltip: tr('entryHub.deleteEntryTooltip'),
          onPressed: _deleteSelected,
        ),
      if (widget.onNewEntry != null)
        IconButton(
          icon: const Icon(Icons.add_rounded),
          tooltip: tr('entryHub.newEntryTooltip'),
          onPressed: widget.onNewEntry,
        ),
    ];
    return Scaffold(
      appBar: AppHubAppBar(
        title: widget.title,
        subtitle: _loading ? null : tr('entryHub.recordCountSuffix', {'count': _entries.length}),
        actions: actions.isEmpty ? null : actions,
      ),
      floatingActionButton: widget.onNewEntry == null
          ? null
          // 작성 세션이 살아 있는 동안은 우하단 미니 창이 이 자리를 쓴다.
          : ListenableBuilder(
              listenable: composeSession,
              builder: (context, _) => composeSession.isActive
                  ? const SizedBox.shrink()
                  : FloatingActionButton.extended(
                      onPressed: widget.onNewEntry,
                      icon: const Icon(Icons.edit_note_rounded),
                      label: Text(tr('entryHub.newEntryButton')),
                    ),
            ),
      body: _loading
          ? const AppLoadingScreen()
          : _entries.isEmpty
              ? AppEmptyState(
                  icon: Icons.auto_stories_outlined,
                  title: widget.emptyHint ?? tr('entryHub.emptyHint'),
                  subtitle: widget.emptySubtitle ?? tr('entryHub.emptySubtitle'),
                  action: widget.onNewEntry == null
                      ? null
                      : FilledButton.icon(
                          onPressed: widget.onNewEntry,
                          icon: const Icon(Icons.add_rounded),
                          label: Text(tr('entryHub.startRecordingButton')),
                        ),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 280,
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surfaceContainerLowest,
                        child: RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            itemCount: _entries.length,
                            itemBuilder: (context, i) {
                              final e = _entries[i] as Map<String, dynamic>;
                              final id = e['id']?.toString() ?? '';
                              final selected = _selected?['id']?.toString() == id;
                              return _EntryListTile(
                                entry: e,
                                selected: selected,
                                showSourceBadge: widget.showEntrySourceBadge,
                                onTap: () => _select(id, cached: e),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(
                      child: _detailLoading && _selected == null
                          ? const AppLoadingScreen()
                          : _selected == null
                              ? AppEmptyState(
                                  icon: Icons.article_outlined,
                                  title: tr('entryHub.selectEntryHint'),
                                )
                              : widget.detailBuilder(
                                  context,
                                  _selected!,
                                  _selected!['id']?.toString() ?? '',
                                  _refreshSelected,
                                ),
                    ),
                  ],
                ),
    );
  }
}

class _EntryListTile extends StatelessWidget {
  const _EntryListTile({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.showSourceBadge = false,
  });

  final Map<String, dynamic> entry;
  final bool selected;
  final VoidCallback onTap;
  final bool showSourceBadge;

  /// First sentence of [value], or null when it carries no text to show.
  static String? _firstSentence(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final head = text.split('.').first.trim();
    // A leading "." would otherwise blank the row out again.
    return head.isEmpty ? text : head;
  }

  @override
  Widget build(BuildContext context) {
    final created = DateTime.tryParse(entry['created_at']?.toString() ?? '');
    final date = created != null
        ? DateFormat('M/d HH:mm').format(created.toLocal())
        : '';
    final status = entry['status']?.toString() ?? '';
    final processing = status == 'processing' || status == 'graph_processing';
    // Fall through on blank as well as null. `??` only skips null, and the
    // server sends translation_en as "" for every entry since the translation
    // pass was removed — so "" won the chain and each row rendered an empty
    // preview. The list became 50 rows of bare timestamps with no way to tell
    // one entry from another.
    final preview = _firstSentence(entry['translation_en']) ??
        _firstSentence(entry['transcript_ko']) ??
        tr('entryHub.processingLabel');
    final isText = entry['entry_source']?.toString() == 'precision_text';
    final entryIcon = isText ? Icons.edit_note_rounded : Icons.mic_rounded;

    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      child: Material(
        color: selected
            ? colorScheme.primaryContainer.withValues(alpha: 0.4)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: selected ? colorScheme.primary : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 2),
                  child: Icon(
                    entryIcon,
                    size: 16,
                    color: selected ? colorScheme.primary : colorScheme.outline,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(date, style: Theme.of(context).textTheme.bodySmall),
                          if (showSourceBadge) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isText ? tr('entryHub.badgeText') : tr('entryHub.badgeVoice'),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (processing)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 2),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      ),
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

/// Narrow screens: list → push detail.
class EntryHubNavigator extends StatefulWidget {
  const EntryHubNavigator({
    super.key,
    required this.title,
    required this.detailBuilder,
    this.initialEntryId,
    this.emptyHint,
    this.emptySubtitle,
    this.onNewEntry,
    this.showEntrySourceBadge = false,
    this.entryDeletable = false,
    this.allDeletable = false,
  });

  final String title;
  final EntryDetailBuilder detailBuilder;
  final String? initialEntryId;
  final String? emptyHint;
  final String? emptySubtitle;
  final VoidCallback? onNewEntry;
  final bool showEntrySourceBadge;
  final bool entryDeletable;
  final bool allDeletable;

  @override
  State<EntryHubNavigator> createState() => _EntryHubNavigatorState();
}

class _EntryHubNavigatorState extends State<EntryHubNavigator> with RouteAware {
  List<dynamic> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.initialEntryId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _open(widget.initialEntryId!);
      });
    }
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

  /// Returned from the pushed entry detail — refresh the list silently so status
  /// (graph / speakers) reflects any changes made in detail.
  @override
  void didPopNext() => _load(silent: true);

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final entries = await apiClient.listEntries();
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _open(String entryId) async {
    // The list refreshes on return via didPopNext.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => _EntryDetailPage(
          title: widget.title,
          entryId: entryId,
          detailBuilder: widget.detailBuilder,
          entryDeletable: widget.entryDeletable,
        ),
      ),
    );
  }

  Future<void> _deleteAll() async {
    final deleted = await confirmAndDeleteAllEntries(context);
    if (deleted && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    if (wide) {
      return EntryHubLayout(
        title: widget.title,
        initialEntryId: widget.initialEntryId,
        emptyHint: widget.emptyHint,
        emptySubtitle: widget.emptySubtitle,
        onNewEntry: widget.onNewEntry,
        showEntrySourceBadge: widget.showEntrySourceBadge,
        entryDeletable: widget.entryDeletable,
        allDeletable: widget.allDeletable,
        detailBuilder: widget.detailBuilder,
      );
    }
    final actions = <Widget>[
      if (widget.allDeletable && _entries.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.delete_sweep_outlined),
          tooltip: tr('entryHub.deleteAllTooltip'),
          onPressed: _deleteAll,
        ),
      if (widget.onNewEntry != null)
        IconButton(
          icon: const Icon(Icons.add_rounded),
          tooltip: tr('entryHub.newEntryTooltip'),
          onPressed: widget.onNewEntry,
        ),
    ];
    return Scaffold(
      appBar: AppHubAppBar(
        title: widget.title,
        subtitle: _loading ? null : tr('entryHub.recordCountSuffix', {'count': _entries.length}),
        actions: actions.isEmpty ? null : actions,
      ),
      floatingActionButton: widget.onNewEntry == null
          ? null
          // 작성 세션이 살아 있는 동안은 우하단 미니 창이 이 자리를 쓴다.
          : ListenableBuilder(
              listenable: composeSession,
              builder: (context, _) => composeSession.isActive
                  ? const SizedBox.shrink()
                  : FloatingActionButton.extended(
                      onPressed: widget.onNewEntry,
                      icon: const Icon(Icons.edit_note_rounded),
                      label: Text(tr('entryHub.newEntryButton')),
                    ),
            ),
      body: _loading
          ? const AppLoadingScreen()
          : RefreshIndicator(
              onRefresh: _load,
              child: _entries.isEmpty
                  ? ListView(
                      children: [
                        AppEmptyState(
                          icon: Icons.auto_stories_outlined,
                          title: widget.emptyHint ?? tr('entryHub.emptyHint'),
                          subtitle: widget.emptySubtitle ?? tr('entryHub.emptySubtitle'),
                          action: widget.onNewEntry == null
                              ? null
                              : FilledButton.icon(
                                  onPressed: widget.onNewEntry,
                                  icon: const Icon(Icons.add_rounded),
                                  label: Text(tr('entryHub.writeJournalButton')),
                                ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      // Clear the extended FAB. With a symmetric 8px the last
                      // entry stayed under it however far the list was
                      // scrolled, so the newest-but-one record could not be
                      // read or tapped.
                      padding: EdgeInsets.only(
                        top: AppSpacing.sm,
                        bottom: widget.onNewEntry == null ? AppSpacing.sm : 88,
                      ),
                      itemCount: _entries.length,
                      itemBuilder: (context, i) {
                        final e = _entries[i] as Map<String, dynamic>;
                        final id = e['id']?.toString() ?? '';
                        return _EntryListTile(
                          entry: e,
                          selected: false,
                          showSourceBadge: widget.showEntrySourceBadge,
                          onTap: () => _open(id),
                        );
                      },
                    ),
            ),
    );
  }
}

class _EntryDetailPage extends StatefulWidget {
  const _EntryDetailPage({
    required this.title,
    required this.entryId,
    required this.detailBuilder,
    this.entryDeletable = false,
  });

  final String title;
  final String entryId;
  final EntryDetailBuilder detailBuilder;
  final bool entryDeletable;

  @override
  State<_EntryDetailPage> createState() => _EntryDetailPageState();
}

class _EntryDetailPageState extends State<_EntryDetailPage> with RouteAware {
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
        title: Text(widget.title),
        actions: [
          if (widget.entryDeletable && _entry != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: tr('entryHub.deleteEntryTooltip'),
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
                  title: tr('entryHub.loadFailed'),
                )
              : widget.detailBuilder(context, _entry!, widget.entryId, _load),
    );
  }
}
