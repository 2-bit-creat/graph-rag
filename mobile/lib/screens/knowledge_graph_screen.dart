import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';
import '../widgets/graph_inspector_panel.dart';
import '../widgets/knowledge_graph_canvas.dart';
import '../widgets/ontology_rules_panel.dart';
import '../widgets/ontology_settings_sheet.dart';
import 'graph_trash_screen.dart';

/// Full-screen interactive knowledge graph.
class KnowledgeGraphScreen extends StatelessWidget {
  const KnowledgeGraphScreen({super.key, this.initialNodeId});

  /// If set, the graph will auto-select this node on load.
  final String? initialNodeId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.graphBgDark,
      appBar: AppBar(
        backgroundColor: const Color(0xFF101018),
        foregroundColor: AppColors.graphLabelLight,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        title: const Text('내 지식 그래프'),
        actions: [
          IconButton(
            tooltip: '저장 위치 안내',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('지식 그래프 저장 위치'),
                content: const Text(
                  'PostgreSQL 데이터베이스\n\n'
                  '• nodes — 개념·인물·장소 등 노드\n'
                  '• edges — 노드 간 관계 (relation)\n'
                  '• ontology — 엔티티/관계 타입 정의\n\n'
                  'GraphRAG 수동 배치(Slow Path) 실행 시\n'
                  'LightRAG 점진적 병합으로 트리플이 upsert 됩니다.\n'
                  'API: GET /graph',
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
                ],
              ),
            ),
          ),
        ],
      ),
      body: KnowledgeGraphView(initialNodeId: initialNodeId),
    );
  }
}

class KnowledgeGraphView extends StatefulWidget {
  const KnowledgeGraphView({super.key, this.compact = false, this.initialNodeId});

  final bool compact;
  final String? initialNodeId;

  @override
  State<KnowledgeGraphView> createState() => _KnowledgeGraphViewState();
}

class _KnowledgeGraphViewState extends State<KnowledgeGraphView> {
  Map<String, dynamic>? _graph;
  Map<String, dynamic>? _ontology;
  bool _loading = true;
  String? _error;
  String _typeFilter = '전체';
  String _query = '';
  String? _selectedNodeId;
  String? _selectedEdgeId;
  Map<String, dynamic>? _selectedNode;
  Map<String, dynamic>? _selectedEdge;
  final _canvasKey = GlobalKey<KnowledgeGraphCanvasState>();
  bool _showOntologyRules = false;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 900;

