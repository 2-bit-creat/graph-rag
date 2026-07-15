import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';

/// Right-side inspector for node / edge detail and editing.
class GraphInspectorPanel extends StatefulWidget {
  const GraphInspectorPanel({
    super.key,
    this.selectedNode,
    this.selectedEdge,
    required this.edges,
    required this.nodeById,
    required this.typeColors,
    required this.relationTypes,
    required this.entityTypes,
    this.onClose,
    this.onUpdated,
    this.onSelectNode,
    this.onSelectEdge,
    this.scrollController,
  });

  final Map<String, dynamic>? selectedNode;
  final Map<String, dynamic>? selectedEdge;
  final List<Map<String, dynamic>> edges;
  final Map<String, Map<String, dynamic>> nodeById;
  final Map<String, Color> typeColors;
  final List<String> relationTypes;
  final List<Map<String, dynamic>> entityTypes;
  final VoidCallback? onClose;
  final VoidCallback? onUpdated;
  final void Function(Map<String, dynamic> node)? onSelectNode;
  final void Function(Map<String, dynamic> edge)? onSelectEdge;
  final ScrollController? scrollController;

  /// Bottom sheet vs fixed side panel layout.
  bool get isSheetMode => scrollController != null;

  @override
  State<GraphInspectorPanel> createState() => _GraphInspectorPanelState();
}

