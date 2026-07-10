import 'package:flutter/material.dart';

import '../api/client.dart';
import '../chat/chat_mode_cards.dart';
import '../chat/chat_session_controller.dart';
import '../chat/journal_task_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';
import '../widgets/chat_journal_compose_bar.dart';
import '../widgets/graph_chat_panel.dart';
import '../widgets/graph_inspector_panel.dart';
import '../widgets/knowledge_graph_canvas.dart';
import '../widgets/app_theme_toggle_button.dart';
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
    final shell = context.shell;
    return Scaffold(
      backgroundColor: shell.graphBackground,
      appBar: AppBar(
        backgroundColor: shell.toolbarBackground,
        foregroundColor: shell.graphLabel,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        title: Text(AppLocalizations.of(context)!.kgTitle),
        actions: [
          const AppThemeToggleButton(),
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
      body: KnowledgeGraphView(
        initialNodeId: initialNodeId,
        chatOpen: true,
      ),
    );
  }
}

class KnowledgeGraphView extends StatefulWidget {
  const KnowledgeGraphView({
    super.key,
    this.compact = false,
    this.initialNodeId,
    this.chatOpen = true,
    this.onChatOpenChanged,
  });

  final bool compact;
  final String? initialNodeId;
  final bool chatOpen;
  final ValueChanged<bool>? onChatOpenChanged;

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

  final _chatInputController = TextEditingController();
  final _chatScrollController = ScrollController();
  Set<String> _glowIds = const {};
  int _glowSeq = 0;
  int _lastMsgCount = 0;
  ChatMode _lastChatMode = ChatMode.normal;
  bool _lastDistillLoading = false;

  /// User-resizable chat panel width (px). Null → default fraction on first layout.
  double? _chatPanelWidth;

  static const _chatMinWidth = 280.0;
  static const _chatMaxWidthFraction = 0.58;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 900;

  @override
  void initState() {
    super.initState();
    if (widget.initialNodeId != null) {
      _selectedNodeId = widget.initialNodeId;
    }
    _load();
    if (!widget.compact) {
      chatSession.onReferencedNodes = _highlightNodes;
      chatSession.addListener(_onChatChanged);
      chatSession.errors.addListener(_onChatError);
      journalTask.addListener(_onJournalTaskChanged);
      chatSession.init();
    }
  }

