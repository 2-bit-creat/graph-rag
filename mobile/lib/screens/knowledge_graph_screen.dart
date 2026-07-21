import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../chat/chat_mode_cards.dart';
import '../chat/chat_session_controller.dart';
import '../chat/journal_task_controller.dart';
import '../compose/compose_session_controller.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';
import '../utils/statement_display.dart';
import '../widgets/app_theme_toggle_button.dart';
import '../widgets/chat_journal_compose_bar.dart';
import '../widgets/graph_chat_panel.dart';
import '../widgets/graph_inspector_panel.dart';
import '../widgets/journal_progress_card.dart';
import '../widgets/journal_status_pill.dart';
import '../widgets/knowledge_graph_canvas.dart';
import '../widgets/ontology_settings_sheet.dart';
import 'graph_trash_screen.dart';

/// Full-screen interactive knowledge graph with integrated chat panel.
class KnowledgeGraphScreen extends StatefulWidget {
  const KnowledgeGraphScreen({
    super.key,
    this.initialNodeId,
  });

  /// If set, the graph will auto-select this node on load.
  final String? initialNodeId;

  @override
  State<KnowledgeGraphScreen> createState() => _KnowledgeGraphScreenState();
}

class _KnowledgeGraphScreenState extends State<KnowledgeGraphScreen> {
  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Scaffold(
      backgroundColor: shell.graphBackground,
      appBar: AppBar(
        backgroundColor: shell.appBarBackground,
        foregroundColor: shell.appBarForeground,
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
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('닫기')),
                ],
              ),
            ),
          ),
        ],
      ),
      body: KnowledgeGraphView(initialNodeId: widget.initialNodeId),
    );
  }
}

class KnowledgeGraphView extends StatefulWidget {
  const KnowledgeGraphView({
    super.key,
    this.compact = false,
    this.initialNodeId,
    this.onOpenMenu,
  });

  final bool compact;
  final String? initialNodeId;

  /// When set, the floating search pill shows a leading hamburger button that
  /// invokes this (opens the rooms drawer) — the host screen has no AppBar.
  final VoidCallback? onOpenMenu;

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
  // 화자 숨김(Speaker-to-Color) 모드: head 노드를 물리에서 제거하고
  // Statement를 화자색으로 인코딩 — 슈퍼노드(성게) 뭉침 해소용.
  bool _hideHeads = false;
  bool _pinning = false;

  // ── 그래프 대화 (전역 chatSession 컨트롤러 구독) ─────────────────────────
  final _chatInputController = TextEditingController();
  final _chatInputFocusNode = FocusNode();
  Set<String> _glowIds = const {};
  int _glowSeq = 0;
  int _lastMsgCount = 0;
  ChatMode _lastChatMode = ChatMode.normal;
  bool _lastChatBusy = false;
  bool _lastDistillLoading = false;
  String? _lastActiveQuizId;
  ComposePhase? _prevJournalPhase;
  ComposePhase? _prevComposePhase;
  String? _prevJournalGraphStatus;
  bool _graphReloadScheduled = false;

  // ── 바텀시트 (지도 앱 스타일: 40% 기본 / 90% 포커스 / 최소화-입력줄만) ────
  final _chatScrollController = ScrollController();
  bool _chatVisible = true;
  double _chatAreaHeight = 1;
  double _chatSheetSize = _sheetDefaultSize;
  double _chatRestoredSize = _sheetDefaultSize;
  bool _graphToolsVisible = true;
  bool _chatExpandedForInput = false;
  bool get _isQuizMode =>
      chatSession.mode == ChatMode.quizWord ||
      chatSession.mode == ChatMode.quizComposition;
  static const double _sheetDefaultSize = 0.40; // 상태 A
  static const double _sheetFocusSize = 0.90; // 상태 B
  bool _chatFocused = false; // 스크림 표시 여부 — 포커스에서만 파생, 수동 드래그와 무관

  /// 시트의 `builder`가 매 build마다 새로 넘겨주는 컨트롤러 — 프로그램적 스크롤은
  /// 항상 "현재 살아있는" 컨트롤러를 대상으로 해야 한다.
  ScrollController? _activeChatScrollController;

  /// 입력바 높이 근사치 기반 최소 시트 크기(상태 C) — 정확한 픽셀 측정 대신
  /// 넉넉한 상수 사용, snap:true 물리가 오차를 흡수한다.
  double _sheetMinChildSize(BuildContext context, double graphAreaHeight) {
    const inputBarApproxHeight = 64.0;
    final minPx = inputBarApproxHeight + MediaQuery.paddingOf(context).bottom;
    if (graphAreaHeight <= 0) return 0.08;
    return (minPx / graphAreaHeight).clamp(0.06, _sheetDefaultSize - 0.02);
  }

  void _onChatFocusChanged() {
    final focused = _chatInputFocusNode.hasFocus;
    if (focused) {
      if (!_chatVisible) setState(() => _chatVisible = true);
      setState(() {
        _chatFocused = true;
        _chatExpandedForInput = true;
      });
      _animateChatSheet(_sheetFocusSize);
      return;
    }

    // Losing focus should not collapse the chat. A downward drag is the
    // explicit user action that restores the normal sheet height.
    if (_chatFocused) setState(() => _chatFocused = false);
  }

  void _animateChatSheet(double target, {bool remember = true}) {
    final min = _sheetMinChildSize(context, _chatAreaHeight);
    final next = target.clamp(min, _sheetFocusSize).toDouble();
    if (remember && _chatVisible && next > min + 0.01) {
      _chatRestoredSize = next;
    }
    setState(() {
      _chatSheetSize = next;
    });
  }

  void _toggleChatVisibility() {
    final nextVisible = !_chatVisible;
    _chatInputFocusNode.unfocus();
    final min = _sheetMinChildSize(context, _chatAreaHeight);
    if (!nextVisible) {
      _chatExpandedForInput = false;
      _chatRestoredSize = _chatSheetSize > min + 0.01
          ? _chatSheetSize
          : _chatRestoredSize;
    }
    setState(() => _chatVisible = nextVisible);
    _animateChatSheet(
      nextVisible ? _chatRestoredSize : min,
      remember: false,
    );
  }

  /// 핀 성공 등으로 채팅을 눈에 띄게 해야 할 때 — 이미 40% 이상이면 그대로 둔다.
  void _ensureChatVisible() {
    if (!_chatVisible) {
      _chatExpandedForInput = false;
      setState(() => _chatVisible = true);
      _animateChatSheet(_chatRestoredSize, remember: false);
    }
  }

