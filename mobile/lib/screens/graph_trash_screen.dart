import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

// Same canonical taxonomy as kg_timeline_screen's _kTypeLabels.
Map<String, String> get _kSourceLabels => {
      '개인일기': tr('timeline.typePersonalDiary'),
      '회의록': tr('timeline.typeMeetingNotes'),
      '책': tr('timeline.typeBook'),
      '뉴스': tr('timeline.typeNews'),
      '강연': tr('timeline.typeLecture'),
      '논문': tr('timeline.typePaper'),
      '대화': tr('timeline.typeConversation'),
      '잡지': tr('timeline.typeMagazine'),
      '자료': tr('timeline.typeMaterial'),
      '미분류': tr('inspector.uncategorized'),
    };
String _sourceLabelFor(String type) => _kSourceLabels[type] ?? type;

class GraphTrashScreen extends StatefulWidget {
  const GraphTrashScreen({super.key});

  @override
  State<GraphTrashScreen> createState() => _GraphTrashScreenState();
}

class _GraphTrashScreenState extends State<GraphTrashScreen> {
  List<dynamic> _nodes = [];
  bool _loading = true;
  String? _error;

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
      final nodes = await apiClient.listTrash();
      if (mounted) setState(() {
        _nodes = nodes;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _restore(Map<String, dynamic> node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('trash.restoreDialogTitle')),
        content: Text(tr('trash.restoreDialogBody', {'name': node['name']})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('trash.restoreAction'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await apiClient.restoreFromTrash(node['id'].toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('trash.restoredSnackbar'))),
        );
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('trash.restoreFailedSnackbar', {'error': e}))),
        );
      }
    }
  }

  Future<void> _purge(Map<String, dynamic> node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('trash.purgeDialogTitle')),
        content: Text(tr('trash.purgeDialogBody', {'name': node['name']})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('trash.purgeAction')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await apiClient.purgeFromTrash(node['id'].toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('trash.purgedSnackbar'))),
        );
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('trash.purgeFailedSnackbar', {'error': e}))),
        );
      }
    }
  }

  String _parseContent(Map<String, dynamic> node) {
    final desc = node['description']?.toString() ?? '';
    if (desc.isEmpty) return node['name']?.toString() ?? '';
    try {
      final data = jsonDecode(desc) as Map<String, dynamic>;
      return data['content']?.toString() ?? node['name']?.toString() ?? '';
    } catch (_) {
      return desc;
    }
  }

  String _parseContextType(Map<String, dynamic> node) {
    final desc = node['description']?.toString() ?? '';
    try {
      final data = jsonDecode(desc) as Map<String, dynamic>;
      return data['context_type']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('trash.pageTitle')),
        actions: [
          IconButton(
            tooltip: tr('common.refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? AppLoadingScreen(message: tr('trash.loadingMessage'))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _nodes.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.delete_outline, size: 56, color: Colors.grey),
                          const SizedBox(height: 12),
                          Text(tr('trash.emptyMessage'), style: const TextStyle(color: Colors.grey)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _nodes.length,
                      itemBuilder: (context, i) {
                        final node = Map<String, dynamic>.from(_nodes[i] as Map);
                        final ctxType = _parseContextType(node);
                        final content = _parseContent(node);
                        final deletedAt = _formatDate(node['deleted_at']?.toString());
                        final ctx = node['deleted_context'] as Map? ?? {};
                        final orphanCount = (ctx['orphan_node_ids'] as List?)?.length ?? 0;
                        final quizCount = (ctx['quiz_ids'] as List?)?.length ?? 0;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (ctxType.isNotEmpty) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: AppColors.primary.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          _sourceLabelFor(ctxType),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.primary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    Expanded(
                                      child: Text(
                                        node['name']?.toString() ?? '',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                if (content.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    content,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(Icons.delete_outline, size: 13, color: Colors.grey[500]),
                                    const SizedBox(width: 4),
                                    Text(
                                      deletedAt,
                                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                    ),
                                    if (orphanCount > 0 || quizCount > 0) ...[
                                      const SizedBox(width: 10),
                                      Text(
                                        tr('trash.impactSuffix', {'orphans': orphanCount, 'quizzes': quizCount}),
                                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                      ),
                                    ],
                                    const Spacer(),
                                    TextButton.icon(
                                      onPressed: () => _restore(node),
                                      icon: const Icon(Icons.restore, size: 16),
                                      label: Text(tr('trash.restoreAction'), style: const TextStyle(fontSize: 13)),
                                    ),
                                    const SizedBox(width: 4),
                                    TextButton.icon(
                                      onPressed: () => _purge(node),
                                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                                      icon: const Icon(Icons.delete_forever, size: 16),
                                      label: Text(tr('trash.purgeAction'), style: const TextStyle(fontSize: 13)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