  @override
  void initState() {
    super.initState();
    if (widget.initialNodeId != null) {
      _selectedNodeId = widget.initialNodeId;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final graph = await apiClient.getGraph();
      Map<String, dynamic>? ontology;
      try {
        ontology = await apiClient.getOntology();
      } catch (_) {
        ontology = {'entity_types': [], 'relation_types': []};
      }
      if (mounted) {
        setState(() {
          _graph = graph;
          _ontology = ontology;
          _loading = false;
          _syncSelection(graph);
        });
        // Auto-open inspector for the initial node from timeline navigation
        if (_selectedNode != null && widget.initialNodeId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showInspectorSheet();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  void _syncSelection(Map<String, dynamic> graph) {
    if (_selectedNodeId == null) return;
    final nodes = graph['nodes'] as List<dynamic>? ?? [];
    _selectedNode = nodes
        .cast<Map>()
        .map((n) => Map<String, dynamic>.from(n))
        .where((n) => n['id'].toString() == _selectedNodeId)
        .cast<Map<String, dynamic>?>()
        .firstOrNull;
    if (_selectedNode == null) {
      _selectedNodeId = null;
      _selectedEdgeId = null;
      _selectedEdge = null;
    }
  }

  Future<void> _selectNode(Map<String, dynamic>? node, {bool showSheet = true}) async {
    if (node == null) {
      setState(() {
        _selectedNode = null;
        _selectedNodeId = null;
        _selectedEdge = null;
        _selectedEdgeId = null;
      });
      _canvasKey.currentState?.refit();
      return;
    }

    Map<String, dynamic> detail = node;
    try {
      detail = await apiClient.getNode(node['id'].toString());
    } catch (_) {
      detail = Map<String, dynamic>.from(node);
    }
    if (!mounted) return;

    setState(() {
      _selectedNode = detail;
      _selectedNodeId = detail['id']?.toString();
      _selectedEdge = null;
      _selectedEdgeId = null;
    });
    if (!showSheet || !mounted) return;
    await _showInspectorSheet();
  }

  Future<void> _selectEdge(Map<String, dynamic>? edge, {bool showSheet = true}) async {
    setState(() {
      _selectedEdge = edge;
      _selectedEdgeId = edge?['id']?.toString();
      _selectedNode = null;
      _selectedNodeId = null;
    });
    if (edge != null && showSheet && mounted) {
      await _showInspectorSheet();
    }
  }

  Future<void> _showInspectorSheet() async {
    final nodes = (_graph?['nodes'] as List<dynamic>? ?? [])
        .map((n) => Map<String, dynamic>.from(n as Map))
        .toList();
    final edges = (_graph?['edges'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final entityTypes = entityTypesFromNodes(nodes);
    final typeColors = buildDynamicTypeColorMap(
      entityTypes.map((e) => e['name'].toString()),
    );
    final relationTypes = (_ontology?['relation_types'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final nodeById = buildNodeById(nodes);

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (_, scrollCtrl) => GraphInspectorPanel(
          selectedNode: _selectedNode,
          selectedEdge: _selectedEdge,
          edges: edges,
          nodeById: nodeById,
          typeColors: typeColors,
          relationTypes: relationTypes,
          entityTypes: entityTypes,
          scrollController: scrollCtrl,
          onClose: () => Navigator.pop(ctx),
          onUpdated: _load,
          onSelectNode: (n) {
            Navigator.pop(ctx);
            _selectNode(n, showSheet: false);
            _showInspectorSheet();
          },
          onSelectEdge: (e) {
            Navigator.pop(ctx);
            _selectEdge(e, showSheet: false);
            _showInspectorSheet();
          },
        ),
      ),
    );
    if (mounted) _clearSelection();
  }

  void _clearSelection() {
    setState(() {
      _selectedNode = null;
      _selectedNodeId = null;
      _selectedEdge = null;
      _selectedEdgeId = null;
    });
    _canvasKey.currentState?.refit();
  }

  Future<void> _clearGraph() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('지식 그래프 전체 삭제'),
        content: const Text(
          '모든 노드·엣지·임베딩 청크가 삭제됩니다.\n'
          '일기 번역본은 유지됩니다. GraphRAG를 다시 실행하면 새 그래프가 만들어집니다.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('전체 삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final stats = await apiClient.clearGraph();
      if (!mounted) return;
      setState(() {
        _graph = {'nodes': [], 'edges': []};
        _selectedNode = null;
        _selectedNodeId = null;
        _selectedEdge = null;
        _selectedEdgeId = null;
        _typeFilter = '전체';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '삭제됨: 노드 ${stats['nodes_deleted']} · 엣지 ${stats['edges_deleted']} · 청크 ${stats['chunks_deleted']}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('삭제 실패: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _error!.contains('연결') ? Icons.cloud_off : Icons.error_outline,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    final nodes = (_graph?['nodes'] as List<dynamic>? ?? [])
        .map((n) => Map<String, dynamic>.from(n as Map))
        .toList();
    final edges = (_graph?['edges'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final entityTypes = entityTypesFromNodes(nodes);
    final typeColors = buildDynamicTypeColorMap(
      entityTypes.map((e) => e['name'].toString()),
    );
    final relationTypes = (_ontology?['relation_types'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    final nodeById = buildNodeById(nodes);

    if (nodes.isEmpty) {
      return _EmptyGraphHint(compact: widget.compact);
    }

    return SizedBox.expand(
      child: widget.compact
          ? _buildCompactGraph(
              nodes: nodes,
              edges: edges,
              entityTypes: entityTypes,
              typeColors: typeColors,
            )
          : _buildFullGraph(
              nodes: nodes,
              edges: edges,
              entityTypes: entityTypes,
              relationTypes: relationTypes,
              typeColors: typeColors,
              nodeById: nodeById,
            ),
    );
  }

  Widget _buildCompactGraph({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required List<Map<String, dynamic>> entityTypes,
    required Map<String, Color> typeColors,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CompactGraphHeader(
          nodeCount: nodes.length,
          edgeCount: edges.length,
          query: _query,
          onQueryChanged: (v) => setState(() => _query = v),
          onRefresh: _load,
          onOpenFullscreen: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const KnowledgeGraphScreen()),
            );
          },
        ),
        Container(
          padding: const EdgeInsets.only(bottom: 6),
          decoration: const BoxDecoration(
            color: Color(0xFF101018),
            border: Border(bottom: BorderSide(color: Color(0xFF2D2D38))),
          ),
          child: OntologyLegendBar(
            entityTypes: entityTypes,
            typeColors: typeColors,
            selectedType: _typeFilter,
            onTypeSelected: (t) => setState(() => _typeFilter = t),
          ),
        ),
        Expanded(
          child: KnowledgeGraphCanvas(
            key: _canvasKey,
            compactMode: true,
            nodes: nodes,
            edges: edges,
            typeColors: typeColors,
            selectedNodeId: _selectedNodeId,
            selectedEdgeId: _selectedEdgeId,
            highlightQuery: _query,
            typeFilter: _typeFilter,
            onNodeTap: _selectNode,
            onEdgeTap: _selectEdge,
            onBackgroundTap: _clearSelection,
          ),
        ),
      ],
    );
  }

  Widget _buildFullGraph({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required List<Map<String, dynamic>> entityTypes,
    required List<String> relationTypes,
    required Map<String, Color> typeColors,
    required Map<String, Map<String, dynamic>> nodeById,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _GraphToolbar(
                query: _query,
                ontologyName: _ontology?['name']?.toString() ?? 'Ontology',
                nodeCount: nodes.length,
                edgeCount: edges.length,
                onQueryChanged: (v) => setState(() => _query = v),
                onRefresh: _load,
                onOntology: () => OntologySettingsSheet.show(
                  context,
                  onApplied: _load,
                  onFilterByType: (type) => setState(() => _typeFilter = type),
                ),
                onTrash: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const GraphTrashScreen()),
                ).then((_) => _load()),
                onClearGraph: _clearGraph,
              ),
              Container(
                padding: const EdgeInsets.only(bottom: 6),
                decoration: const BoxDecoration(
                  color: Color(0xFF101018),
                  border: Border(bottom: BorderSide(color: Color(0xFF2D2D38))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Text(
                        '${nodes.length} nodes · ${edges.length} edges · ${entityTypes.length} types',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                      ),
                    ),
                    OntologyLegendBar(
                      entityTypes: entityTypes,
                      typeColors: typeColors,
                      selectedType: _typeFilter,
                      onTypeSelected: (t) => setState(() => _typeFilter = t),
                    ),
                  ],
                ),
              ),
              OntologyRulesPanel(
                ontologyName: _ontology?['name']?.toString() ?? 'DailyLife_English',
                entityTypes: entityTypes,
                relationTypes: relationTypes,
                typeColors: typeColors,
                expanded: _showOntologyRules,
                onToggle: () {
                  setState(() => _showOntologyRules = !_showOntologyRules);
                  _canvasKey.currentState?.refit();
                },
                onEdit: () => OntologySettingsSheet.show(context, onApplied: _load),
              ),
              Expanded(
                child: KnowledgeGraphCanvas(
                  key: _canvasKey,
                  nodes: nodes,
                  edges: edges,
                  typeColors: typeColors,
                  selectedNodeId: _selectedNodeId,
                  selectedEdgeId: _selectedEdgeId,
                  highlightQuery: _query,
                  typeFilter: _typeFilter,
                  onNodeTap: _selectNode,
                  onEdgeTap: _selectEdge,
                  onBackgroundTap: _clearSelection,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactGraphHeader extends StatelessWidget {
  const _CompactGraphHeader({
    required this.nodeCount,
    required this.edgeCount,
    required this.query,
    required this.onQueryChanged,
    required this.onRefresh,
    required this.onOpenFullscreen,
  });

  final int nodeCount;
  final int edgeCount;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onRefresh;
  final VoidCallback onOpenFullscreen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
      decoration: const BoxDecoration(
        color: Color(0xFF101018),
        border: Border(bottom: BorderSide(color: Color(0xFF2D2D38))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: const TextStyle(fontSize: 13, color: AppColors.graphLabelLight),
              decoration: InputDecoration(
                hintText: '노드 검색…',
                hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF6B7280)),
                filled: true,
                fillColor: const Color(0xFF1A1A22),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF2D2D38)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF2D2D38)),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: onQueryChanged,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$nodeCount/$edgeCount',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          IconButton(
            tooltip: '새로고침',
            visualDensity: VisualDensity.compact,
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 20, color: AppColors.textMuted),
          ),
          IconButton(
            tooltip: '전체 화면',
            visualDensity: VisualDensity.compact,
            onPressed: onOpenFullscreen,
            icon: const Icon(Icons.open_in_full, size: 20, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _GraphToolbar extends StatelessWidget {
  const _GraphToolbar({
    required this.query,
    required this.ontologyName,
    required this.nodeCount,
    required this.edgeCount,
    required this.onQueryChanged,
    required this.onRefresh,
    required this.onOntology,
    required this.onTrash,
    required this.onClearGraph,
  });

  final String query;
  final String ontologyName;
  final int nodeCount;
  final int edgeCount;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onRefresh;
  final VoidCallback onOntology;
  final VoidCallback onTrash;
  final VoidCallback onClearGraph;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      decoration: const BoxDecoration(
        color: Color(0xFF101018),
        border: Border(bottom: BorderSide(color: Color(0xFF2D2D38))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: const TextStyle(color: AppColors.graphLabelLight),
              decoration: InputDecoration(
                hintText: '노드 검색…',
                hintStyle: const TextStyle(color: Color(0xFF6B7280)),
                prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF6B7280)),
                filled: true,
                fillColor: const Color(0xFF1A1A22),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF2D2D38)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF2D2D38)),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onChanged: onQueryChanged,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '온톨로지',
            onPressed: onOntology,
            icon: const Icon(Icons.category_outlined, color: AppColors.textMuted),
          ),
          IconButton(
            tooltip: '새로고침',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, color: AppColors.textMuted),
          ),
          IconButton(
            tooltip: '휴지통',
            onPressed: onTrash,
            icon: const Icon(Icons.delete_outline, color: AppColors.textMuted),
          ),
          IconButton(
            tooltip: '지식 그래프 전체 삭제',
            onPressed: onClearGraph,
            icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
          ),
        ],
      ),
    );
  }
}

class _EmptyGraphHint extends StatelessWidget {
  const _EmptyGraphHint({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.hub_outlined, size: 56, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('아직 지식 그래프가 비어 있습니다', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              compact
                  ? '개발자 도구 → 파이프라인에서 GraphRAG 수동 배치'
                  : '일기 작성 후 파이프라인(Dev)에서 GraphRAG 배치 실행',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

class KnowledgeGraphBody extends StatelessWidget {
  const KnowledgeGraphBody({super.key});

  @override
  Widget build(BuildContext context) {
    return const KnowledgeGraphView(compact: true);
  }
}