  Widget _buildGraphChatPanel({
    required ScrollController scrollController,
    required double graphAreaHeight,
    Map<String, Color> typeColors = const {},
    Map<String, Map<String, dynamic>> nodeById = const {},
  }) {
    return GraphChatPanel(
      messages: chatSession.messages,
      busy: chatSession.busy,
      typeColors: typeColors,
      nodeById: nodeById,
      scrollController: scrollController,
      title: (chatSession.activeSession?['title'] as String?)?.trim(),
      onNodeHighlight: nodeById.isEmpty ? (_) {} : _highlightNodes,
      onNodeSelect: nodeById.isEmpty
          ? (_) {}
          : (node) => _selectNode(node, showSheet: true),
      onClearHistory: _deleteActiveRoom,
      listFooter: _chatListFooter(),
      quizMode: _isQuizMode,
      statusPill: journalTask.showsPill
          ? JournalStatusPill(onTap: _onStatusPillTap)
          : null,
      onPanelTap: _chatVisible ? null : () {
        _chatInputFocusNode.unfocus();
        setState(() => _chatVisible = true);
        _animateChatSheet(_chatRestoredSize, remember: false);
      },
      onHandleDragUpdate: (delta) {
        if (graphAreaHeight <= 0) return;
        _chatExpandedForInput = false;
        final next = (_chatSheetSize - delta / graphAreaHeight)
            .clamp(_sheetMinChildSize(context, graphAreaHeight), _sheetFocusSize)
            .toDouble();
        setState(() {
          _chatSheetSize = next;
          if (_chatVisible) _chatRestoredSize = next;
        });
      },
    );
  }

