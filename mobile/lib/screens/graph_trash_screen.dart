import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

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
        title: const Text('노드 복구'),
        content: Text('「${node['name']}」 노드와 연결됐던 고아 노드들을 함께 복구합니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('복구')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await apiClient.restoreFromTrash(node['id'].toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('복구 완료')),
        );
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('복구 실패: $e')),
        );
      }
    }
  }

  Future<void> _purge(Map<String, dynamic> node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('영구 삭제'),
        content: Text('「${node['name']}」 노드를 영구 삭제합니다. 이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('영구 삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await apiClient.purgeFromTrash(node['id'].toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('영구 삭제 완료')),
        );
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('영구 삭제 실패: $e')),
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
        title: const Text('휴지통'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen(message: '휴지통 불러오는 중…')
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _nodes.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_outline, size: 56, color: Colors.grey),
                          SizedBox(height: 12),
                          Text('휴지통이 비어 있습니다', style: TextStyle(color: Colors.grey)),
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
                                          ctxType,
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
                                    style: TextStyle(fontSize: 13, color: context.mutedText),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(Icons.delete_outline, size: 13, color: context.mutedText),
                                    const SizedBox(width: 4),
                                    Text(
                                      deletedAt,
                                      style: TextStyle(fontSize: 11, color: context.mutedText),
                                    ),
                                    if (orphanCount > 0 || quizCount > 0) ...[
                                      const SizedBox(width: 10),
                                      Text(
                                        '노드 +$orphanCount · 퀴즈 $quizCount',
                                        style: TextStyle(fontSize: 11, color: context.mutedText),
                                      ),
                                    ],
                                    const Spacer(),
                                    TextButton.icon(
                                      onPressed: () => _restore(node),
                                      icon: const Icon(Icons.restore, size: 16),
                                      label: const Text('복구', style: TextStyle(fontSize: 13)),
                                    ),
                                    const SizedBox(width: 4),
                                    TextButton.icon(
                                      onPressed: () => _purge(node),
                                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                                      icon: const Icon(Icons.delete_forever, size: 16),
                                      label: const Text('영구 삭제', style: TextStyle(fontSize: 13)),
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