  @override
  void dispose() {
    if (!widget.compact) {
      chatSession.removeListener(_onChatChanged);
      chatSession.errors.removeListener(_onChatError);
      journalTask.removeListener(_onJournalTaskChanged);
      chatSession.onReferencedNodes = null;
    }
    _chatInputController.dispose();
    _chatScrollController.dispose();
    super.dispose();
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

  void _scrollChatToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollController.hasClients) return;
      final max = _chatScrollController.position.maxScrollExtent;
      if (animated) {
        _chatScrollController.animateTo(
          max,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      } else {
        _chatScrollController.jumpTo(max);
      }
    });
  }

  Future<void> _sendChat(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || chatSession.busy) return;
    _chatInputController.clear();
    await chatSession.submitInput(text);
    _scrollChatToBottom();
  }

  Future<void> _deleteActiveRoom() async {
    final id = chatSession.activeId;
    if (id == null || chatSession.messages.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('대화 기록 삭제'),
        content: const Text(
          '이 채팅방의 대화 기록을 모두 지울까요?\n지식그래프는 그대로 유지돼요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await chatSession.deleteSession(id);
    if (mounted) setState(() => _glowIds = const {});
  }

  void _highlightNodes(Set<String> nodeIds) {
    setState(() {
      _glowIds = nodeIds;
      _glowSeq++;
    });
    _canvasKey.currentState?.focusOnNodes(nodeIds);
  }

  void _collapseChat() => widget.onChatOpenChanged?.call(false);

  void _expandChat() => widget.onChatOpenChanged?.call(true);

  void _onChatChanged() {
    if (chatSession.messages.length != _lastMsgCount) {
      _lastMsgCount = chatSession.messages.length;
      _scrollChatToBottom();
    }
    final mode = chatSession.mode;
    final enteredDistill =
        mode == ChatMode.distill && _lastChatMode != ChatMode.distill;
    final distillReady = mode == ChatMode.distill &&
        _lastDistillLoading &&
        !chatSession.distillLoading;
    if (enteredDistill || distillReady) {
      _scrollChatToBottom();
    }
    _lastChatMode = mode;
    _lastDistillLoading = chatSession.distillLoading;
    if (mounted) setState(() {});
  }

  void _onJournalTaskChanged() {
    if (mounted) setState(() {});
  }

  void _onChatError() {
    final msg = chatSession.errors.value;
    if (msg == null || !mounted) return;
    chatSession.errors.value = null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  double _chatMaxWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * _chatMaxWidthFraction)
          .clamp(_chatMinWidth, 720.0);

  double _resolvedChatWidth(BuildContext context) {
    final maxW = _chatMaxWidth(context);
    _chatPanelWidth ??=
        (MediaQuery.sizeOf(context).width.clamp(320.0, 900.0) * 0.34)
            .clamp(_chatMinWidth, maxW);
    return _chatPanelWidth!.clamp(_chatMinWidth, maxW);
  }

  void _resizeChatPanel(double deltaDx) {
    final maxW = _chatMaxWidth(context);
    setState(() {
      _chatPanelWidth =
          (_resolvedChatWidth(context) + deltaDx).clamp(_chatMinWidth, maxW);
    });
  }

  void _onModeSelected(String action) {
    switch (action) {
      case 'journal':
        chatSession.enterJournalMode();
        break;
      case 'distill':
        chatSession.startDistill();
        break;
      case 'composition':
        chatSession.startQuiz('composition');
        break;
      case 'word':
        chatSession.startQuiz('cloze');
        break;
    }
  }

  String? _modeLabel() {
    switch (chatSession.mode) {
      case ChatMode.distill:
        return '대화 → 일기 정리';
      case ChatMode.quizComposition:
        return '작문 퀴즈';
      case ChatMode.quizWord:
        return '단어 퀴즈';
      case ChatMode.journal:
        return '일기 쓰기';
      case ChatMode.normal:
        return null;
    }
  }

  bool get _inputEnabled =>
      chatSession.mode != ChatMode.quizWord && !journalTask.blocksChat;

  String get _inputHint {
    switch (chatSession.mode) {
      case ChatMode.distill:
        return '고칠 부분을 말해보세요. 예) 첫 문장 빼줘';
      case ChatMode.quizComposition:
        return '영어로 작문해서 보내기';
      case ChatMode.quizWord:
        return '카드에서 답을 선택하세요';
      case ChatMode.journal:
        return '일기를 작성하세요…';
      case ChatMode.normal:
        return '아무 얘기나 해보세요…';
    }
  }

  Widget? _journalInputBar() =>
      chatSession.mode == ChatMode.journal && !journalTask.blocksChat
          ? const ChatJournalComposeBar()
          : null;

  /// Quiz cards pinned above the input, or null.
  Widget? _activeModeCard() {
    switch (chatSession.mode) {
      case ChatMode.normal:
      case ChatMode.journal:
      case ChatMode.distill:
        return null;
      case ChatMode.quizComposition:
        final quiz = chatSession.activeQuiz;
        if (quiz == null) return _quizStatusCard();
        return CompositionDrillCard(
          key: ValueKey('comp-${quiz['id']}'),
          quiz: quiz,
          feedback: chatSession.quizFeedback,
          busy: chatSession.busy,
          onNext: chatSession.nextQuiz,
          onExit: chatSession.exitMode,
        );
      case ChatMode.quizWord:
        final quiz = chatSession.activeQuiz;
        if (quiz == null) return _quizStatusCard();
        return WordQuizCard(
          key: ValueKey('word-${quiz['id']}'),
          quiz: quiz,
          onSubmit: ({answer, order, selectedIndex}) =>
              chatSession.submitWordQuiz(
            answer: answer,
            order: order,
            selectedIndex: selectedIndex,
          ),
          onNext: chatSession.nextQuiz,
          onExit: chatSession.exitMode,
        );
    }
  }

  /// Distill draft lives in the chat scroll so it grows with content.
  Widget? _chatListFooter() {
    if (chatSession.mode != ChatMode.distill) return null;
    return DistillDraftCard(
      sentences: chatSession.distillSentences,
      loading: chatSession.distillLoading,
      onToggle: chatSession.toggleDistillSentence,
      onSave: chatSession.saveDistillAsJournal,
      onCancel: chatSession.exitMode,
    );
  }

  Widget _quizStatusCard() {
    return const Padding(
      padding: EdgeInsets.all(12),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }

  Widget _buildGraphChatPanel({
    Map<String, Color> typeColors = const {},
    Map<String, Map<String, dynamic>> nodeById = const {},
  }) {
    return GraphChatPanel(
      messages: chatSession.messages,
      busy: chatSession.busy,
      typeColors: typeColors,
      nodeById: nodeById,
      inputController: _chatInputController,
      scrollController: _chatScrollController,
      onSend: _sendChat,
      onNodeHighlight: nodeById.isEmpty ? (_) {} : _highlightNodes,
      onNodeSelect: nodeById.isEmpty
          ? (_) {}
          : (node) => _selectNode(node, showSheet: true),
      onClearHistory: _deleteActiveRoom,
      onCollapse: _collapseChat,
      activeCard: _activeModeCard(),
      listFooter: _chatListFooter(),
      modeLabel: _modeLabel(),
      onExitMode: chatSession.exitMode,
      onModeSelected: journalTask.blocksChat ? null : _onModeSelected,
      inputEnabled: _inputEnabled,
      inputHint: _inputHint,
      inputBarOverride: _journalInputBar(),
      pipelineLocked: journalTask.blocksChat,
      pipelineLockLabel: journalTask.stageLabel.isEmpty
          ? '일기 처리 중'
          : journalTask.stageLabel,
    );
  }

  Widget _layoutGraphWithChat({
    required Widget graphSide,
    Map<String, Color> typeColors = const {},
    Map<String, Map<String, dynamic>> nodeById = const {},
  }) {
    final showChat = widget.chatOpen;
    if (!showChat) {
      return Stack(
        fit: StackFit.expand,
        children: [
          graphSide,
          Positioned(
            right: 0,
            top: MediaQuery.sizeOf(context).height * 0.38,
            child: GraphChatCollapsedTab(onExpand: _expandChat),
          ),
        ],
      );
    }

    final chatW = _resolvedChatWidth(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: graphSide),
        _ChatPanelResizeHandle(onDrag: _resizeChatPanel),
        SizedBox(
          width: chatW,
          child: _buildGraphChatPanel(
            typeColors: typeColors,
            nodeById: nodeById,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyWithChat() {
    return _layoutGraphWithChat(
      graphSide: const _EmptyGraphHint(),
    );
  }

  Widget _canvasWithCard({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required Map<String, Color> typeColors,
  }) {
    return KnowledgeGraphCanvas(
      key: _canvasKey,
      nodes: nodes,
      edges: edges,
      typeColors: typeColors,
      selectedNodeId: _selectedNodeId,
      selectedEdgeId: _selectedEdgeId,
      highlightQuery: _query,
      typeFilter: _typeFilter,
      glowNodeIds: _glowIds,
      glowSeq: _glowSeq,
      onNodeTap: _selectNode,
      onEdgeTap: _selectEdge,
      onBackgroundTap: _clearSelection,
    );
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
      if (widget.compact) {
        return _EmptyGraphHint(compact: true);
      }
      return _buildEmptyWithChat();
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
          decoration: BoxDecoration(
            color: context.shell.toolbarBackground,
            border: Border(bottom: BorderSide(color: context.shell.graphBorder)),
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
            glowNodeIds: _glowIds,
            glowSeq: _glowSeq,
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
    return _layoutGraphWithChat(
      typeColors: typeColors,
      nodeById: nodeById,
      graphSide: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GraphToolbar(
            query: _query,
            ontologyName: _ontology?['name']?.toString() ?? 'Ontology',
            nodeCount: nodes.length,
            edgeCount: edges.length,
            onQueryChanged: (v) => setState(() => _query = v),
            onRefresh: () {
              _load();
              chatSession.loadSessions();
            },
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
            decoration: BoxDecoration(
              color: context.shell.toolbarBackground,
              border: Border(bottom: BorderSide(color: context.shell.graphBorder)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Text(
                    '${nodes.length} nodes · ${edges.length} edges · ${entityTypes.length} types',
                    style: TextStyle(fontSize: 11, color: context.shell.graphMuted),
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
            child: _canvasWithCard(
              nodes: nodes,
              edges: edges,
              typeColors: typeColors,
            ),
          ),
        ],
      ),
    );
  }
}

/// Drag handle between graph canvas and chat panel.
class _ChatPanelResizeHandle extends StatelessWidget {
  const _ChatPanelResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Container(
          width: 8,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 2,
              height: double.infinity,
              color: const Color(0xFF3A3A48),
            ),
          ),
        ),
      ),
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
    final shell = context.shell;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
      decoration: BoxDecoration(
        color: shell.toolbarBackground,
        border: Border(bottom: BorderSide(color: shell.graphBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: TextStyle(fontSize: 13, color: shell.graphLabel),
              decoration: InputDecoration(
                hintText: '노드 검색…',
                hintStyle: TextStyle(color: shell.graphMuted, fontSize: 13),
                prefixIcon: Icon(Icons.search, size: 18, color: shell.graphMuted),
                filled: true,
                fillColor: shell.graphInputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: shell.graphBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: shell.graphBorder),
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
            style: TextStyle(fontSize: 11, color: context.mutedText),
          ),
          IconButton(
            tooltip: '새로고침',
            visualDensity: VisualDensity.compact,
            onPressed: onRefresh,
            icon: Icon(Icons.refresh, size: 20, color: context.mutedText),
          ),
          IconButton(
            tooltip: '전체 화면',
            visualDensity: VisualDensity.compact,
            onPressed: onOpenFullscreen,
            icon: Icon(Icons.open_in_full, size: 20, color: context.mutedText),
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
    final shell = context.shell;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      decoration: BoxDecoration(
        color: shell.toolbarBackground,
        border: Border(bottom: BorderSide(color: shell.graphBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: TextStyle(color: shell.graphLabel),
              decoration: InputDecoration(
                hintText: '노드 검색…',
                hintStyle: TextStyle(color: shell.graphMuted),
                prefixIcon: Icon(Icons.search, size: 20, color: shell.graphMuted),
                filled: true,
                fillColor: shell.graphInputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: shell.graphBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: shell.graphBorder),
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
            icon: Icon(Icons.category_outlined, color: context.mutedText),
          ),
          IconButton(
            tooltip: '새로고침',
            onPressed: onRefresh,
            icon: Icon(Icons.refresh, color: context.mutedText),
          ),
          IconButton(
            tooltip: '휴지통',
            onPressed: onTrash,
            icon: Icon(Icons.delete_outline, color: context.mutedText),
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
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.hub_outlined, size: 56, color: context.mutedText),
            const SizedBox(height: 16),
            Text(l10n.kgEmpty, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              compact
                  ? 'Dev tools → run GraphRAG ingest from the pipeline hub'
                  : l10n.kgEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.mutedText),
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
