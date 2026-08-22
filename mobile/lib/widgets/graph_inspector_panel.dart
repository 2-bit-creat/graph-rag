import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';

/// "7월 2일 (목)" — the same date vocabulary the timeline and review panel use.
String _inspectorDayLabel(DateTime d) => tr('timeline.dayPanelDateLabel', {
      'month': d.month,
      'day': d.day,
      'weekday': [
        tr('timeline.weekdayMon'),
        tr('timeline.weekdayTue'),
        tr('timeline.weekdayWed'),
        tr('timeline.weekdayThu'),
        tr('timeline.weekdayFri'),
        tr('timeline.weekdaySat'),
        tr('timeline.weekdaySun'),
      ][d.weekday - 1],
    });

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
  bool _editing = false;
  bool _showRelations = false;
  bool _showMore = false;

  /// Content/type as loaded, so _saveNode can tell whether the user actually
  /// changed a Statement's content before saving — the backend only wipes
  /// and regenerates quizzes/expressions when the content text itself
  /// differs, or the node leaves the Statement type (see graph.py's
  /// `changed` check), and the user should see that coming, not discover it
  /// after the fact. Name and context_type are never compared here: neither
  /// feeds quiz/expression generation, so editing only those never wipes
  /// anything on the backend either.
  String? _originalContent;
  String? _originalType;

  /// Statement source/context type while editing — a free dropdown, not a
  /// read-only Chip. Stored inside the same `description` JSON as `content`
  /// (see _buildStmtDescription), but read separately from content on the
  /// backend's regeneration check, so editing only this never wipes quizzes.
  String? _ctxType;

  static const List<String> _statementContextTypes = [
    '개인일기',
    '대화',
    '회의록',
    '책',
    '뉴스',
    '강연',
    '논문',
  ];

  /// Event day currently shown for a Statement, and the value it was loaded
  /// with. Only a real change is sent, so editing the text of a statement whose
  /// date was inferred never silently promotes that guess to a confirmed date.
  DateTime? _occurredAt;
  DateTime? _loadedOccurredAt;

  /// Advanced/diagnostic groups start collapsed — every control stays reachable,
  /// but the panel opens on the fields that describe the node rather than on
  /// embedding status and ids.
  bool _showAdvanced = false;
  bool _showDebug = false;

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
        return (map['context_type'] as String? ?? tr('inspector.uncategorized'))
            .trim();
      } catch (_) {}
    }
    return desc.split('\n').first.trim().isEmpty
        ? tr('inspector.uncategorized')
        : desc.split('\n').first.trim();
  }

  String _buildStmtDescription(String contextType, String content) =>
      jsonEncode({'context_type': contextType, 'content': content});

  bool _isStatementNode(Map<String, dynamic>? node) =>
      (node?['type'] as String? ?? '').toLowerCase() == 'statement';

  // ── Event date ─────────────────────────────────────────────────────────────

  /// When the statement's event happened. Falls back to the source entry's
  /// writing time, then node creation, mirroring how the server resolves it.
  DateTime? _nodeEventDate(Map<String, dynamic> node) {
    final raw =
        (node['occurred_at'] ?? node['entry_created_at'] ?? node['created_at'])
            ?.toString();
    if (raw == null || raw.isEmpty) return null;
    final parsed =
        DateTime.tryParse(raw.length > 10 ? raw.substring(0, 10) : raw);
    return parsed == null
        ? null
        : DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// True while the stored day is only the day the entry was written — nothing
  /// in the text said when it happened, so it is worth marking as unconfirmed.
  bool _dateIsGuessed(Map<String, dynamic> node) =>
      (node['temporal_precision']?.toString() ?? '') == 'recorded_date' &&
      _occurredAt == _loadedOccurredAt;

  bool _dateIsConfirmed(Map<String, dynamic> node) =>
      (node['temporal_precision']?.toString() ?? '') == 'user_set';

  Future<void> _pickEventDate() async {
    final now = DateTime.now();
    final initial = _occurredAt ?? DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(initial.year - 5),
      lastDate: DateTime(now.year, now.month, now.day),
      helpText: tr('reviewDate.pickerHelp'),
    );
    if (picked == null || !mounted) return;
    setState(
        () => _occurredAt = DateTime(picked.year, picked.month, picked.day));
  }

  /// The date, stated plainly and editable in place — it is a primary fact
  /// about a journal statement, not a diagnostic detail.
  Widget _eventDateField(Map<String, dynamic> node, ThemeData theme) {
    final date = _occurredAt;
    if (date == null) return const SizedBox.shrink();
    final guessed = _dateIsGuessed(node);
    final dirty = _occurredAt != _loadedOccurredAt;
    final tone = guessed
        ? AppColors.accentWarm
        : (dirty || _dateIsConfirmed(node))
            ? AppColors.hubGraph
            : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: _pickEventDate,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tone.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.event_outlined, size: 17, color: tone),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _inspectorDayLabel(date),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: tone,
                        ),
                      ),
                      if (guessed || dirty) ...[
                        const SizedBox(height: 2),
                        Text(
                          dirty
                              ? tr('inspector.eventDateUnsaved')
                              : tr('inspector.eventDateGuessed'),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: tone.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.edit_calendar_outlined, size: 16, color: tone),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sourceTranscriptWidget(Map<String, dynamic> node) {
    final raw = node['source_transcript_ko'] as String? ?? '';
    final clean = node['source_transcript_clean_ko'] as String? ?? '';
    if (raw.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _SourceTranscriptSection(
            raw: raw, label: tr('inspector.sourceRawLabel')),
      );
    }
    if (clean.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _SourceTranscriptSection(
            raw: clean, label: tr('inspector.sourceFullLabel')),
      );
    }
    return const SizedBox.shrink();
  }

  // ── Field sync ─────────────────────────────────────────────────────────────

  /// Which node/edge the fields below currently hold, so a rebuild that changes
  /// neither can leave them alone.
  ///
  /// [_syncFields] used to run unconditionally from [didUpdateWidget], and it
  /// ends with `_editing = false` plus a full overwrite of every controller.
  /// The graph screen rebuilds constantly — chat listeners, journal polling,
  /// canvas frames — so pressing "수정" put the panel into edit mode only for
  /// the next incidental rebuild to throw it straight back out, taking any
  /// half-typed name with it. That is the header flickering between 수정 and
  /// 취소 with the form appearing and vanishing.
  String? _syncedNodeId;
  String? _syncedEdgeId;

  /// Re-read the server's values on the next rebuild even if the id is
  /// unchanged — used after a save, where the response is the new truth.
  void _invalidateSync() {
    _syncedNodeId = null;
    _syncedEdgeId = null;
  }

  void _syncFields() {
    final nodeId = widget.selectedNode?['id']?.toString();
    final edgeId = widget.selectedEdge?['id']?.toString();
    // Same selection as last time: the fields are already right, and the user
    // may be typing into them.
    if (nodeId == _syncedNodeId && edgeId == _syncedEdgeId) return;
    _syncedNodeId = nodeId;
    _syncedEdgeId = edgeId;

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
      _ctxType = _isStatementNode(node) ? _stmtCtxType(node) : null;
      _originalContent = _descCtrl.text;
      _originalType = _type;
      _occurredAt = _nodeEventDate(node);
      _loadedOccurredAt = _occurredAt;
      _showAdvanced = false;
      _showDebug = false;
      _editing = false;
      _showRelations = false;
      _showMore = false;
    }
    final edge = widget.selectedEdge;
    if (edge != null) {
      _relationCtrl.text = edge['relation']?.toString() ?? '';
      _editing = false;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _relationCtrl.dispose();
    super.dispose();
  }

  /// Statements this node currently heads. Demoting it out of the identity
  /// category reverses those edges into `Statement --CONTEXT--> node`, which
  /// destroys "who said it" — nothing else in the schema records the head.
  int _spokenStatementCount(Map<String, dynamic> node) {
    final id = node['id'].toString();
    return widget.edges
        .where((e) =>
            e['source_id'].toString() == id &&
            e['relation']?.toString() == 'SPOKE_OR_PUBLISHED')
        .length;
  }

  /// Warn before an irreversible identity → non-identity retype. Warn, don't
  /// refuse: the KG screen is the after-the-fact correction hub.
  Future<bool> _confirmHeadDemotion(Map<String, dynamic> node) async {
    final wasIdentity = _isIdentityCategoryType(node['type']?.toString());
    if (!wasIdentity || _isIdentityCategoryType(_type)) return true;
    final count = _spokenStatementCount(node);
    if (count == 0) return true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('inspector.demoteHeadTitle')),
        content: Text(tr('inspector.demoteHeadBody', {'count': count})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('inspector.demoteHeadConfirm')),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Warn before a Statement edit that the backend will treat as an actual
  /// content change: it retires every quiz and expression derived from this
  /// node and regenerates them from scratch (graph.py's `changed` gate,
  /// which — like this check — only looks at the statement's content text
  /// and whether it's leaving the Statement type; quiz/expression generation
  /// never reads name or context_type, so editing only those no longer wipes
  /// anything on either side). A no-op save (open, don't touch anything,
  /// press 저장) never hits this — only a real content/type difference does.
  Future<bool> _confirmContentRegeneration(Map<String, dynamic> node) async {
    if (!_isStatementNode(node)) return true;
    final contentChanged = _descCtrl.text.trim() != (_originalContent ?? '').trim();
    final typeChanged = _type != _originalType;
    if (!contentChanged && !typeChanged) return true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('inspector.confirmRegenerateTitle')),
        content: Text(tr('inspector.confirmRegenerateBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('inspector.confirmRegenerateConfirm')),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _saveNode() async {
    final node = widget.selectedNode;
    if (node == null || _type == null) return;
    if (!await _confirmHeadDemotion(node)) return;
    if (!mounted) return;
    if (!await _confirmContentRegeneration(node)) return;
    if (!mounted) return;
    setState(() => _saving = true);

    // For Statement nodes: user edits the content text, we re-wrap in JSON
    String? descToSave;
    final contentText = _descCtrl.text.trim();
    if (_isStatementNode(node) && contentText.isNotEmpty) {
      final ctxType = _ctxType ?? _stmtCtxType(node);
      descToSave = _buildStmtDescription(ctxType, contentText);
    } else {
      descToSave = contentText.isEmpty ? null : contentText;
    }

    try {
      final saved = await apiClient.updateNode(
        node['id'].toString(),
        name: _nameCtrl.text.trim(),
        type: _type!,
        description: descToSave,
        // Only when actually changed — otherwise saving a text edit would stamp
        // an inferred date as user-confirmed without the user ever saying so.
        occurredAt: (_occurredAt != null && _occurredAt != _loadedOccurredAt)
            ? _isoDay(_occurredAt!)
            : null,
      );
      _loadedOccurredAt = _occurredAt;
      // The save response is the new truth (the server may normalize the name
      // or realign the type), so let the reload it triggers re-seed the fields
      // even though the node id has not changed.
      _invalidateSync();
      widget.onUpdated?.call();
      if (mounted) {
        // A successful save drops back to read mode.
        setState(() => _editing = false);
        // Say so when the type change rewrote relations. Silently fixing what
        // used to silently break is only half the fix.
        final realigned = (saved[kEdgesRealignedKey] as int?) ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(realigned > 0
                ? tr('inspector.nodeSavedWithEdges', {'count': realigned})
                : tr('inspector.nodeSaved')),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('inspector.saveFailed', {'error': e}))),
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
            title: Text(tr('inspector.deleteNodeTitle')),
            content: Text(
                tr('inspector.deleteNodeSimpleBody', {'name': node['name']})),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('common.cancel'))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr('common.delete'))),
            ],
          );
        }
        final edgeCount = impact['edge_count'] as int? ?? 0;
        final orphanCount = impact['orphan_node_count'] as int? ?? 0;
        final quizCount = impact['quiz_count'] as int? ?? 0;
        final exprCount = impact['expression_count'] as int? ?? 0;
        return AlertDialog(
          title: Text(tr('inspector.deleteNodeTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('inspector.deleteStatementBody', {'name': node['name']})),
              const SizedBox(height: 12),
              Text(tr('inspector.alsoDeletedLabel'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              _ImpactRow(
                  icon: Icons.share_outlined,
                  label: tr('inspector.relatedEdges'),
                  count: edgeCount),
              _ImpactRow(
                  icon: Icons.bubble_chart_outlined,
                  label: tr('inspector.orphanNodes'),
                  count: orphanCount),
              _ImpactRow(
                  icon: Icons.quiz_outlined,
                  label: tr('inspector.generatedQuizzes'),
                  count: quizCount),
              _ImpactRow(
                  icon: Icons.translate_outlined,
                  label: tr('inspector.extractedExpressions'),
                  count: exprCount),
              const SizedBox(height: 12),
              Text(
                tr('inspector.restoreFromTrashNote'),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('common.cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('common.delete')),
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
                tr('inspector.deleteCompleteSnackbar', {
                  'orphans': orphans,
                  'quizzes': quizzes,
                  'exprs': exprs,
                }),
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
          SnackBar(content: Text(tr('inspector.deleteFailed', {'error': e}))),
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
          SnackBar(content: Text(tr('inspector.saveFailed', {'error': e}))),
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
        title: Text(tr('inspector.unlinkVoiceTitle')),
        content: Text(tr('inspector.unlinkVoiceBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('inspector.unlinkAction'))),
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
          SnackBar(content: Text(tr('inspector.voiceUnlinkedSnackbar'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('inspector.unlinkFailed', {'error': e}))),
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
          SnackBar(content: Text(tr('inspector.deleteFailed', {'error': e}))),
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
                    if (edge != null && node == null)
                      ..._edgeInspector(edge, theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
      ThemeData theme, Map<String, dynamic>? node, Map<String, dynamic>? edge) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
      child: Row(
        children: [
          if (edge != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: tr('inspector.backToNode'),
              onPressed: () {
                final source = widget.nodeById[edge['source_id'].toString()];
                if (source != null) widget.onSelectNode?.call(source);
              },
            ),
          Expanded(
            child: Text(
              node != null
                  ? tr('inspector.nodeDetailTitle')
                  : edge != null
                      ? tr('inspector.relationDetailTitle')
                      : 'Inspector',
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if ((node != null && !_isChunkNode(node)) || edge != null)
            TextButton(
              onPressed: _saving
                  ? null
                  : () {
                      if (_editing) {
                        setState(_syncFields);
                      } else {
                        setState(() => _editing = true);
                      }
                    },
              child: Text(_editing
                  ? tr('inspector.cancelEditAction')
                  : tr('inspector.editAction')),
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: widget.onClose,
            tooltip: tr('common.close'),
          ),
        ],
      ),
    );
  }

  bool _isChunkNode(Map<String, dynamic> node) {
    return canonicalEntityType(node['type']?.toString() ?? '').toLowerCase() ==
        'chunk';
  }

  String? _neighborChunkPreview(Map<String, dynamic> node,
      {required bool forward}) {
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

  List<Widget> _chunkReadOnlySection(
      Map<String, dynamic> node, ThemeData theme) {
    final speaker = node['speaker_name']?.toString() ?? '—';
    final text =
        node['text']?.toString() ?? node['description']?.toString() ?? '';
    final created = node['created_at']?.toString() ?? '';
    final prev = _neighborChunkPreview(node, forward: false);
    final next = _neighborChunkPreview(node, forward: true);

    return [
      Text(tr('inspector.chunkUtterance'),
          style: theme.textTheme.labelLarge?.copyWith(color: Colors.grey)),
      const SizedBox(height: 8),
      if (created.isNotEmpty)
        Text(tr('inspector.createdLabel', {'date': created.split('T').first}),
            style: theme.textTheme.bodySmall),
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
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          text.isNotEmpty ? '[$speaker] $text' : tr('inspector.noContent'),
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
      ),
      if (prev != null || next != null) ...[
        const SizedBox(height: 12),
        Text(tr('inspector.conversationFlow'),
            style: theme.textTheme.labelMedium),
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
                tr('inspector.noLearnedAliases'),
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
          Text(tr('inspector.aliasesCount', {'count': aliases.length}),
              style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const Spacer(),
          Icon(
            embCount > 0 ? Icons.scatter_plot : Icons.scatter_plot_outlined,
            size: 12,
            color: embCount > 0 ? const Color(0xFFB07BFF) : AppColors.textMuted,
          ),
          const SizedBox(width: 3),
          Text(
            embCount > 0
                ? tr('inspector.embeddingsLearnedCount', {'count': embCount})
                : tr('inspector.embeddingPending'),
            style: TextStyle(
              fontSize: 11,
              color:
                  embCount > 0 ? const Color(0xFFB07BFF) : AppColors.textMuted,
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
            icon: const Icon(Icons.sync_rounded, size: 15),
            label: Text(tr('inspector.generateAliasEmbedding'),
                style: const TextStyle(fontSize: 12)),
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
          SnackBar(
              content:
                  Text(tr('inspector.aliasEmbeddingsGenerated', {'count': n}))),
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
                              ? tr(
                                  'inspector.mergeConvertTitle', {'name': name})
                              : tr('inspector.mergeIntoOtherTitle',
                                  {'name': name}),
                          style: Theme.of(ctx).textTheme.titleSmall),
                    ),
                    if (isConcept)
                      ListTile(
                        leading: const Icon(Icons.person_add_alt_1),
                        title: Text(tr('inspector.convertToNewEntity')),
                        subtitle:
                            Text(tr('inspector.convertToNewEntitySubtitle')),
                        onTap: () => Navigator.pop(ctx, {'mergeInto': null}),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: TextField(
                        autofocus: false,
                        decoration: InputDecoration(
                          hintText: tr('inspector.mergeSearchHint'),
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
                        child: Text(tr('inspector.mergeIntoIdentity'),
                            style: Theme.of(ctx).textTheme.bodySmall),
                      ),
                      for (final p in idents)
                        ListTile(
                          dense: true,
                          leading: Icon(p['is_self'] == true
                              ? Icons.account_circle
                              : Icons.person_outline),
                          title: Text(p['is_self'] == true
                              ? tr(
                                  'graphReview.selfSuffix', {'name': p['name']})
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
                        child: Text(tr('inspector.mergeIntoConcept'),
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
                ? tr('inspector.convertedToIdentitySnackbar', {'name': name})
                : tr('inspector.mergedSnackbar', {'name': name})),
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
    final color = colorForType(
        _type ?? node['type']?.toString() ?? '', widget.typeColors);
    final outgoing =
        widget.edges.where((e) => e['source_id'].toString() == id).toList();
    final incoming =
        widget.edges.where((e) => e['target_id'].toString() == id).toList();

    if (!_editing && !_isChunkNode(node)) {
      return _nodeReadInspector(
        node,
        theme,
        color: color,
        outgoing: outgoing,
        incoming: incoming,
        locked: locked,
      );
    }

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
          Text(tr('inspector.nodeLabel'),
              style: theme.textTheme.labelLarge?.copyWith(color: Colors.grey)),
        ],
      ),
      if (locked) ...[
        const SizedBox(height: 10),
        _LockedNotice(),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _nameCtrl,
        decoration: InputDecoration(
            labelText: tr('sidebar.nameLabel'),
            border: const OutlineInputBorder(),
            isDense: true),
      ),
      const SizedBox(height: 10),
      // When a statement happened is a primary fact in a journal, so it sits
      // with the name rather than in the diagnostic footer it used to share
      // with the node id.
      if (_isStatementNode(node)) _eventDateField(node, theme),
      // Type and (for a Statement) source type are both short classification
      // pickers, not primary content — pairing them side by side keeps the
      // form from reading as one long undifferentiated stack of fields.
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _selectedTypeValue(),
              decoration: InputDecoration(
                  labelText: tr('inspector.typeLabel'),
                  prefixIcon: const Icon(Icons.label_outline, size: 18),
                  border: const OutlineInputBorder(),
                  isDense: true),
              items: _typeDropdownItems(),
              onChanged: (v) => setState(() => _type = v),
            ),
          ),
          if (_isStatementNode(node)) ...[
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _statementContextTypes.contains(_ctxType)
                    ? _ctxType
                    : null,
                decoration: InputDecoration(
                    labelText: tr('inspector.sourceTypeLabel'),
                    prefixIcon:
                        const Icon(Icons.category_outlined, size: 18),
                    border: const OutlineInputBorder(),
                    isDense: true),
                items: [
                  for (final option in _statementContextTypes)
                    DropdownMenuItem(value: option, child: Text(option)),
                ],
                onChanged: (v) => setState(() => _ctxType = v),
              ),
            ),
          ],
        ],
      ),
      // Extra breathing room before the body text — it is the one field that
      // actually matters most here, not just another row of metadata.
      const SizedBox(height: 18),
      TextField(
        controller: _descCtrl,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: _isStatementNode(node)
              ? tr('inspector.statementContentLabel')
              : tr('inspector.descriptionLabel'),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      _sourceTranscriptWidget(node),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: _saving ? null : _saveNode,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('common.save')),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            onPressed: _deleteNode,
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            tooltip: tr('common.delete'),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Text(
          tr('inspector.relationsCount',
              {'count': outgoing.length + incoming.length}),
          style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      ...outgoing.map((e) => _RelationTile(
            label:
                '${e['relation']} → ${widget.nodeById[e['target_id'].toString()]?['name'] ?? '?'}',
            onTap: () => widget.onSelectEdge?.call(e),
          )),
      ...incoming.map((e) => _RelationTile(
            label:
                '${widget.nodeById[e['source_id'].toString()]?['name'] ?? '?'} → ${e['relation']}',
            onTap: () => widget.onSelectEdge?.call(e),
          )),
      const SizedBox(height: 16),

      // Everything below is either rarely needed or purely diagnostic. It all
      // stays available — just folded away so the panel opens on what the node
      // actually says.
      _disclosureHeader(
        theme,
        label: tr('inspector.advancedSection'),
        expanded: _showAdvanced,
        onTap: () => setState(() => _showAdvanced = !_showAdvanced),
      ),
      if (_showAdvanced) ...[
        const SizedBox(height: 10),
        ..._aliasSection(node, theme),
        if (((node['importance_score'] as num?)?.toInt() ?? 0) > 0) ...[
          _ImportanceCard(score: (node['importance_score'] as num).toInt()),
          const SizedBox(height: 12),
        ],
        // Voice/alias embeddings only ever exist on identity-category nodes
        // (see backend crud.index_identity_alias) — showing this card for a
        // Statement/Concept just displayed two permanently-"없음" rows with no
        // path to fix them.
        if (_isIdentityCategoryType(node['type']?.toString()))
          _EmbeddingStatusCard(
            node: node,
            onUnlinkVoice: node['voice_embedding_registered'] == true
                ? _unlinkNodeVoice
                : null,
          ),
        // 병합·전환: 잘못 추출된 노드를 사후 교정하는 허브. Concept는 정체성 전환/
        // 정체성·개념 병합, 정체성은 다른 정체성에 병합(중복 제거). 병합 시 관계와
        // 일기 연결(provenance)이 대상 노드로 승계되고 별칭으로 학습된다.
        if (!_isStatementNode(node) && !_isChunkNode(node)) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _saving ? null : () => _mergeOrConvert(node),
            icon: const Icon(Icons.merge_type, size: 18),
            label: Text(
              canonicalEntityType(node['type']?.toString() ?? '')
                          .toLowerCase() ==
                      'concept'
                  ? tr('inspector.mergeConvertButton')
                  : tr('inspector.mergeIntoOtherButton'),
            ),
          ),
        ],
      ],

      const SizedBox(height: 8),
      _disclosureHeader(
        theme,
        label: tr('inspector.debugSection'),
        expanded: _showDebug,
        onTap: () => setState(() => _showDebug = !_showDebug),
      ),
      if (_showDebug) ...[
        const SizedBox(height: 8),
        Text(
          'ID: ${id.substring(0, 8)}… · ${node['created_at']?.toString().split('T').first ?? ''}',
          style: TextStyle(
              fontSize: 10, color: Colors.grey[600], fontFamily: 'monospace'),
        ),
        const SizedBox(height: 8),
        Text(
          tr('inspector.storedNodesNote'),
          style: TextStyle(
              fontSize: 10, color: Colors.grey[600], fontFamily: 'monospace'),
        ),
      ],
    ];
  }

  List<Widget> _nodeReadInspector(
    Map<String, dynamic> node,
    ThemeData theme, {
    required Color color,
    required List<Map<String, dynamic>> outgoing,
    required List<Map<String, dynamic>> incoming,
    required bool locked,
  }) {
    final isStatement = _isStatementNode(node);
    final content = isStatement
        ? _stmtContent(node)
        : (node['description']?.toString().trim() ?? '');
    final relationCount = outgoing.length + incoming.length;

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 7),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              nodeDisplayLabel(node),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.35,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          _InspectorMetaPill(
            label: _type ?? node['type']?.toString() ?? '',
            tint: color,
          ),
          if (isStatement)
            _InspectorMetaPill(
              icon: Icons.category_outlined,
              label: _stmtCtxType(node),
            ),
          if (isStatement && _occurredAt != null)
            _InspectorMetaPill(
              icon: Icons.calendar_today_outlined,
              label: _inspectorDayLabel(_occurredAt!),
              // Same guessed/confirmed language the edit-mode date field
              // uses, so a low-confidence date reads as low-confidence here
              // too instead of looking identical to a user-set one.
              tint: _dateIsGuessed(node)
                  ? AppColors.accentWarm
                  : (_dateIsConfirmed(node) ? AppColors.hubGraph : null),
            ),
        ],
      ),
      if (content.isNotEmpty) ...[
        const SizedBox(height: 18),
        Text(
          content,
          style: theme.textTheme.bodyLarge?.copyWith(
            height: 1.55,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
      const SizedBox(height: 18),
      _disclosureHeader(
        theme,
        label: tr('inspector.relationsCount', {'count': relationCount}),
        expanded: _showRelations,
        onTap: () => setState(() => _showRelations = !_showRelations),
      ),
      if (_showRelations) ...[
        const SizedBox(height: 6),
        ...outgoing.map((e) => _RelationTile(
              label:
                  '${e['relation']} → ${widget.nodeById[e['target_id'].toString()]?['name'] ?? '?'}',
              onTap: () => widget.onSelectEdge?.call(e),
            )),
        ...incoming.map((e) => _RelationTile(
              label:
                  '${widget.nodeById[e['source_id'].toString()]?['name'] ?? '?'} → ${e['relation']}',
              onTap: () => widget.onSelectEdge?.call(e),
            )),
      ],
      const SizedBox(height: 4),
      _disclosureHeader(
        theme,
        label: tr('inspector.moreSection'),
        expanded: _showMore,
        onTap: () => setState(() => _showMore = !_showMore),
      ),
      if (_showMore) ...[
        const SizedBox(height: 8),
        if (locked) ...[
          _LockedNotice(),
          const SizedBox(height: 8),
        ],
        _sourceTranscriptWidget(node),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _deleteNode,
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: Text(tr('common.delete')),
        ),
      ],
    ];
  }

  /// Header for a collapsed group — a plain disclosure row rather than an
  /// ExpansionTile, so it sits flush with the surrounding flat list.
  Widget _disclosureHeader(
    ThemeData theme, {
    required String label,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    final color = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _edgeInspector(Map<String, dynamic> edge, ThemeData theme) {
    final src = widget.nodeById[edge['source_id'].toString()];
    final tgt = widget.nodeById[edge['target_id'].toString()];
    final locked =
        (src?['source_entry_id'] != null) || (tgt?['source_entry_id'] != null);
    final suggestions = _relationSuggestions(_relationCtrl.text);

    if (!_editing) {
      return [
        _EdgeEndpoint(
          label: tr('inspector.sourceNode'),
          name: src?['name']?.toString() ?? '?',
          onTap: src == null ? null : () => widget.onSelectNode?.call(src),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                edge['relation']?.toString() ?? '',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        _EdgeEndpoint(
          label: tr('inspector.targetNode'),
          name: tgt?['name']?.toString() ?? '?',
          onTap: tgt == null ? null : () => widget.onSelectNode?.call(tgt),
        ),
      ];
    }

    return [
      if (locked) ...[
        const SizedBox(height: 10),
        _LockedNotice(),
      ],
      const SizedBox(height: 12),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(src?['name']?.toString() ?? '?'),
        subtitle: Text(tr('inspector.sourceNode')),
        onTap: src != null ? () => widget.onSelectNode?.call(src) : null,
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tgt?['name']?.toString() ?? '?'),
        subtitle: Text(tr('inspector.targetNode')),
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
            child: FilledButton(
                onPressed: _saving ? null : _saveEdge,
                child: Text(tr('common.save'))),
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
        tr('inspector.storedEdgesNote'),
        style: TextStyle(
            fontSize: 10, color: Colors.grey[600], fontFamily: 'monospace'),
      ),
    ];
  }
}

class _InspectorMetaPill extends StatelessWidget {
  const _InspectorMetaPill({required this.label, this.icon, this.tint});

  final String label;
  final IconData? icon;

  /// Overrides the neutral fill/text color — used to echo a node's type
  /// color or a date's confidence tone, so the pill row carries the same
  /// at-a-glance signal the rest of the inspector already gives.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fg = tint ?? colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tint != null
            ? tint!.withValues(alpha: .14)
            : colors.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(999),
        border: tint != null
            ? Border.all(color: tint!.withValues(alpha: .30))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgeEndpoint extends StatelessWidget {
  const _EdgeEndpoint({
    required this.label,
    required this.name,
    required this.onTap,
  });

  final String label;
  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(name, style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
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
              tr('inspector.lockedNotice'),
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
                  tr('inspector.cumulativeImportance'),
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
                      tr('inspector.perMentionNote'),
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
          Text(tr('inspector.pointsSuffix'),
              style:
                  TextStyle(fontSize: 12, color: Colors.deepOrange.shade600)),
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
    final aliasEmbCount = (node['alias_embedding_count'] as num?)?.toInt() ?? 0;
    final label = node['voice_profile_label']?.toString();
    final samples = node['voice_sample_count'];
    final duration =
        (node['voice_total_duration_sec'] as num?)?.toDouble() ?? 0.0;
    final isSpeakerLike = !nodeIsSource(node);

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
                  tr('inspector.embeddingVoiceMemoryTitle'),
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
              label: tr('inspector.voiceEmbeddingLabel'),
              ok: voiceOk,
              detail: voiceOk
                  ? tr('inspector.voiceRegisteredDetail', {
                      'label': label ?? tr('inspector.profileDefault'),
                      'samples': samples,
                      'duration': duration.toStringAsFixed(1),
                    })
                  : isSpeakerLike
                      ? tr('inspector.voiceUnregisteredSpeaker')
                      : tr('inspector.voiceNotSpeakerType'),
            ),
            const SizedBox(height: 8),
            _StatusRow(
              icon: Icons.scatter_plot,
              label: tr('inspector.aliasEmbeddingLabel'),
              ok: aliasEmbCount > 0,
              detail: aliasEmbCount > 0
                  ? tr('inspector.aliasEmbeddingDetail',
                      {'count': aliasEmbCount})
                  : tr('inspector.aliasEmbeddingNone'),
            ),
            if (voiceOk && onUnlinkVoice != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onUnlinkVoice,
                icon: const Icon(Icons.link_off, size: 18),
                label: Text(tr('inspector.unlinkVoiceTitle')),
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
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12)),
              Text(
                detail,
                style: TextStyle(
                    fontSize: 11, color: Colors.grey[700], height: 1.3),
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
  State<_SourceTranscriptSection> createState() =>
      _SourceTranscriptSectionState();
}

class _SourceTranscriptSectionState extends State<_SourceTranscriptSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.label ?? tr('inspector.sourceOriginalLabel');
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
                Text(label,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    // Filter out non-language metadata keys (e.g. "node_name") — only keep List values
    final raw = data?['expressions_by_language'] as Map? ?? {};
    final byLang = Map.fromEntries(
      raw.entries.where((e) => e.value is List),
    );
    if (byLang.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('inspector.noExpressionsYetLong'))),
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
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.translate, size: 18),
      label: Text(tr('inspector.viewLearnedExpressions')),
    );
  }
}

Map<String, String> get _kLangLabelMap => {
      'english': tr('kg.langEnglish'),
      'german': tr('kg.langGerman'),
      'korean': tr('kg.langKorean'),
      'japanese': tr('lang.japanese'),
      'chinese': tr('lang.chinese'),
      'spanish': tr('lang.spanish'),
      'french': tr('lang.french'),
      'portuguese': tr('lang.portuguese'),
      'italian': tr('lang.italian'),
      'arabic': tr('lang.arabic'),
      'russian': tr('lang.russian'),
    };

class _ExpressionsBottomSheet extends StatefulWidget {
  const _ExpressionsBottomSheet({required this.nodeName, required this.byLang});

  final String nodeName;
  final Map<String, dynamic> byLang;

  @override
  State<_ExpressionsBottomSheet> createState() =>
      _ExpressionsBottomSheetState();
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
              width: 40,
              height: 4,
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
                tabs: _langs
                    .map((l) => Tab(text: _kLangLabelMap[l] ?? l))
                    .toList(),
              ),
            const Divider(height: 1),
            Expanded(
              child: _langs.length == 1
                  ? _ExpressionList(
                      items: List<Map>.from(widget.byLang[_langs[0]] ?? []),
                    )
                  : TabBarView(
                      controller: _tabs,
                      children: _langs
                          .map((l) => _ExpressionList(
                                items: List<Map>.from(widget.byLang[l] ?? []),
                              ))
                          .toList(),
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
      return Center(child: Text(tr('inspector.noExpressionsYetShort')));
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
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
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
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 12))),
              Icon(Icons.chevron_right, size: 18, color: Colors.grey[500]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImpactRow extends StatelessWidget {
  const _ImpactRow(
      {required this.icon, required this.label, required this.count});

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
          Expanded(
              child: Text('• $label', style: const TextStyle(fontSize: 13))),
          Text(
            tr('inspector.countSuffix', {'count': count}),
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