  /// 시트 밖, 화면 최하단에 항상 도킹된 입력바 — 시트 익스텐트와 무관하게
  /// 최소화 상태에서도 계속 탭 가능해야 한다.
  Widget _buildPersistentInputBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ChatInputBar(
        inputController: _chatInputController,
        busy: chatSession.busy,
        onSend: _sendChat,
        modeLabel: _modeLabel(),
        onExitMode: chatSession.exitMode,
        onModeSelected: _onModeSelected,
        inputEnabled: _inputEnabled,
        inputHint: _inputHint,
        inputBarOverride: _journalInputBar(),
        inputFocusNode: _chatInputFocusNode,
      ),
    );
  }

  Widget _buildChatSheet(
    double graphAreaHeight, {
    Map<String, Color> typeColors = const {},
    Map<String, Map<String, dynamic>> nodeById = const {},
  }) {
    _activeChatScrollController = _chatScrollController;
    // When the chat is collapsed, do not leave the sheet at its minimum
    // height. That exposed only the rounded top edge and shadow above the
    // composer. The composer is docked independently, so the chat sheet can
    // disappear completely while retaining its restored height for reopening.
    return AnimatedPositioned(
      left: 0,
      right: 0,
      bottom: 0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      // While typing, use every pixel above the keyboard. The Scaffold/SafeArea
      // viewport already excludes the IME, so this keeps the composer and the
      // latest messages visible on short and tall phones alike.
      height: !_chatVisible
          ? 0
          : (_isQuizMode || _chatExpandedForInput
              ? graphAreaHeight
              : _chatSheetSize * graphAreaHeight),
      child: IgnorePointer(
        ignoring: !_chatVisible,
        child: _buildGraphChatPanel(
          scrollController: _chatScrollController,
          graphAreaHeight: graphAreaHeight,
          typeColors: typeColors,
          nodeById: nodeById,
        ),
      ),
    );
  }

  /// 그래프 캔버스(변경 없음) + 떠 있는 오버레이(검색 필·범례 칩) + 포커스
  /// 스크림 + 상시 임베드된 채팅 시트 + 시트 밖에 도킹된 입력바. 그래프 영역
  /// 실제 높이를 LayoutBuilder로 얻어 시트 비율 계산의 기준으로 쓴다.
  /// [overlays]는 스크림 아래에 깔려 포커스 시 함께 어두워진다.
  Widget _canvasWithChat({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required Map<String, Color> typeColors,
    bool compactMode = false,
    double overlayTopInset = 8,
    List<Widget> overlays = const [],
  }) {
    final nodeById = buildNodeById(nodes);
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphAreaHeight = constraints.maxHeight;
        _chatAreaHeight = graphAreaHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            _canvasWithCard(
              nodes: nodes,
              edges: edges,
              typeColors: typeColors,
              compactMode: compactMode,
              overlayTopInset: overlayTopInset,
              selectionCardBottom: _chatSheetSize * graphAreaHeight + 12,
              controlsBottomInset: 92,
              controlsVisible: _graphToolsVisible,
            ),
            ...overlays,
            _ChatFocusScrim(
              visible: _chatFocused,
              onTap: _chatInputFocusNode.unfocus,
            ),
            _buildChatSheet(graphAreaHeight,
                typeColors: typeColors, nodeById: nodeById),
            _buildPersistentInputBar(),
          ],
        );
      },
    );
  }

  /// Tap the floating status pill: scroll to the inline progress card if it's in
  /// the feed, otherwise open the review surface directly.
  void _onStatusPillTap() {
    final entryId = journalTask.entryId;
    final hasCard = entryId != null &&
        chatSession.messages.any((m) =>
            m.kind == 'journal_progress' &&
            (m.meta?['entry_id']?.toString() == entryId));
    if (hasCard) {
      _scrollChatToBottom();
      return;
    }
    if (entryId != null) {
      openJournalReviewFallback(context, entryId);
    }
  }


  @override
  void initState() {
    super.initState();
    if (widget.initialNodeId != null) {
      _selectedNodeId = widget.initialNodeId;
    }
    _load();
    _prevJournalPhase = journalTask.phase;
    _prevComposePhase = composeSession.phase;
    _prevJournalGraphStatus = journalTask.entry?['graph_status']?.toString();
    composeSession.entriesChanged.addListener(_onEntriesChanged);
    chatSession.onReferencedNodes = _onReferencedNodes;
    chatSession.addListener(_onChatChanged);
    chatSession.errors.addListener(_onChatError);
    journalTask.addListener(_onJournalTaskChanged);
    _chatInputController.addListener(_onChatInputChanged);
    _chatInputFocusNode.addListener(_onChatFocusChanged);
    chatSession.init();
  }

  @override
  void dispose() {
    chatSession.removeListener(_onChatChanged);
    chatSession.errors.removeListener(_onChatError);
    journalTask.removeListener(_onJournalTaskChanged);
    composeSession.entriesChanged.removeListener(_onEntriesChanged);
    if (chatSession.onReferencedNodes == _onReferencedNodes) {
      chatSession.onReferencedNodes = null;
    }
    _chatInputController.removeListener(_onChatInputChanged);
    _chatInputFocusNode.removeListener(_onChatFocusChanged);
    _chatInputController.dispose();
    _chatInputFocusNode.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  /// Forward every composer keystroke to the live word-by-word cloze matcher
  /// while a word quiz is active — a match clears the composer for the next
  /// blank instead of waiting for the learner to hit send.
  void _onChatInputChanged() {
    if (chatSession.mode != ChatMode.quizWord) return;
    unawaited(chatSession.updateClozeDraft(_chatInputController.text).then((clear) {
      if (clear && mounted) _chatInputController.clear();
    }));
  }

  void _onChatChanged() {
    if (chatSession.messages.length != _lastMsgCount) {
      _lastMsgCount = chatSession.messages.length;
      _scrollChatToBottom();
    }
    final mode = chatSession.mode;
    // Quiz/distill cards render as the chat list's footer item (see
    // _chatListFooter), not a fixed bar above the input — so switching into
    // one of these modes, or loading a new card into an already-active mode,
    // must scroll the list just like a new message would.
    final enteredFooterMode = mode != _lastChatMode &&
        (mode == ChatMode.distill ||
            mode == ChatMode.quizComposition ||
            mode == ChatMode.quizWord);
    final distillReady = mode == ChatMode.distill &&
        _lastDistillLoading &&
        !chatSession.distillLoading;
    final quizId = chatSession.activeQuiz?['id']?.toString();
    final quizCardChanged =
        (mode == ChatMode.quizComposition || mode == ChatMode.quizWord) &&
            quizId != _lastActiveQuizId;
    if (enteredFooterMode || distillReady || quizCardChanged) {
      _scrollChatToBottom();
    }
    // Defensive re-focus for word quizzes generally (covers entering the
    // mode and any card change, not just the explicit "다음 문제" tap).
    // Deferred a frame: requestFocus() here runs synchronously inside
    // notifyListeners(), i.e. still against the OLD build where the composer
    // was `enabled: false` (wordQuizSolved was true for the just-finished
    // question) — EditableText only opens its platform text-input connection
    // on a focus-state TRANSITION, so focusing before the rebuild that flips
    // `enabled` to true leaves the field visually focused but not accepting
    // keystrokes. Requesting it after the next frame targets the rebuilt,
    // enabled field instead.
    if (mode == ChatMode.quizWord && quizCardChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _chatInputFocusNode.requestFocus();
      });
    }
    // A reply landing can leave the composer looking enabled but no longer
    // holding real editing focus (the field re-enables after busy, but
    // Flutter doesn't auto-restore focus) — return it to the composer so the
    // next message can be typed immediately, same as the quiz re-focus above.
    if (mode == ChatMode.normal && _lastChatBusy && !chatSession.busy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _chatInputFocusNode.requestFocus();
      });
    }
    _lastChatMode = mode;
    _lastChatBusy = chatSession.busy;
    _lastDistillLoading = chatSession.distillLoading;
    _lastActiveQuizId = quizId;
    if (mounted) setState(() {});
  }

  void _onJournalTaskChanged() {
    final graphStatus = journalTask.entry?['graph_status']?.toString() ?? '';
    _maybeReloadGraph(_prevJournalPhase, journalTask.phase);
    if (graphStatus == 'graph_ready' &&
        _prevJournalGraphStatus != 'graph_ready') {
      _scheduleGraphReload();
    }
    _prevJournalPhase = journalTask.phase;
    _prevJournalGraphStatus = graphStatus;
    if (mounted) setState(() {});
  }

  void _onEntriesChanged() {
    _maybeReloadGraph(_prevComposePhase, composeSession.phase);
    _prevComposePhase = composeSession.phase;
  }

  void _maybeReloadGraph(ComposePhase? prev, ComposePhase next) {
    if (prev != ComposePhase.done && next == ComposePhase.done) {
      _scheduleGraphReload();
    }
  }

  void _scheduleGraphReload() {
    if (_graphReloadScheduled) return;
    _graphReloadScheduled = true;
    Future.microtask(() async {
      _graphReloadScheduled = false;
      if (!mounted) return;
      await _load(silent: true);
    });
  }

  void _onChatError() {
    final msg = chatSession.errors.value;
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    chatSession.errors.value = null;
  }

  /// Canvas hook: glow the nodes an answer cited and fly the camera to them.
  void _onReferencedNodes(Set<String> ids) {
    final nodes = (_graph?['nodes'] as List? ?? [])
        .map((n) => Map<String, dynamic>.from(n as Map))
        .toList();
    final nodeById = buildNodeById(nodes);
    final known = ids.where(nodeById.containsKey).toSet();
    if (known.isEmpty || !mounted) return;
    setState(() {
      _glowIds = known;
      _glowSeq++;
    });
    _canvasKey.currentState?.focusOnNodes(known);
  }

  /// 사후 교정: 검토에서 놓친 개념/정체성을 그래프에 직접 추가한다.
  /// (이름+타입 dedupe — 같은 이름·타입이 있으면 그 노드를 재사용)
  Future<void> _addNode() async {
    final nameCtrl = TextEditingController();
    var type = 'Concept';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('노드 추가'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: '이름',
                    isDense: true,
                    border: OutlineInputBorder()),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(
                    labelText: '타입',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(
                      value: 'Concept', child: Text('개념 (Concept)')),
                  DropdownMenuItem(
                      value: 'Identity', child: Text('정체성 (Identity)')),
                  DropdownMenuItem(value: 'Person', child: Text('사람 (Person)')),
                  DropdownMenuItem(value: 'Source', child: Text('출처 (Source)')),
                ],
                onChanged: (v) => setDlgState(() => type = v ?? 'Concept'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('추가')),
          ],
        ),
      ),
    );
    final name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    try {
      await apiClient.createNode(name: name, type: type);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("'$name' 노드가 추가되었습니다.")),
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
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
          if (!silent) _loading = false;
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
          if (!silent) _loading = false;
        });
      }
    }
  }

  void _scrollChatToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _activeChatScrollController;
      if (controller == null || !controller.hasClients) return;
      final max = controller.position.maxScrollExtent;
      if (animated) {
        controller.animateTo(max,
            duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
      } else {
        controller.jumpTo(max);
      }
    });
  }

  /// Send a chat message through the global controller and clear the input.
  void _sendChat(String raw) {
    if (raw.trim().isEmpty) return;
    _chatInputController.clear();
    _scrollChatToBottom();
    chatSession.submitInput(raw);
  }

  /// The panel's clear button now deletes the active room (multi-room world).
  Future<void> _deleteActiveRoom() async {
    final id = chatSession.activeId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('채팅방 삭제'),
        content: const Text('이 채팅방의 대화를 모두 지울까요?\n지식그래프는 그대로 유지돼요.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _glowIds = const {});
    await chatSession.deleteSession(id);
  }

  // ── + 버튼 모드 시스템 ───────────────────────────────────────────────────

  void _onModeSelected(String action) {
    // Opening the mode menu must never resize the chat sheet. If the chat was
    // hidden, restore its previous height before entering a mode.
    _ensureChatVisible();
    switch (action) {
      case 'journal':
        // One journal at a time: block only a NEW journal while one is busy.
        // Quiz/distill modes stay reachable during background processing.
        if (journalTask.isBusy) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('일기 처리가 진행 중이에요 — 완료 후 새 일기를 저장할 수 있어요.'),
            ),
          );
          return;
        }
        chatSession.enterJournalMode();
        break;
      case 'distill':
        chatSession.startDistill();
        break;
      case 'composition':
        _startQuizWithLanguagePrompt('composition');
        break;
      case 'word':
        _startQuizWithLanguagePrompt('word');
        break;
    }
  }

  // Learnable target languages — kept in sync with settings_screen.dart's
  // _kLanguages (the quiz engine is only tuned for these three).
  static const _quizLanguages = [
    (key: 'english', label: '영어', flag: '🇺🇸'),
    (key: 'german', label: '독일어', flag: '🇩🇪'),
    (key: 'korean', label: '한국어', flag: '🇰🇷'),
  ];

  /// When the learner has more than one target language configured in their
  /// profile, ask which one this quiz session should draw from before
  /// starting it. With zero or one configured, skip the prompt entirely.
  Future<void> _startQuizWithLanguagePrompt(String quizType) async {
    List<String> langs = const ['english'];
    try {
      final profile = await apiClient.getUserProfile();
      final raw = profile['target_languages'];
      if (raw is List && raw.isNotEmpty) {
        langs = raw.map((e) => e.toString()).toList();
      } else {
        final single = profile['target_language']?.toString();
        if (single != null && single.isNotEmpty) langs = [single];
      }
    } catch (_) {
      // Profile fetch failed — fall back to the backend's own default.
    }

    if (langs.length <= 1) {
      chatSession.startQuiz(quizType,
          language: langs.isNotEmpty ? langs.first : null);
      return;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('어떤 언어로 퀴즈를 풀까요?',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
            for (final code in langs)
              ListTile(
                leading: Text(
                  _quizLanguages
                      .firstWhere((l) => l.key == code,
                          orElse: () => (key: code, label: code, flag: '🌐'))
                      .flag,
                  style: const TextStyle(fontSize: 20),
                ),
                title: Text(_quizLanguages
                    .firstWhere((l) => l.key == code,
                        orElse: () => (key: code, label: code, flag: '🌐'))
                    .label),
                onTap: () => Navigator.pop(ctx, code),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) {
      chatSession.startQuiz(quizType, language: chosen);
    }
  }

  String? _modeLabel() {
    switch (chatSession.mode) {
      case ChatMode.distill:
        return tr('chat.mode.distill');
      case ChatMode.quizComposition:
        return tr('chat.mode.composition');
      case ChatMode.quizWord:
        return tr('chat.mode.word');
      case ChatMode.journal:
        return tr('chat.mode.journal');
      case ChatMode.normal:
        return null;
    }
  }

  // Deliberately NOT gated on wordQuizSolved: toggling TextField.enabled
  // false→true forces Flutter to tear down and reopen the platform text-input
  // connection, and doing that right as a new question loads is what caused
  // the composer to go dead ("입력창이 막혔어" — reproduced a few questions
  // in, not the first). The actual no-typing-once-solved behavior is already
  // enforced in chat_session_controller.dart (updateClozeDraft/answerWordQuiz
  // both no-op once wordQuizSolved is true), so gating the widget too was
  // pure UX polish, not a correctness requirement — not worth the fragility.
  bool get _inputEnabled =>
      chatSession.mode != ChatMode.quizWord || chatSession.wordQuizUsesComposer;

  String get _inputHint {
    switch (chatSession.mode) {
      case ChatMode.distill:
        return tr('chat.hint.distill');
      case ChatMode.quizComposition:
        return tr('chat.hint.composition');
      case ChatMode.quizWord:
        return tr('chat.hint.word');
      case ChatMode.journal:
        return tr('chat.hint.journal');
      case ChatMode.normal:
        return tr('chat.inputHint');
    }
  }

  Widget? _journalInputBar() =>
      chatSession.mode == ChatMode.journal && !journalTask.isBusy
          ? const ChatJournalComposeBar()
          : null;

  /// Feature cards that live INSIDE the chat scroll so they grow with content and
  /// scroll up with the conversation — distill draft and the active quiz card.
  Widget? _chatListFooter() {
    switch (chatSession.mode) {
      case ChatMode.distill:
        return DistillDraftCard(
          sentences: chatSession.distillSentences,
          loading: chatSession.distillLoading,
          onToggle: chatSession.toggleDistillSentence,
          onSave: chatSession.saveDistillAsJournal,
          onCancel: chatSession.exitMode,
        );
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
                  answer: answer, order: order, selectedIndex: selectedIndex),
          onNext: () {
            chatSession.nextQuiz();
            // "다음 문제" steals focus from the composer — the next blank
            // needs typing to work immediately, not after a manual tap back.
            // Deferred a frame for the same reason as the defensive re-focus
            // in _onChatChanged: requesting focus before the rebuild that
            // flips the composer back to `enabled: true` leaves it focused
            // but not actually accepting keystrokes.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _chatInputFocusNode.requestFocus();
            });
          },
          onExit: chatSession.exitMode,
          externalResult: chatSession.quizFeedback,
          clozeSolved: chatSession.wordQuizSolved,
          clozeCompletedWords: chatSession.clozeCompletedWords,
          clozeLiveDraft: chatSession.clozeLiveDraft,
          onClozeHintRequested: () {
            _chatInputController.clear();
            // Hint/reveal-answer buttons steal focus from the composer — without
            // this, typing goes nowhere once the hint button disables itself
            // (힌트 확인됨) and there's nothing left to return focus to.
            _chatInputFocusNode.requestFocus();
          },
        );
      case ChatMode.normal:
      case ChatMode.journal:
        return null;
    }
  }

  Widget? _quizStatusCard() {
    if (chatSession.busy) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (chatSession.quizExhausted) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Text(tr('quiz.sessionDone'),
                  style: TextStyle(
                      color: context.shell.primaryText, fontSize: 13)),
            ),
            TextButton(
                onPressed: chatSession.exitMode, child: Text(tr('quiz.close'))),
            FilledButton(
              onPressed: () => chatSession.startQuiz(chatSession.quizType),
              child: Text(tr('quiz.more')),
            ),
          ],
        ),
      );
    }
    return null;
  }

  void _highlightNodes(Set<String> nodeIds) {
    setState(() {
      _glowIds = nodeIds;
      _glowSeq++;
    });
    _canvasKey.currentState?.focusOnNodes(nodeIds);
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

  /// Tap flow: select → camera glides to the node + compact info card at the
  /// bottom (the 2-hop highlight stays visible). The full inspector sheet
  /// only opens from the card's "자세히" button (or [showSheet]).
  Future<void> _selectNode(Map<String, dynamic>? node,
      {bool showSheet = false}) async {
    if (node == null) {
      _clearSelection();
      return;
    }

    // Show the card immediately with what we have; upgrade to full detail.
    setState(() {
      _selectedNode = node;
      _selectedNodeId = node['id']?.toString();
      _selectedEdge = null;
      _selectedEdgeId = null;
    });
    _canvasKey.currentState?.centerOnNode(node['id'].toString());

    Map<String, dynamic> detail = node;
    try {
      detail = await apiClient.getNode(node['id'].toString());
    } catch (_) {
      detail = Map<String, dynamic>.from(node);
    }
    if (!mounted || _selectedNodeId != detail['id']?.toString()) return;

    setState(() => _selectedNode = detail);
    if (!showSheet || !mounted) return;
    await _showInspectorSheet();
  }

  Future<void> _selectEdge(Map<String, dynamic>? edge,
      {bool showSheet = false}) async {
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
            _selectNode(n, showSheet: true);
          },
          onSelectEdge: (e) {
            Navigator.pop(ctx);
            _selectEdge(e, showSheet: true);
          },
        ),
      ),
    );
    // Closing the sheet keeps the selection (and its highlight/card) — the
    // user returns to the graph exactly where they were exploring.
  }

  /// Pin/unpin the selected Statement from the compact bottom card. Pinning
  /// generates an isolated mini-batch immediately server-side; when it comes
  /// back non-empty this jumps straight into the same inline quiz mode the
  /// "단어 퀴즈" chat button uses, seeded with exactly those generated items
  /// instead of the learner having to go find them in the queue.
  Future<void> _togglePin(Map<String, dynamic> node) async {
    if (_pinning) return;
    final nodeId = node['id'].toString();
    final nextPinned = node['is_pinned'] != true;
    setState(() => _pinning = true);
    try {
      final result = await apiClient.setNodePinned(nodeId, nextPinned);
      if (!mounted) return;
      setState(() {
        node['is_pinned'] = result['is_pinned'] ?? nextPinned;
        if (_selectedNode != null && _selectedNode!['id'].toString() == nodeId) {
          _selectedNode = {..._selectedNode!, 'is_pinned': node['is_pinned']};
        }
      });
      if (nextPinned) {
        final quizIds =
            (result['generated_quiz_ids'] as Map?)?.cast<String, dynamic>();
        final language = result['generated_language']?.toString();
        final clozeIds = ((quizIds?['cloze'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
        final compositionIds = ((quizIds?['composition'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
        if (clozeIds.isNotEmpty) {
          _ensureChatVisible();
          await chatSession.startQuiz('cloze',
              language: language, quizIds: clozeIds);
        } else if (compositionIds.isNotEmpty) {
          _ensureChatVisible();
          await chatSession.startQuiz('composition',
              language: language, quizIds: compositionIds);
        } else {
          chatSession.errors.value = tr('graph.pinEmpty');
        }
      }
    } catch (e) {
      if (mounted) {
        chatSession.errors.value = e.toString();
      }
    } finally {
      if (mounted) setState(() => _pinning = false);
    }
  }

  /// 숨김 모드에서는 head 타입 칩(Person/Speaker/Source)이 필터해도 빈
  /// 화면만 나오므로 범례 바에서 제외한다.
  List<Map<String, dynamic>> _legendEntityTypes(
    List<Map<String, dynamic>> entityTypes,
  ) {
    if (!_hideHeads) return entityTypes;
    return entityTypes
        .where((et) => !isStatementHeadType(et['name']?.toString()))
        .toList();
  }

  void _toggleHideHeads() {
    setState(() {
      _hideHeads = !_hideHeads;
      if (_hideHeads) {
        // head 타입 필터는 숨김 모드에서 빈 화면이 되므로 해제.
        if (isStatementHeadType(_typeFilter)) _typeFilter = '전체';
        // 숨겨질 head가 선택돼 있으면 선택도 해제.
        final selType = _selectedNode?['type']?.toString();
        if (selType != null && isStatementHeadType(selType)) {
          _selectedNode = null;
          _selectedNodeId = null;
        }
      }
    });
  }

  /// 숨김 모드 범례: head별 인코딩 색 + Statement 수. self 우선, 이후 수량순.
  List<SpeakerLegendEntry> _speakerLegendEntries(
    List<Map<String, dynamic>> nodes,
    List<Map<String, dynamic>> edges,
  ) {
    final colors = headColorById(nodes);
    final headIdx = statementHeadIndex(nodes, edges);
    final counts = <String, int>{};
    for (final headId in headIdx.values) {
      counts[headId] = (counts[headId] ?? 0) + 1;
    }
    final entries = <SpeakerLegendEntry>[
      for (final n in nodes)
        if (isStatementHeadType(n['type']?.toString()))
          (
            name: n['name']?.toString() ?? '?',
            color: colors[n['id'].toString()] ?? Colors.grey,
            count: counts[n['id'].toString()] ?? 0,
            isSelf: isSelfNode(n),
          ),
    ];
    entries.sort((a, b) {
      if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.name.compareTo(b.name);
    });
    return entries;
  }

  void _clearSelection() {
    setState(() {
      _selectedNode = null;
      _selectedNodeId = null;
      _selectedEdge = null;
      _selectedEdgeId = null;
    });
    // No refit: keep the camera where the user was exploring.
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
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
            ),
    );
  }

  Widget _buildEmptyWithChat() {
    final safeTop = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (context, constraints) {
        final graphAreaHeight = constraints.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            const _EmptyGraphHint(),
            // 그래프가 비어도 드로어(대화방 목록)와 테마 전환은 접근 가능해야
            // 한다 — AppBar가 사라졌으므로 이 플로팅 버튼이 유일한 통로.
            if (widget.onOpenMenu != null)
              Positioned(
                top: safeTop + 8,
                left: 12,
                child: _FloatingCircleButton(
                  tooltip: '메뉴',
                  icon: Icons.menu_rounded,
                  onTap: widget.onOpenMenu!,
                ),
              ),
            _ChatFocusScrim(
              visible: _chatFocused,
              onTap: _chatInputFocusNode.unfocus,
            ),
            _buildChatSheet(graphAreaHeight),
            _buildPersistentInputBar(),
          ],
        );
      },
    );
  }

  /// Canvas + floating selection card. [selectionCardBottom] lets a caller
  /// float the card above whatever sits below it (a bottom sheet's live
  /// extent in the full-graph chat layout; a fixed 12px in compact mode,
  /// which has no sheet). [overlayTopInset] pushes the mode toggle / speaker
  /// legend below any floating chrome (search pill + legend chips) the
  /// full-bleed layout stacks over the canvas.
  Widget _canvasWithCard({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required Map<String, Color> typeColors,
    bool compactMode = false,
    double overlayTopInset = 8,
    double selectionCardBottom = 12,
    double controlsBottomInset = 0,
    bool controlsVisible = true,
  }) {
    final nodeById = buildNodeById(nodes);
    final selected = _selectedNode ?? _selectedEdge;
    return Stack(
      fit: StackFit.expand,
      children: [
        KnowledgeGraphCanvas(
          key: _canvasKey,
          compactMode: compactMode,
          showControls: controlsVisible,
          nodes: nodes,
          edges: edges,
          typeColors: typeColors,
          selectedNodeId: _selectedNodeId,
          selectedEdgeId: _selectedEdgeId,
          controlsBottomInset: controlsBottomInset,
          highlightQuery: _query,
          typeFilter: _typeFilter,
          hideHeadNodes: _hideHeads,
          glowNodeIds: _glowIds,
          glowSeq: _glowSeq,
          onNodeTap: (node) {
            _selectNode(node);
          },
          onEdgeTap: _selectEdge,
          onBackgroundTap: () {
            _clearSelection();
          },
        ),
        // 모드 토글 — 기본 ↔ 화자 숨김(색상 인코딩).
        if (compactMode)
          Positioned(
            top: compactMode ? 26 : overlayTopInset,
            right: 12,
            child: _HideHeadsToggle(active: _hideHeads, onTap: _toggleHideHeads),
          ),
        // 화자 색상 범례: head가 안 보이는 동안 색을 해독할 유일한 단서.
        if (_hideHeads && compactMode)
          Positioned(
            top: compactMode ? 26 : overlayTopInset,
            left: 10,
            child: SpeakerColorLegendCard(
              entries: _speakerLegendEntries(nodes, edges),
            ),
          ),
        Positioned(
          left: 12,
          right: 64, // keep clear of the zoom controls
          bottom: selectionCardBottom,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.15),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: selected == null
                ? const SizedBox.shrink()
                : _SelectionInfoCard(
                    key: ValueKey(_selectedNodeId ?? _selectedEdgeId),
                    node: _selectedNode,
                    edge: _selectedEdge,
                    edges: edges,
                    nodeById: nodeById,
                    typeColors: typeColors,
                    onDetail: _showInspectorSheet,
                    onClose: _clearSelection,
                    onPin: _togglePin,
                    pinning: _pinning,
                  ),
          ),
        ),
      ],
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
          matchCount: _queryMatchCount(nodes),
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
            border:
                Border(bottom: BorderSide(color: context.shell.toolbarBorder)),
          ),
          child: OntologyLegendBar(
            entityTypes: _legendEntityTypes(entityTypes),
            typeColors: typeColors,
            selectedType: _typeFilter,
            onTypeSelected: (t) => setState(() => _typeFilter = t),
          ),
        ),
        Expanded(
          child: _canvasWithCard(
            nodes: nodes,
            edges: edges,
            typeColors: typeColors,
            compactMode: true,
          ),
        ),
      ],
    );
  }

  int? _queryMatchCount(List<Map<String, dynamic>> nodes) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return null;
    return nodes.where((n) {
      final name = n['name']?.toString().toLowerCase() ?? '';
      final desc = n['description']?.toString().toLowerCase() ?? '';
      return name.contains(q) || desc.contains(q);
    }).length;
  }

  Widget _buildFullGraph({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required List<Map<String, dynamic>> entityTypes,
    required List<String> relationTypes,
    required Map<String, Color> typeColors,
  }) {
    // Google-Maps grammar: the graph is a full-bleed background; search and
    // legend float OVER it as detached surfaces instead of stacked bars that
    // push the canvas down.
    final safeTop = MediaQuery.paddingOf(context).top;
    final pillTop = safeTop + 8;
    final chipsTop = pillTop + 58;
    return _canvasWithChat(
      nodes: nodes,
      edges: edges,
      typeColors: typeColors,
      overlayTopInset: chipsTop + 44,
      overlays: [
        if (_graphToolsVisible)
          Positioned(
            top: chipsTop,
            left: 0,
            right: 0,
            child: OntologyLegendBar(
              entityTypes: _legendEntityTypes(entityTypes),
              typeColors: typeColors,
              selectedType: _typeFilter,
              onTypeSelected: (t) => setState(() => _typeFilter = t),
            ),
          ),
        Positioned(
            top: pillTop,
            left: 12,
            right: 12,
            child: _FloatingSearchBar(
              matchCount: _queryMatchCount(nodes),
              nodeCount: nodes.length,
              edgeCount: edges.length,
              onQueryChanged: (v) => setState(() => _query = v),
              onOpenMenu: widget.onOpenMenu,
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
                MaterialPageRoute<void>(
                    builder: (_) => const GraphTrashScreen()),
              ).then((_) => _load()),
              onClearGraph: _clearGraph,
              onAddNode: _addNode,
              onToggleChat: _toggleChatVisibility,
              chatVisible: _chatVisible,
              onToggleGraphTools: () =>
                  setState(() => _graphToolsVisible = !_graphToolsVisible),
              graphToolsVisible: _graphToolsVisible,
            ),
          ),
      ],
    );
  }
}