class _GraphInspectorPanelState extends State<GraphInspectorPanel> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _relationCtrl = TextEditingController();
  String? _type;
  bool _saving = false;

  @override
  void didUpdateWidget(covariant GraphInspectorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFields();
  }

  @override
  void initState() {
    super.initState();
    _syncFields();
  }

  List<String> get _entityTypeNames => widget.entityTypes
      .map((et) => et['name']?.toString())
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .toList();

  /// Match ontology names case-insensitively (DB may store CONCEPT vs Concept).
  String? _resolveEntityType(String? raw) {
    if (raw == null || raw.isEmpty) {
      return _entityTypeNames.isNotEmpty ? _entityTypeNames.first : 'Entity';
    }
    final canon = canonicalEntityType(raw);
    for (final name in _entityTypeNames) {
      if (name.toLowerCase() == canon.toLowerCase()) return name;
    }
    return canon;
  }

  List<DropdownMenuItem<String>> _typeDropdownItems() {
    final byKey = <String, String>{};
    for (final n in _entityTypeNames) {
      byKey.putIfAbsent(n.toLowerCase(), () => n);
    }
    if (_type != null && _type!.isNotEmpty) {
      byKey.putIfAbsent(_type!.toLowerCase(), () => _type!);
    }
    if (byKey.isEmpty) byKey['entity'] = 'Entity';
    return byKey.values
        .map((n) => DropdownMenuItem(value: n, child: Text(n)))
        .toList();
  }

  String? _selectedTypeValue() {
    final items = _typeDropdownItems();
    final values = items.map((i) => i.value).whereType<String>().toList();
    if (_type != null && values.contains(_type)) return _type;
    return values.isNotEmpty ? values.first : null;
  }

  List<String> _relationSuggestions(String? current) {
    final opts = <String>{
      for (final r in widget.relationTypes)
        if (r.trim().isNotEmpty) r.trim(),
    };
    if (current != null && current.trim().isNotEmpty) opts.add(current.trim());
    if (opts.isEmpty) opts.add('RELATED_TO');
    return opts.toList();
  }

  // ── Statement description helpers ──────────────────────────────────────────

  String _stmtContent(Map<String, dynamic> node) {
    final ctxField = node['content']?.toString();
    if (ctxField != null) return ctxField.trim();
    final desc = (node['description'] as String? ?? '').trim();
    if (desc.startsWith('{')) {
      try {
        final map = (jsonDecode(desc) as Map).cast<String, dynamic>();
        return (map['content'] as String? ?? '').trim();
      } catch (_) {}
    }
    final parts = desc.split('\n');
    return parts.length > 1 ? parts.sublist(1).join('\n').trim() : desc;
  }

  String _stmtCtxType(Map<String, dynamic> node) {
    final ctxField = node['context_type']?.toString();
    if (ctxField != null) return ctxField.trim();
    final desc = (node['description'] as String? ?? '').trim();
    if (desc.startsWith('{')) {
      try {
        final map = (jsonDecode(desc) as Map).cast<String, dynamic>();
        return (map['context_type'] as String? ?? '미분류').trim();
      } catch (_) {}
    }
    return desc.split('\n').first.trim().isEmpty ? '미분류' : desc.split('\n').first.trim();
  }

  String _buildStmtDescription(String contextType, String content) =>
      jsonEncode({'context_type': contextType, 'content': content});

  bool _isStatementNode(Map<String, dynamic>? node) =>
      (node?['type'] as String? ?? '').toLowerCase() == 'statement';

  Widget _sourceTranscriptWidget(Map<String, dynamic> node) {
    final raw = node['source_transcript_ko'] as String? ?? '';
    final clean = node['source_transcript_clean_ko'] as String? ?? '';
    if (raw.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _SourceTranscriptSection(raw: raw, label: '원문 (정제 전 원본)'),
      );
    }
    if (clean.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _SourceTranscriptSection(raw: clean, label: '원문 (일기 전체)'),
      );
    }
    return const SizedBox.shrink();
  }

  // ── Field sync ─────────────────────────────────────────────────────────────

  void _syncFields() {
    final node = widget.selectedNode;
    if (node != null) {
      _nameCtrl.text = node['name']?.toString() ?? '';
      // For Statement nodes: show only the content text, not the raw JSON
      if (_isStatementNode(node)) {
        _descCtrl.text = _stmtContent(node);
      } else {
        _descCtrl.text = node['description']?.toString() ?? '';
      }
      _type = _resolveEntityType(node['type']?.toString());
    }
    final edge = widget.selectedEdge;
    if (edge != null) {
      _relationCtrl.text = edge['relation']?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _relationCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveNode() async {
    final node = widget.selectedNode;
    if (node == null || _type == null) return;
    setState(() => _saving = true);

    // For Statement nodes: user edits the content text, we re-wrap in JSON
    String? descToSave;
    final contentText = _descCtrl.text.trim();
    if (_isStatementNode(node) && contentText.isNotEmpty) {
      final ctxType = _stmtCtxType(node);
      descToSave = _buildStmtDescription(ctxType, contentText);
    } else {
      descToSave = contentText.isEmpty ? null : contentText;
    }

    try {
      await apiClient.updateNode(
        node['id'].toString(),
        name: _nameCtrl.text.trim(),
        type: _type!,
        description: descToSave,
      );
      widget.onUpdated?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('노드 저장됨')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteNode() async {
    final node = widget.selectedNode;
    if (node == null) return;
    final isStatement = (node['type']?.toString() ?? '') == 'Statement';

    // Load deletion impact counts before showing dialog
    Map<String, dynamic> impact = {};
    if (isStatement) {
      try {
        impact = await apiClient.getNodeDeletionImpact(node['id'].toString());
      } catch (_) {}
    }

    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        if (!isStatement) {
          return AlertDialog(
            title: const Text('노드 삭제'),
            content: Text('「${node['name']}」 노드와 연결된 관계도 삭제됩니다.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
            ],
          );
        }
        final edgeCount = impact['edge_count'] as int? ?? 0;
        final orphanCount = impact['orphan_node_count'] as int? ?? 0;
        final quizCount = impact['quiz_count'] as int? ?? 0;
        final exprCount = impact['expression_count'] as int? ?? 0;
        return AlertDialog(
          title: const Text('노드 삭제'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('「${node['name']}」 Statement 노드를 삭제합니다.'),
              const SizedBox(height: 12),
              const Text('함께 삭제되는 항목:', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              _ImpactRow(icon: Icons.share_outlined, label: '연결된 관계(엣지)', count: edgeCount),
              _ImpactRow(icon: Icons.bubble_chart_outlined, label: '고아 개념/화자 노드', count: orphanCount),
              _ImpactRow(icon: Icons.quiz_outlined, label: '생성된 퀴즈', count: quizCount),
              _ImpactRow(icon: Icons.translate_outlined, label: '추출된 언어 표현', count: exprCount),
              const SizedBox(height: 12),
              Text(
                '삭제된 항목은 휴지통에서 복구할 수 있습니다.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    try {
      if (isStatement) {
        final result = await apiClient.deleteNodeCascade(node['id'].toString());
        if (mounted) {
          final orphans = result['orphan_nodes_deleted'] ?? 0;
          final quizzes = result['quizzes_deleted'] ?? 0;
          final exprs = result['expressions_deleted'] ?? 0;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '삭제 완료 — 고아 노드 $orphans개, 퀴즈 $quizzes개, 표현 $exprs개 함께 삭제됨',
              ),
            ),
          );
        }
      } else {
        await apiClient.deleteNode(node['id'].toString());
      }
      widget.onClose?.call();
      widget.onUpdated?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('삭제 실패: $e')),
        );
      }
    }
  }

  Future<void> _saveEdge() async {
    final edge = widget.selectedEdge;
    final relation = _relationCtrl.text.trim();
    if (edge == null || relation.isEmpty) return;
    setState(() => _saving = true);
    try {
      await apiClient.updateEdge(edge['id'].toString(), relation: relation);
      widget.onUpdated?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _unlinkNodeVoice() async {
    final node = widget.selectedNode;
    if (node == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('목소리 임베딩 해제'),
        content: const Text(
          '이 노드에서 목소리 임베딩 연결을 제거합니다.\n'
          '잘못 매칭된 경우 일기에서 화자를 다시 확인할 수 있습니다.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('해제')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await apiClient.unlinkNodeVoice(node['id'].toString());
      widget.onUpdated?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('목소리 임베딩 연결이 해제되었습니다')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('해제 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteEdge() async {
    final edge = widget.selectedEdge;
    if (edge == null) return;
    try {
      await apiClient.deleteEdge(edge['id'].toString());
      widget.onClose?.call();
      widget.onUpdated?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('삭제 실패: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = widget.selectedNode;
    final edge = widget.selectedEdge;

    if (widget.isSheetMode) {
      return Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          top: false,
          child: ListView(
            controller: widget.scrollController,
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              16 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              _buildHeader(theme, node, edge),
              const Divider(height: 24),
              if (node != null) ..._nodeInspector(node, theme),
              if (edge != null && node == null) ..._edgeInspector(edge, theme),
            ],
          ),
        ),
      );
    }

    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        left: false,
        child: SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme, node, edge),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (node != null) ..._nodeInspector(node, theme),
                    if (edge != null && node == null) ..._edgeInspector(edge, theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, Map<String, dynamic>? node, Map<String, dynamic>? edge) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              node != null
                  ? nodeDisplayLabel(node)
                  : edge != null
                      ? '관계 상세'
                      : 'Inspector',
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: widget.onClose,
            tooltip: '닫기',
          ),
        ],
      ),
    );
  }

  bool _isChunkNode(Map<String, dynamic> node) {
    return canonicalEntityType(node['type']?.toString() ?? '').toLowerCase() == 'chunk';
  }

  String? _neighborChunkPreview(Map<String, dynamic> node, {required bool forward}) {
    final id = node['id'].toString();
    final rel = 'NEXT_TURN';
    for (final e in widget.edges) {
      if (forward && e['source_id'].toString() == id && e['relation'] == rel) {
        final n = widget.nodeById[e['target_id'].toString()];
        if (n != null) return nodeDisplayLabel(n);
      }
      if (!forward && e['target_id'].toString() == id && e['relation'] == rel) {
        final n = widget.nodeById[e['source_id'].toString()];
        if (n != null) return nodeDisplayLabel(n);
      }
    }
    return null;
  }

  List<Widget> _chunkReadOnlySection(Map<String, dynamic> node, ThemeData theme) {
    final speaker = node['speaker_name']?.toString() ?? '—';
    final text = node['text']?.toString() ?? node['description']?.toString() ?? '';
    final created = node['created_at']?.toString() ?? '';
    final prev = _neighborChunkPreview(node, forward: false);
    final next = _neighborChunkPreview(node, forward: true);

    return [
      Text('Chunk 발화', style: theme.textTheme.labelLarge?.copyWith(color: Colors.grey)),
      const SizedBox(height: 8),
      if (created.isNotEmpty)
        Text('생성: ${created.split('T').first}', style: theme.textTheme.bodySmall),
      const SizedBox(height: 6),
      Chip(
        avatar: const Icon(Icons.person, size: 16),
        label: Text(speaker),
        visualDensity: VisualDensity.compact,
      ),
      const SizedBox(height: 10),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          text.isNotEmpty ? '[$speaker] $text' : '(내용 없음)',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
      ),
      if (prev != null || next != null) ...[
        const SizedBox(height: 12),
        Text('대화 흐름 (NEXT_TURN)', style: theme.textTheme.labelMedium),
        if (prev != null) Text('← $prev', style: theme.textTheme.bodySmall),
        if (next != null) Text('→ $next', style: theme.textTheme.bodySmall),
      ],
      const SizedBox(height: 16),
      const Divider(),
      const SizedBox(height: 8),
    ];
  }

  bool _isIdentityCategoryType(String? raw) {
    final t = canonicalEntityType(raw ?? '').toLowerCase();
    return t == 'person' ||
        t == 'speaker' ||
        t == 'individual' ||
        t == 'source' ||
        t == 'identity';
  }

  /// Learned aliases (다른 명칭들) + fuzzy-embedding readiness for identity nodes —
  /// '나' 노드에 매칭한 '장세영' 같은 별칭이 여기 쌓이고, 임베딩 학습 여부를 보여준다.
  List<Widget> _aliasSection(Map<String, dynamic> node, ThemeData theme) {
    if (!_isIdentityCategoryType(node['type']?.toString())) return [];
    final aliases = ((node['aliases'] as List?) ?? [])
        .map((a) => a.toString().trim())
        .where((a) => a.isNotEmpty)
        .toList();
    final embCount = (node['alias_embedding_count'] as num?)?.toInt() ?? 0;
    if (aliases.isEmpty) {
      return [
        Row(
          children: [
            Icon(Icons.badge_outlined, size: 13, color: AppColors.textMuted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '학습된 별칭 없음 — 검토에서 다른 이름을 이 정체성에 연결하면 여기 쌓입니다.',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
      ];
    }
    return [
      Row(
        children: [
          Icon(Icons.badge_outlined, size: 13, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Text('별칭 (${aliases.length})',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const Spacer(),
          Icon(
            embCount > 0 ? Icons.auto_awesome : Icons.auto_awesome_outlined,
            size: 12,
            color: embCount > 0 ? const Color(0xFFB07BFF) : AppColors.textMuted,
          ),
          const SizedBox(width: 3),
          Text(
            embCount > 0 ? '임베딩 $embCount개 학습됨' : '임베딩 대기',
            style: TextStyle(
              fontSize: 11,
              color: embCount > 0 ? const Color(0xFFB07BFF) : AppColors.textMuted,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final a in aliases)
            Chip(
              label: Text(a, style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
        ],
      ),
      if (embCount < aliases.length) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _saving ? null : _reindexAliases,
            icon: const Icon(Icons.auto_awesome, size: 15),
            label: const Text('별칭 임베딩 생성', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
          ),
        ),
      ],
      const SizedBox(height: 10),
    ];
  }

  /// Backfill embeddings for aliases learned before the embedding index existed.
  Future<void> _reindexAliases() async {
    setState(() => _saving = true);
    try {
      final n = await apiClient.reindexAliasEmbeddings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('별칭 임베딩 $n개 생성됨')),
        );
      }
      widget.onUpdated?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 사후 교정 허브: Concept는 정체성 전환(in-place retype) 또는 기존 정체성·개념에
  /// 병합, 정체성 노드는 다른 정체성에 병합(중복 제거). 병합 시 관계·일기 연결이
  /// 대상으로 승계되고 이름이 별칭으로 학습돼 이후 추출이 자동 수렴한다.
  Future<void> _mergeOrConvert(Map<String, dynamic> node) async {
    final id = node['id'].toString();
    final name = node['name']?.toString() ?? '';
    final isConcept =
        canonicalEntityType(node['type']?.toString() ?? '').toLowerCase() ==
            'concept';

    // 병합 후보: 정체성 노드 우선, Concept 노드는 개념끼리 병합용으로 뒤에.
    final identityCands = widget.nodeById.values
        .where((n) =>
            n['id'].toString() != id &&
            _isIdentityCategoryType(n['type']?.toString()))
        .toList()
      ..sort((a, b) =>
          (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
    final conceptCands = isConcept
        ? (widget.nodeById.values
            .where((n) =>
                n['id'].toString() != id &&
                canonicalEntityType(n['type']?.toString() ?? '')
                        .toLowerCase() ==
                    'concept')
            .toList()
          ..sort((a, b) => (a['name'] ?? '')
              .toString()
              .compareTo((b['name'] ?? '').toString())))
        : const <Map<String, dynamic>>[];

    final choice = await showModalBottomSheet<Map<String, String?>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        var filter = '';
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            bool match(Map<String, dynamic> n) =>
                filter.isEmpty ||
                (n['name'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(filter.toLowerCase());
            final idents = identityCands.where(match).take(30).toList();
            final concepts = conceptCands.where(match).take(30).toList();
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(ctx).viewInsets.bottom),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                          isConcept
                              ? "'$name' 병합·정체성 전환"
                              : "'$name' 을(를) 다른 정체성에 병합",
                          style: Theme.of(ctx).textTheme.titleSmall),
                    ),
                    if (isConcept)
                      ListTile(
                        leading: const Icon(Icons.person_add_alt_1),
                        title: const Text('새 개체로 전환'),
                        subtitle: const Text(
                            '이 노드를 그대로 정체성(Identity) 타입으로 바꿉니다.'),
                        onTap: () => Navigator.pop(ctx, {'mergeInto': null}),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: TextField(
                        autofocus: false,
                        decoration: const InputDecoration(
                          hintText: '병합 대상 검색',
                          prefixIcon: Icon(Icons.search, size: 18),
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => setSheetState(() => filter = v),
                      ),
                    ),
                    if (idents.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                        child: Text('정체성에 병합 (관계·일기 연결·별칭 승계)',
                            style: Theme.of(ctx).textTheme.bodySmall),
                      ),
                      for (final p in idents)
                        ListTile(
                          dense: true,
                          leading: Icon(p['is_self'] == true
                              ? Icons.account_circle
                              : Icons.person_outline),
                          title: Text(p['is_self'] == true
                              ? '${p['name']} (본인)'
                              : (p['name'] ?? '').toString()),
                          subtitle: Text((p['type'] ?? '').toString(),
                              style: const TextStyle(fontSize: 11)),
                          onTap: () => Navigator.pop(
                              ctx, {'mergeInto': p['id'].toString()}),
                        ),
                    ],
                    if (concepts.isNotEmpty) ...[
                      const Divider(height: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Text('다른 개념에 병합 (중복 개념 정리)',
                            style: Theme.of(ctx).textTheme.bodySmall),
                      ),
                      for (final p in concepts)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.lightbulb_outline),
                          title: Text((p['name'] ?? '').toString()),
                          onTap: () => Navigator.pop(
                              ctx, {'mergeInto': p['id'].toString()}),
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (choice == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final mergeInto = choice['mergeInto'];
      await apiClient.reclassifyNode(id,
          toType: 'Identity', mergeInto: mergeInto);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(mergeInto == null
                ? "'$name' 을(를) 정체성 노드로 전환했습니다."
                : "'$name' 을(를) 병합했습니다 — 관계·일기 연결이 승계되었습니다."),
          ),
        );
      }
      if (mergeInto != null) widget.onClose?.call();
      widget.onUpdated?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Widget> _nodeInspector(Map<String, dynamic> node, ThemeData theme) {
    final chunkSection =
        _isChunkNode(node) ? _chunkReadOnlySection(node, theme) : <Widget>[];
    final id = node['id'].toString();
    final locked = node['source_entry_id'] != null;
    final color = colorForType(_type ?? node['type']?.toString() ?? '', widget.typeColors);
    final outgoing = widget.edges.where((e) => e['source_id'].toString() == id).toList();
    final incoming = widget.edges.where((e) => e['target_id'].toString() == id).toList();

    return [
      ...chunkSection,
      Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text('노드', style: theme.textTheme.labelLarge?.copyWith(color: Colors.grey)),
        ],
      ),
      if (locked) ...[
        const SizedBox(height: 10),
        _LockedNotice(),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _nameCtrl,
        decoration: const InputDecoration(labelText: '이름', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        value: _selectedTypeValue(),
        decoration: const InputDecoration(labelText: '타입', border: OutlineInputBorder(), isDense: true),
        items: _typeDropdownItems(),
        onChanged: (v) => setState(() => _type = v),
      ),
      const SizedBox(height: 10),
      ..._aliasSection(node, theme),
      if (_isStatementNode(node)) ...[
        Row(
          children: [
            Icon(Icons.category_outlined, size: 13, color: AppColors.textMuted),
            const SizedBox(width: 4),
            Text('소스 유형: ', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
            Chip(
              label: Text(
                _stmtCtxType(node),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
          ],
        ),
        const SizedBox(height: 6),
      ],
      TextField(
        controller: _descCtrl,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: _isStatementNode(node) ? '본문 내용 (정제)' : '설명',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      _sourceTranscriptWidget(node),
      if (((node['importance_score'] as num?)?.toInt() ?? 0) > 0) ...[
        const SizedBox(height: 12),
        _ImportanceCard(score: (node['importance_score'] as num).toInt()),
      ],
      const SizedBox(height: 14),
      _EmbeddingStatusCard(
        node: node,
        onUnlinkVoice: node['voice_embedding_registered'] == true ? _unlinkNodeVoice : null,
      ),
      if (_isStatementNode(node)) ...[
        const SizedBox(height: 10),
        _NodeExpressionButton(nodeId: id, nodeName: node['name']?.toString() ?? ''),
      ],
      // 병합·전환: 잘못 추출된 노드를 사후 교정하는 허브. Concept는 정체성 전환/
      // 정체성·개념 병합, 정체성은 다른 정체성에 병합(중복 제거). 병합 시 관계와
      // 일기 연결(provenance)이 대상 노드로 승계되고 별칭으로 학습된다.
      if (!_isStatementNode(node) && !_isChunkNode(node)) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _saving ? null : () => _mergeOrConvert(node),
          icon: const Icon(Icons.merge_type, size: 18),
          label: Text(
            canonicalEntityType(node['type']?.toString() ?? '').toLowerCase() ==
                    'concept'
                ? '병합·정체성 전환'
                : '다른 정체성에 병합',
          ),
        ),
      ],
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: _saving ? null : _saveNode,
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('저장'),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            onPressed: _deleteNode,
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            tooltip: '삭제',
          ),
        ],
      ),
      const SizedBox(height: 20),
      Text('관계 (${outgoing.length + incoming.length})', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      ...outgoing.map((e) => _RelationTile(
            label: '${e['relation']} → ${widget.nodeById[e['target_id'].toString()]?['name'] ?? '?'}',
            onTap: () => widget.onSelectEdge?.call(e),
          )),
      ...incoming.map((e) => _RelationTile(
            label: '${widget.nodeById[e['source_id'].toString()]?['name'] ?? '?'} → ${e['relation']}',
            onTap: () => widget.onSelectEdge?.call(e),
          )),
      const SizedBox(height: 16),
      Builder(builder: (context) {
        final recorded = (node['occurred_at'] ?? node['entry_created_at'] ?? node['created_at'])
            ?.toString()
            .split('T')
            .first;
        if (recorded == null || recorded.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('기록일: $recorded',
              style: TextStyle(fontSize: 11, color: context.mutedText)),
        );
      }),
      Text(
        'ID: ${id.substring(0, 8)}… · ${node['created_at']?.toString().split('T').first ?? ''}',
        style: TextStyle(fontSize: 10, color: Colors.grey[600], fontFamily: 'monospace'),
      ),
      const SizedBox(height: 8),
      Text(
        '저장: PostgreSQL nodes 테이블\nGraphRAG 배치 시 upsert',
        style: TextStyle(fontSize: 10, color: Colors.grey[600], fontFamily: 'monospace'),
      ),
    ];
  }

  List<Widget> _edgeInspector(Map<String, dynamic> edge, ThemeData theme) {
    final src = widget.nodeById[edge['source_id'].toString()];
    final tgt = widget.nodeById[edge['target_id'].toString()];
    final locked =
        (src?['source_entry_id'] != null) || (tgt?['source_entry_id'] != null);
    final suggestions = _relationSuggestions(_relationCtrl.text);

    return [
      Text('관계 (Edge)', style: theme.textTheme.labelLarge?.copyWith(color: Colors.grey)),
      if (locked) ...[
        const SizedBox(height: 10),
        _LockedNotice(),
      ],
      const SizedBox(height: 12),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(src?['name']?.toString() ?? '?'),
        subtitle: const Text('source'),
        trailing: const Icon(Icons.arrow_forward),
        onTap: src != null ? () => widget.onSelectNode?.call(src) : null,
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tgt?['name']?.toString() ?? '?'),
        subtitle: const Text('target'),
        onTap: tgt != null ? () => widget.onSelectNode?.call(tgt) : null,
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _relationCtrl,
        decoration: const InputDecoration(
          labelText: 'Relation (open-domain)',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      if (suggestions.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: suggestions.take(8).map((r) {
            return ActionChip(
              label: Text(r, style: const TextStyle(fontSize: 11)),
              onPressed: () => setState(() => _relationCtrl.text = r),
            );
          }).toList(),
        ),
      ],
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: FilledButton(onPressed: _saving ? null : _saveEdge, child: const Text('저장')),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            onPressed: _deleteEdge,
            icon: const Icon(Icons.delete_outline, color: Colors.red),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        '저장: PostgreSQL edges 테이블',
        style: TextStyle(fontSize: 10, color: Colors.grey[600], fontFamily: 'monospace'),
      ),
    ];
  }
}

class _LockedNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_edu, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '일기에서 생성된 그래프입니다. 여기서 수정하면 바로 반영되고, 일기 연결(원문 추적)은 유지됩니다.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cumulative LLM-assigned importance (Node.importance_score). Each time the
/// concept is mentioned, its 1-5 score adds up — recurring themes weigh more.
/// This is what drives the bolder label in the graph canvas.
class _ImportanceCard extends StatelessWidget {
  const _ImportanceCard({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    // Roughly map cumulative score → 1-5 pips (each mention adds up to 5).
    final pips = ((score + 4) ~/ 5).clamp(1, 5);
    final accent = Colors.deepOrange.shade400;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.deepOrange.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          Icon(Icons.local_fire_department_outlined, size: 18, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '누적 중요도',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: Colors.deepOrange.shade700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    for (var i = 0; i < 5; i++)
                      Icon(
                        i < pips ? Icons.circle : Icons.circle_outlined,
                        size: 9,
                        color: i < pips ? accent : Colors.grey.shade400,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      '언급마다 1~5점 누적',
                      style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Text(
            '$score',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Colors.deepOrange.shade600,
            ),
          ),
          const SizedBox(width: 2),
          Text('점', style: TextStyle(fontSize: 12, color: Colors.deepOrange.shade600)),
        ],
      ),
    );
  }
}

