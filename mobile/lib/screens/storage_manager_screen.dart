import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'graph_trash_screen.dart';

/// 저장공간 관리 — the single place data is inspected and given back.
///
/// Before this screen, "지식그래프 전체 삭제" and the trash lived in the graph
/// canvas's overflow menu, one mis-tap from the view toggles, while photos,
/// recordings, chats and quiz artifacts had no delete surface at all. Those are
/// all the same question — "what is this account holding, and what can I let
/// go?" — so they answer it in one place, under 내 프로필.
///
/// Category deletes hit `DELETE /storage/categories/{key}`; the reset button
/// hits `/storage/all`, which keeps the account (handle, native language,
/// consent) and clears everything derived from the user's content. Deleting the
/// *account* stays on the menu screen — a different decision with a different
/// blast radius.
class StorageManagerScreen extends StatefulWidget {
  const StorageManagerScreen({super.key});

  @override
  State<StorageManagerScreen> createState() => _StorageManagerScreenState();
}

class _StorageManagerScreenState extends State<StorageManagerScreen> {
  Map<String, dynamic>? _usage;
  bool _loading = true;
  String? _error;
  String? _busyKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final usage = await apiClient.getStorageUsage();
      if (mounted) setState(() { _usage = usage; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  List<Map<String, dynamic>> get _categories {
    final raw = _usage?['categories'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _deleteCategory(Map<String, dynamic> category) async {
    final key = category['key']?.toString() ?? '';
    final label = _label(key, category);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('storage.deleteTitle', {'label': label})),
        content: Text(
          '${tr('storage.deleteBody', {
            'label': label,
            'size': formatBytes(category['bytes']),
          })}\n\n${_description(key, category)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('storage.deleteAction')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busyKey = key);
    try {
      await apiClient.purgeStorageCategory(key);
      _toast(tr('storage.deleted', {'label': label}));
      await _load();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _resetEverything() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('storage.resetConfirmTitle')),
        content: Text(tr('storage.resetConfirmBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('storage.resetAction')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busyKey = '_all');
    try {
      await apiClient.purgeAllStorage();
      _toast(tr('storage.resetDone'));
      await _load();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  /// Server labels are the fallback: the app's own strings follow the UI
  /// locale, which the API does not know about.
  String _label(String key, Map<String, dynamic> category) {
    final localized = tr('storage.categoryLabel.$key');
    if (localized != 'storage.categoryLabel.$key') return localized;
    return category['label']?.toString() ?? key;
  }

  String _description(String key, Map<String, dynamic> category) {
    final localized = tr('storage.categoryDesc.$key');
    if (localized != 'storage.categoryDesc.$key') return localized;
    return category['description']?.toString() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('storage.title')),
        actions: [
          IconButton(
            tooltip: tr('kg.refreshTooltip'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen()
          : _error != null
              ? _ErrorBody(message: _error!, onRetry: _load)
              : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _usage?['total_bytes'];
    final busy = _busyKey != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageH, AppSpacing.md, AppSpacing.pageH, AppSpacing.xxl,
      ),
      children: [
        _TotalCard(bytes: total, categories: _categories),
        const SizedBox(height: 6),
        Text(tr('storage.approxNote'),
            style: TextStyle(fontSize: 11.5, color: context.shell.mutedText)),
        const SizedBox(height: AppSpacing.lg),
        for (final category in _categories) ...[
          _CategoryCard(
            color: _TotalCard.colorFor(context, category['key']?.toString()),
            label: _label(category['key']?.toString() ?? '', category),
            description: _description(category['key']?.toString() ?? '', category),
            bytes: category['bytes'],
            items: category['items'],
            busy: _busyKey == category['key'],
            // A category with nothing in it has nothing to delete; keeping the
            // row visible still answers "where did my photos go?".
            onDelete: (busy || (category['bytes'] as num? ?? 0) <= 0)
                ? null
                : () => _deleteCategory(category),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.lg),
        AppSectionHeader(title: tr('storage.trashTitle')),
        const SizedBox(height: AppSpacing.sm),
        AppHubTile(
          icon: Icons.delete_outline_rounded,
          title: tr('storage.trashTitle'),
          subtitle: tr('storage.trashSubtitle'),
          color: AppColors.hubGraph,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const GraphTrashScreen()),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        AppSectionHeader(
          title: tr('storage.resetSectionTitle'),
          subtitle: tr('storage.resetSubtitle'),
        ),
        const SizedBox(height: AppSpacing.sm),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: busy ? null : _resetEverything,
          icon: _busyKey == '_all'
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.restart_alt_rounded),
          label: Text(tr('storage.resetAction')),
        ),
      ],
    );
  }
}

/// Total + a one-bar breakdown, so the biggest category is obvious before
/// reading any number.
class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.bytes, required this.categories});

  final dynamic bytes;
  final List<Map<String, dynamic>> categories;

  /// One hue per category, reused by the bar so a glance at the widest band
  /// answers "what is actually taking the space".
  static const _colors = <String, Color>{
    'images': AppColors.hubVoice,
    'audio': AppColors.accentWarm,
    'journals': Color(0xFF10B981),
    'graph': AppColors.hubGraph,
    'chats': Color(0xFF0EA5E9),
    'quizzes': AppColors.hubQuiz,
    'debug': AppColors.textMuted,
  };

  static Color colorFor(BuildContext context, String? key) =>
      _colors[key] ??
      Theme.of(context).colorScheme.primary.withValues(alpha: 0.45);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = (bytes as num? ?? 0).toDouble();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('storage.totalLabel'),
              style: TextStyle(fontSize: 12, color: context.shell.mutedText)),
          const SizedBox(height: 4),
          Text(formatBytes(bytes),
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          if (total > 0) ...[
            const SizedBox(height: AppSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: [
                    for (final c in categories)
                      if (((c['bytes'] as num?) ?? 0) > 0)
                        Expanded(
                          flex: ((c['bytes'] as num).toDouble() / total * 1000)
                              .round()
                              .clamp(1, 1000),
                          child: ColoredBox(
                            color: colorFor(context, c['key']?.toString()),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.color,
    required this.label,
    required this.description,
    required this.bytes,
    required this.items,
    required this.busy,
    this.onDelete,
  });

  final Color color;
  final String label;
  final String description;
  final dynamic bytes;
  final dynamic items;
  final bool busy;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = (items as num?)?.toInt() ?? 0;
    final empty = ((bytes as num?) ?? 0) <= 0;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Ties this row to its band in the total bar above.
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                          color: color, borderRadius: BorderRadius.circular(2)),
                    ),
                    Expanded(
                      child: Text(label,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    Text(
                      empty ? tr('storage.emptyCategory') : formatBytes(bytes),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: empty ? context.shell.mutedText : null,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  count > 0
                      ? '${tr('storage.itemsSuffix', {'count': count})} · $description'
                      : description,
                  style:
                      TextStyle(fontSize: 11.5, color: context.shell.mutedText),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: tr('storage.deleteAction'),
              onPressed: onDelete,
              color: scheme.error,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 36),
            const SizedBox(height: 12),
            Text(tr('storage.loadFailed'), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: context.shell.mutedText)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(tr('common.retry'))),
          ],
        ),
      ),
    );
  }
}

/// Human-readable byte size. Shared with the account overview so main and the
/// account owner read the same units for the same number.
String formatBytes(dynamic value) {
  final bytes = (value as num?)?.toDouble() ?? 0;
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final digits = size >= 100 || unit == 0 ? 0 : 1;
  return '${size.toStringAsFixed(digits)} ${units[unit]}';
}