/// Dark scrim over the graph while the composer is focused (state B) — tap
/// to unfocus and return to state A. `IgnorePointer` is essential: at
/// opacity 0 the scrim must not eat pointer events meant for the graph.
class _ChatFocusScrim extends StatelessWidget {
  const _ChatFocusScrim({required this.visible, required this.onTap});

  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: GestureDetector(
          onTap: onTap,
          child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
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
    required this.matchCount,
    required this.onQueryChanged,
    required this.onRefresh,
    required this.onOpenFullscreen,
  });

  final int nodeCount;
  final int edgeCount;
  final String query;
  final int? matchCount;
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
        border: Border(bottom: BorderSide(color: shell.toolbarBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: TextStyle(fontSize: 13, color: shell.primaryText),
              decoration: InputDecoration(
                hintText: '노드 검색…',
                hintStyle: TextStyle(color: shell.mutedText, fontSize: 13),
                prefixIcon:
                    Icon(Icons.search, size: 18, color: shell.mutedText),
                suffixText: matchCount == null ? null : '$matchCount개',
                suffixStyle: TextStyle(
                  fontSize: 11,
                  color: matchCount == 0
                      ? const Color(0xFFFF7A7A)
                      : AppColors.accent,
                ),
                filled: true,
                fillColor: shell.subtleSurface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: shell.panelBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: shell.panelBorder),
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
            style: TextStyle(fontSize: 11, color: shell.mutedText),
          ),
          IconButton(
            tooltip: '새로고침',
            visualDensity: VisualDensity.compact,
            onPressed: onRefresh,
            icon: Icon(Icons.refresh, size: 20, color: shell.mutedText),
          ),
          IconButton(
            tooltip: '전체 화면',
            visualDensity: VisualDensity.compact,
            onPressed: onOpenFullscreen,
            icon: Icon(Icons.open_in_full, size: 20, color: shell.mutedText),
          ),
        ],
      ),
    );
  }
}