class _EmbeddingStatusCard extends StatelessWidget {
  const _EmbeddingStatusCard({
    required this.node,
    this.onUnlinkVoice,
  });

  final Map<String, dynamic> node;
  final VoidCallback? onUnlinkVoice;

  @override
  Widget build(BuildContext context) {
    final voiceOk = node['voice_embedding_registered'] == true;
    final aliasEmbCount =
        (node['alias_embedding_count'] as num?)?.toInt() ?? 0;
    final label = node['voice_profile_label']?.toString();
    final samples = node['voice_sample_count'];
    final duration = (node['voice_total_duration_sec'] as num?)?.toDouble() ?? 0.0;
    final isSpeakerLike = isSpeakerLikeType(node['type']?.toString());

    return Card(
      color: Colors.blueGrey.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory, size: 18, color: Colors.blueGrey[700]),
                const SizedBox(width: 8),
                Text(
                  '임베딩 · 음성 메모리',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Colors.blueGrey[800],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _StatusRow(
              icon: Icons.mic,
              label: '목소리 임베딩',
              ok: voiceOk,
              detail: voiceOk
                  ? '${label ?? '프로필'} · 샘플 $samples회 · ${duration.toStringAsFixed(1)}초'
                  : isSpeakerLike
                      ? '미등록 — 일기 녹음 후 화자 확인 시 등록됩니다'
                      : 'Speaker 노드가 아니거나 아직 음성 샘플 없음',
            ),
            const SizedBox(height: 8),
            _StatusRow(
              icon: Icons.auto_awesome,
              label: '별칭 임베딩 (유사 매칭)',
              ok: aliasEmbCount > 0,
              detail: aliasEmbCount > 0
                  ? '$aliasEmbCount개 학습됨 — 이름이 달라도 유사하면 자동 제안'
                  : '아직 없음 — 이 정체성에 다른 이름을 연결하면 학습됩니다',
            ),
            if (voiceOk && onUnlinkVoice != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onUnlinkVoice,
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('목소리 임베딩 해제'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.label,
    required this.ok,
    required this.detail,
  });

  final IconData icon;
  final String label;
  final bool ok;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 18,
          color: ok ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              Text(
                detail,
                style: TextStyle(fontSize: 11, color: Colors.grey[700], height: 1.3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Expandable section showing the original raw transcript linked to this node.
class _SourceTranscriptSection extends StatefulWidget {
  const _SourceTranscriptSection({required this.raw, this.label});
  final String raw;
  final String? label;

  @override
  State<_SourceTranscriptSection> createState() => _SourceTranscriptSectionState();
}

class _SourceTranscriptSectionState extends State<_SourceTranscriptSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.label ?? '원문 (음성/텍스트 원본)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Colors.grey[600],
                ),
                const SizedBox(width: 4),
                Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.25)),
            ),
            child: SelectableText(
              widget.raw,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
      ],
    );
  }
}