/// Small circular floating action (menu button on the empty-graph state).
class _FloatingCircleButton extends StatelessWidget {
  const _FloatingCircleButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xF21A1A22) : Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: shell.panelBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.12),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          icon: Icon(icon, color: shell.primaryText),
        ),
      ),
    );
  }
}

/// Google-Maps-style floating search pill: hamburger (rooms drawer) + search
/// field + theme toggle + overflow menu, one detached rounded surface floating
/// over the full-bleed graph — replaces the old stacked AppBar+toolbar strips.
class _FloatingSearchBar extends StatelessWidget {
  const _FloatingSearchBar({
    required this.matchCount,
    required this.nodeCount,
    required this.edgeCount,
    required this.onQueryChanged,
    required this.onRefresh,
    required this.onOntology,
    required this.onTrash,
    required this.onClearGraph,
    required this.onAddNode,
    required this.onToggleChat,
    required this.chatVisible,
    required this.onToggleGraphTools,
    required this.graphToolsVisible,
    this.onOpenMenu,
  });

  final int? matchCount;
  final int nodeCount;
  final int edgeCount;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onRefresh;
  final VoidCallback onOntology;
  final VoidCallback onTrash;
  final VoidCallback onClearGraph;
  final VoidCallback onAddNode;
  final VoidCallback onToggleChat;
  final bool chatVisible;
  final VoidCallback onToggleGraphTools;
  final bool graphToolsVisible;
  final VoidCallback? onOpenMenu;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xE91A1A22) : const Color(0xF2FFFFFF);
    final hintColor = isDark ? const Color(0xFF7B8494) : AppColors.textMuted;
    return Container(
      height: 48,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: shell.panelBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: Row(
          children: [
            if (onOpenMenu != null)
              IconButton(
                tooltip: '메뉴',
                onPressed: onOpenMenu,
                icon: Icon(Icons.menu_rounded, color: shell.primaryText),
              )
            else
              Padding(
                padding: const EdgeInsets.only(left: 14, right: 2),
                child: Icon(Icons.search, size: 20, color: hintColor),
              ),
            Expanded(
              child: TextField(
                style: TextStyle(color: shell.primaryText, fontSize: 14.5),
                decoration: InputDecoration(
                  hintText: '노드 검색',
                  hintStyle: TextStyle(color: hintColor, fontSize: 14),
                  suffixText: matchCount == null ? null : '$matchCount개',
                  suffixStyle: TextStyle(
                    fontSize: 11.5,
                    color: matchCount == 0
                        ? const Color(0xFFFF7A7A)
                        : AppColors.accent,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 11),
                ),
                onChanged: onQueryChanged,
              ),
            ),
            const AppThemeToggleButton(),
            IconButton(
              tooltip: chatVisible ? '梨꾪똿 ?④湲' : '梨꾪똿 ?쒖떆',
              onPressed: onToggleChat,
              icon: Icon(
                chatVisible
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                color: shell.primaryText,
              ),
            ),
            // Destructive / rarely-used actions live behind the overflow menu
            // so they can't be fat-fingered while exploring.
            PopupMenuButton<String>(
              tooltip: '더보기',
              icon: Icon(Icons.more_vert, color: shell.primaryText),
              color: shell.barBackground,
              onSelected: (v) {
                if (v == 'ontology') onOntology();
                if (v == 'refresh') onRefresh();
                if (v == 'addNode') onAddNode();
                if (v == 'trash') onTrash();
                if (v == 'clear') onClearGraph();
                if (v == 'toggleGraphTools') onToggleGraphTools();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'toggleGraphTools',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      graphToolsVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: AppColors.textMuted,
                    ),
                    title: Text(
                      graphToolsVisible ? '그래프 도구 숨김' : '그래프 도구 표시',
                      style: TextStyle(color: shell.primaryText, fontSize: 13),
                    ),
                  ),
                ),
                PopupMenuItem(
                  enabled: false,
                  height: 32,
                  child: Text('노드 $nodeCount · 관계 $edgeCount',
                      style:
                          TextStyle(color: shell.mutedText, fontSize: 12)),
                ),
                PopupMenuItem(
                  value: 'ontology',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.category_outlined,
                        color: AppColors.textMuted),
                    title: Text('온톨로지',
                        style:
                            TextStyle(color: shell.primaryText, fontSize: 13)),
                  ),
                ),
                PopupMenuItem(
                  value: 'refresh',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const Icon(Icons.refresh, color: AppColors.textMuted),
                    title: Text('새로고침',
                        style:
                            TextStyle(color: shell.primaryText, fontSize: 13)),
                  ),
                ),
                PopupMenuItem(
                  value: 'addNode',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.add_circle_outline,
                        color: AppColors.textMuted),
                    title: Text('노드 추가',
                        style:
                            TextStyle(color: shell.primaryText, fontSize: 13)),
                  ),
                ),
                PopupMenuItem(
                  value: 'trash',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_outline,
                        color: AppColors.textMuted),
                    title: Text('휴지통',
                        style:
                            TextStyle(color: shell.primaryText, fontSize: 13)),
                  ),
                ),
                const PopupMenuItem(
                  value: 'clear',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_sweep, color: Colors.redAccent),
                    title: Text('그래프 전체 삭제',
                        style:
                            TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// 기본 모드 ↔ 화자 숨김(Speaker-to-Color) 모드 토글 필 버튼.
class _HideHeadsToggle extends StatelessWidget {
  const _HideHeadsToggle({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final fg = active ? shell.primaryText : shell.mutedText;
    return Material(
      color: active ? shell.subtleSurface : shell.panelBackground,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Tooltip(
          message:
              active ? '기본 모드로 — 화자 노드 다시 표시' : '화자 숨기기 — Statement를 화자색으로 표시',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: active ? AppColors.primary : shell.panelBorder,
                width: active ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  active ? Icons.person_off : Icons.people_alt_outlined,
                  size: 15,
                  color: fg,
                ),
                const SizedBox(width: 6),
                Text(
                  active ? '화자 숨김' : '기본 모드',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
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

/// Compact floating preview of the selected node/edge. Keeps the graph (and
/// its tier highlight) visible while answering "이게 뭐지?" at a glance; the
/// full inspector opens only on demand.
class _SelectionInfoCard extends StatelessWidget {
  const _SelectionInfoCard({
    super.key,
    required this.node,
    required this.edge,
    required this.edges,
    required this.nodeById,
    required this.typeColors,
    required this.onDetail,
    required this.onClose,
    required this.onPin,
    required this.pinning,
  });

  final Map<String, dynamic>? node;
  final Map<String, dynamic>? edge;
  final List<Map<String, dynamic>> edges;
  final Map<String, Map<String, dynamic>> nodeById;
  final Map<String, Color> typeColors;
  final VoidCallback onDetail;
  final VoidCallback onClose;
  final ValueChanged<Map<String, dynamic>> onPin;
  final bool pinning;

  /// "기록일" — when this happened, falling back to when it was written down.
  static String? _recordedDateLabel(Map<String, dynamic> n) {
    final raw = (n['occurred_at'] ?? n['entry_created_at'] ?? n['created_at'])
        ?.toString();
    if (raw == null || raw.isEmpty) return null;
    return raw.split('T').first;
  }

  /// Statement: context badge + plain content (never raw JSON).
  static ({String? contextType, String content}) _statementPreview(
      Map<String, dynamic> n) {
    if (!isStatementNode(n)) {
      final desc = n['description']?.toString().trim() ?? '';
      return (contextType: null, content: desc);
    }
    final parsed = parseStatementFromNode(n);
    return (
      contextType: parsed.hasContextType ? parsed.contextType : null,
      content: parsed.content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final n = node;
    final e = edge;

    Widget body;
    var isStatement = false;
    if (n != null) {
      final id = n['id'].toString();
      final type = n['type']?.toString() ?? '';
      final color = colorForType(type, typeColors);
      final degree = edges
          .where((ed) =>
              ed['source_id'].toString() == id ||
              ed['target_id'].toString() == id)
          .length;
      isStatement = canonicalEntityType(type).toLowerCase() == 'statement';
      final stmtPreview = isStatement ? _statementPreview(n) : null;
      final preview = stmtPreview?.content ?? '';
      // Statement 귀속 head: 화자 숨김 모드에서 노드가 안 보여도 여기서
      // 누구의 진술인지 확인할 수 있다. 점 색은 숨김 모드 인코딩색과 동일.
      final headNode =
          isStatement ? statementHeadNode(id, edges, nodeById) : null;
      final headColor = headNode == null
          ? null
          : headColorById(nodeById.values.toList())[headNode['id'].toString()];
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nodeDisplayLabel(n),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: shell.primaryText,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '$type · 연결 $degree개',
                      style: TextStyle(
                          fontSize: 11, color: color.withValues(alpha: 0.9)),
                    ),
                    if (stmtPreview?.contextType != null) ...[
                      const SizedBox(width: 6),
                      StatementContextBadge(
                        label: stmtPreview!.contextType!,
                        compact: true,
                      ),
                    ],
                    if (_recordedDateLabel(n) != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '· ${_recordedDateLabel(n)}',
                        style: TextStyle(fontSize: 11, color: shell.mutedText),
                      ),
                    ],
                  ],
                ),
                if (headNode != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: headColor ?? const Color(0xFF9CA3AF),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${isSpeakerLikeType(headNode['type']?.toString()) ? '화자' : '출처'}: ${headNode['name'] ?? '?'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: shell.mutedText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: shell.mutedText,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    } else if (e != null) {
      final src = nodeById[e['source_id'].toString()];
      final tgt = nodeById[e['target_id'].toString()];
      final srcName = src == null ? '?' : nodeDisplayLabel(src);
      final tgtName = tgt == null ? '?' : nodeDisplayLabel(tgt);
      final relation = e['relation']?.toString() ?? '';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  srcName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: shell.primaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child:
                    Icon(Icons.arrow_forward, size: 13, color: shell.mutedText),
              ),
              Flexible(
                child: Text(
                  tgtName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: shell.primaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            relation,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: shell.mutedText,
            ),
          ),
        ],
      );
    } else {
      return const SizedBox.shrink();
    }

    return Material(
      color: shell.panelBackground, // translucent chrome over the graph
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: shell.panelBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            body,
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
            if (n != null && isStatement)
              IconButton(
                tooltip: n['is_pinned'] == true ? '핀 해제' : '최우선 과제로 핀',
                visualDensity: VisualDensity.compact,
                onPressed: pinning ? null : () => onPin(n),
                icon: pinning
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: shell.mutedText,
                        ),
                      )
                    : Icon(
                        n['is_pinned'] == true
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        size: 18,
                        color: n['is_pinned'] == true
                            ? AppColors.accent
                            : shell.mutedText,
                      ),
              ),
            TextButton(
              onPressed: onDetail,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('자세히', style: TextStyle(fontSize: 12.5)),
            ),
            IconButton(
              tooltip: '닫기',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: Icon(Icons.close, size: 18, color: shell.mutedText),
            ),
              ],
            ),
          ],
        ),
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
            Icon(Icons.hub_outlined, size: 56, color: context.shell.mutedText),
            const SizedBox(height: 16),
            Text(tr('graph.emptyTitle'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              tr('graph.emptyBody'),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.shell.mutedText),
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