/// Button that shows extracted learning expressions for a Statement node.
class _NodeExpressionButton extends StatefulWidget {
  const _NodeExpressionButton({required this.nodeId, required this.nodeName});

  final String nodeId;
  final String nodeName;

  @override
  State<_NodeExpressionButton> createState() => _NodeExpressionButtonState();
}

class _NodeExpressionButtonState extends State<_NodeExpressionButton> {
  bool _loading = false;

  Future<void> _showExpressions() async {
    setState(() => _loading = true);
    Map<String, dynamic>? data;
    String? error;
    try {
      data = await apiClient.getNodeExpressions(widget.nodeId);
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }

    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    // Filter out non-language metadata keys (e.g. "node_name") — only keep List values
    final raw = data?['expressions_by_language'] as Map? ?? {};
    final byLang = Map.fromEntries(
      raw.entries.where((e) => e.value is List),
    );
    if (byLang.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('아직 추출된 표현이 없습니다. 추출 작업이 완료된 후 다시 확인해 주세요.')),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ExpressionsBottomSheet(
        nodeName: widget.nodeName,
        byLang: Map<String, dynamic>.from(byLang),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _loading ? null : _showExpressions,
      icon: _loading
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.translate, size: 18),
      label: const Text('학습 표현 보기'),
    );
  }
}

const _kLangLabelMap = {
  'english':    '영어',
  'japanese':   '일본어',
  'chinese':    '중국어',
  'spanish':    '스페인어',
  'french':     '프랑스어',
  'german':     '독일어',
  'portuguese': '포르투갈어',
  'italian':    '이탈리아어',
  'arabic':     '아랍어',
  'russian':    '러시아어',
};

class _ExpressionsBottomSheet extends StatefulWidget {
  const _ExpressionsBottomSheet({required this.nodeName, required this.byLang});

  final String nodeName;
  final Map<String, dynamic> byLang;

  @override
  State<_ExpressionsBottomSheet> createState() => _ExpressionsBottomSheetState();
}

class _ExpressionsBottomSheetState extends State<_ExpressionsBottomSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  late List<String> _langs;

  @override
  void initState() {
    super.initState();
    _langs = widget.byLang.keys.toList();
    _tabs = TabController(length: _langs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      maxChildSize: 0.92,
      builder: (ctx, scrollCtrl) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.translate, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.nodeName,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (_langs.length > 1)
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: _langs.map((l) => Tab(text: _kLangLabelMap[l] ?? l)).toList(),
              ),
            const Divider(height: 1),
            Expanded(
              child: _langs.length == 1
                  ? _ExpressionList(
                      items: List<Map>.from(widget.byLang[_langs[0]] ?? []),
                    )
                  : TabBarView(
                      controller: _tabs,
                      children: _langs.map((l) => _ExpressionList(
                        items: List<Map>.from(widget.byLang[l] ?? []),
                      )).toList(),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _ExpressionList extends StatelessWidget {
  const _ExpressionList({required this.items});

  final List<Map> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('아직 추출된 표현이 없습니다'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final item = items[i];
        final expr = item['expression']?.toString() ?? '';
        final meaning = item['meaning']?.toString() ?? '';
        final example = item['example']?.toString() ?? '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                expr,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
              if (meaning.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  meaning,
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
              ],
              if (example.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  example,
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Colors.blueGrey[600],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RelationTile extends StatelessWidget {
  const _RelationTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
              Icon(Icons.chevron_right, size: 18, color: Colors.grey[500]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImpactRow extends StatelessWidget {
  const _ImpactRow({required this.icon, required this.label, required this.count});

  final IconData icon;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Expanded(child: Text('• $label', style: const TextStyle(fontSize: 13))),
          Text(
            '$count개',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: count > 0 ? Colors.red.shade700 : Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }
}
