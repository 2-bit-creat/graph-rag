import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../chat/chat_mode_cards.dart';
import '../chat/chat_session_controller.dart';
import '../chat/chat_suggestions.dart';
import '../chat/journal_task_controller.dart';
import '../compose/compose_session_controller.dart';
import '../l10n/app_strings.dart';
import '../l10n/languages.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart';
import '../utils/image_file_import.dart';
import '../utils/keep_keyboard_on_tap.dart';
import '../utils/statement_display.dart';
import '../widgets/graph_chat_panel.dart';
import '../widgets/graph_inspector_panel.dart';
import '../widgets/knowledge_graph_canvas.dart';
import '../widgets/measure_size.dart';
import '../widgets/mention_editor_core.dart' show MentionAutocompleteFieldState;
import '../widgets/ocr_review_sheet.dart';
import '../widgets/ontology_settings_sheet.dart';
import '../widgets/quiz/cloze_quiz_card.dart';
import '../widgets/thinking_orbs.dart';
import 'graph_trash_screen.dart';
import 'quiz_deck_screen.dart';

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
        title: Text(tr('kg.title')),
        actions: [
          IconButton(
            tooltip: tr('kg.storageInfoTooltip'),
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(tr('kg.storageDialogTitle')),
                content: Text(tr('kg.storageDialogBody')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(tr('common.close'))),
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

class _KnowledgeGraphViewState extends State<KnowledgeGraphView>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _graph;
  Map<String, dynamic>? _ontology;
  bool _loading = true;
  String? _error;
  String _typeFilter = kAllTypesFilter;
  String _query = '';
  String? _selectedNodeId;
  String? _selectedEdgeId;
  Map<String, dynamic>? _selectedNode;
  Map<String, dynamic>? _selectedEdge;
  Map<String, dynamic>? _selectedStudyQuizzes;
  bool _selectedStudyLoading = false;
  bool _selectedRegenerating = false;
  bool _selectedGenerating = false;
  Timer? _selectedStudyPollTimer;
  final _canvasKey = GlobalKey<KnowledgeGraphCanvasState>();
  // 화자 숨김(Speaker-to-Color) 모드: head 노드를 물리에서 제거하고
  // Statement를 화자색으로 인코딩 — 슈퍼노드(성게) 뭉침 해소용.
  bool _hideHeads = false;

  // ── 그래프 대화 (전역 chatSession 컨트롤러 구독) ─────────────────────────
  final _chatInputController = TextEditingController();

  /// Reaches the journal composer's mention field — the only way to put text
  /// there, since that field owns its own controller (see ChatInputBar).
  final _journalFieldKey = GlobalKey<MentionAutocompleteFieldState>();
  final _chatInputFocusNode = FocusNode();
  final _clozeCardKey = GlobalKey<ClozeQuizCardState>();

  /// So the word-quiz hint button's on-screen rect can be published to the DOM
  /// focus guard — see the note on [_wordQuizComposerActions].
  final _wordQuizHintButtonKey = GlobalKey();

  /// Measured height of the docked composer, so the feed can pad its tail by
  /// exactly that much.
  ///
  /// A notifier, not a field behind setState. The composer's height changes as
  /// the draft wraps, and rebuilding this whole screen for that also rebuilt
  /// the composer — which on iOS Safari drops the field's native input
  /// connection, so the keyboard closed mid-sentence while Flutter still
  /// believed the field was focused. Picking a speaker hit it every time
  /// because inserting "@이름 " is what pushes the text onto the next line.
  ///
  /// Only the parts that actually read the height listen now, and none of them
  /// contain the field.
  final _inputBarHeight = ValueNotifier<double>(96);

  /// Runs while [_pinChatToBottom] keeps the feed glued to its tail.
  Timer? _bottomPinTimer;
  Timer? _chatPeekTimer;
  bool _chatPeekThrough = false;
  Set<String> _glowIds = const {};
  int _glowSeq = 0;
  // Dual view: "오늘" lights up the nodes behind today's due cards and hands
  // exactly those quiz ids to the deck, so the highlight and the deck can
  // never disagree about what "today" means.
  bool _todayMode = false;
  bool _todayLoading = false;
  List<Map<String, dynamic>> _todayItems = const [];
  // Textract answers in a couple of seconds, but on a slow phone connection the
  // upload alone is long enough that a silent UI reads as a dead tap.
  bool _ocrBusy = false;
  int _lastMsgCount = 0;
  ChatMode _lastChatMode = ChatMode.normal;
  bool _lastChatBusy = false;
  bool _lastDistillLoading = false;
  bool _lastWordQuizSolved = false;
  String? _lastActiveQuizId;

  /// Which chat room is on screen — see _onChatSessionSwitched. Null until the
  /// first room loads, so opening the app is not mistaken for a room switch.
  String? _lastSessionId;
  ComposePhase? _prevJournalPhase;
  ComposePhase? _prevComposePhase;
  String? _prevJournalGraphStatus;
  bool _wasGraphReviewPending = false;
  bool _graphReloadScheduled = false;
  bool _quizStarting = false;

  // ── 바텀시트 (지도 앱 스타일: 40% 기본 / 90% 포커스 / 최소화-입력줄만) ────
  final _chatScrollController = ScrollController();
  double _chatAreaHeight = 1;
  double _chatSheetSize = _sheetDefaultSize;
  double _chatRestoredSize = _sheetDefaultSize;
  bool _graphToolsVisible = true;
  bool _chatExpandedForInput = false;
  bool _chatManuallySized = false;
  bool get _isQuizMode =>
      chatSession.mode == ChatMode.quizWord ||
      chatSession.mode == ChatMode.quizComposition;
  bool get _isJournalMode => chatSession.mode == ChatMode.journal;
  static const double _sheetDefaultSize = 0.40; // 상태 A
  static const double _sheetFocusSize = 0.90; // 상태 B
  double _wordQuizContentHeight = 0;
  bool _chatFocused = false; // 스크림 표시 여부 — 포커스에서만 파생, 수동 드래그와 무관

  /// 시트의 `builder`가 매 build마다 새로 넘겨주는 컨트롤러 — 프로그램적 스크롤은
  /// 항상 "현재 살아있는" 컨트롤러를 대상으로 해야 한다.
  ScrollController? _activeChatScrollController;

  /// 최소 시트 크기(상태 C) — 도킹된 입력바 실측 높이 기준.
  ///
  /// [handleClearance]만큼 여유를 더 얹는다 — 이게 없으면 시트를 끝까지
  /// 내렸을 때 드래그 핸들(회색 바)이 시트 밖에 독립적으로 도킹된 입력바
  /// 뒤로 완전히 가려져 "최소화해도 잡을 손잡이가 안 보이는" 상태가 된다.
  /// 최소 높이를 입력바 높이보다 더 크게 잡아, 핸들이 항상 입력바 위로
  /// 분명한 간격을 두고 보이도록 한다.
  ///
  /// 여기서 [_inputBarHeight] 실측값을 쓰는 것이 핵심이다. 예전에는 64.0
  /// 상수였는데, 새 채팅은 메시지가 비어 제안 칩 레일이 입력바에 붙으므로
  /// (see _buildPersistentInputBar) 실제 높이가 그 상수를 훌쩍 넘는다. 그
  /// 차이만큼 시트가 입력바 아래로 내려가, 정확히 이 주석이 막으려던 상태 —
  /// 새 채팅을 열면 손잡이가 아예 안 보이는 상태 — 가 됐다.
  double _sheetMinChildSize(BuildContext context, double graphAreaHeight) {
    const handleClearance = 32.0;
    final minPx = _inputBarHeight.value +
        handleClearance +
        MediaQuery.paddingOf(context).bottom;
    if (graphAreaHeight <= 0) return 0.08;
    return (minPx / graphAreaHeight).clamp(0.06, _sheetDefaultSize - 0.02);
  }

  /// The keyboard opening shrinks the feed by its full height. Without pulling
  /// the scroll offset along, everything the user was looking at — including the
  /// newest message — stays where it was and ends up behind the composer.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_chatInputFocusNode.hasFocus) _pinChatToBottom();
  }

  /// Hold the feed at its bottom for a short window instead of scrolling once.
  ///
  /// A single scroll can't land this: focusing the composer starts a 220ms
  /// sheet resize *and* the keyboard inset arrives a frame or more later, so
  /// `maxScrollExtent` keeps moving after any one-shot `animateTo` finishes —
  /// which is exactly why the newest message stayed parked under the keyboard
  /// and had to be dragged up by hand.
  void _pinChatToBottom({Duration window = const Duration(milliseconds: 700)}) {
    void stick() {
      final c = _activeChatScrollController;
      if (c == null || !c.hasClients) return;
      final max = c.position.maxScrollExtent;
      if ((c.position.pixels - max).abs() > 0.5) c.jumpTo(max);
    }

    _bottomPinTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) => stick());
    final deadline = DateTime.now().add(window);
    _bottomPinTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      if (!mounted || DateTime.now().isAfter(deadline)) {
        t.cancel();
        _bottomPinTimer = null;
        return;
      }
      stick();
    });
  }

  void _onChatFocusChanged() {
    final focused = _chatInputFocusNode.hasFocus;
    if (focused) {
      setState(() {
        _chatFocused = true;
        _chatExpandedForInput = true;
        _chatManuallySized = false;
      });
      _animateChatSheet(_sheetFocusSize);
      _pinChatToBottom();
      return;
    }

    // Losing focus should not collapse the chat. A downward drag is the
    // explicit user action that restores the normal sheet height.
    if (_chatFocused) setState(() => _chatFocused = false);
  }

  void _animateChatSheet(double target) {
    final min = _sheetMinChildSize(context, _chatAreaHeight);
    final next = target.clamp(min, _sheetFocusSize).toDouble();
    if (next > min + 0.01) {
      _chatRestoredSize = next;
    }
    setState(() {
      _chatSheetSize = next;
    });
  }

  /// 핀 성공 등으로 채팅을 눈에 띄게 해야 할 때 — 이미 40% 이상이면 그대로 둔다.
  void _ensureChatVisible() {
    // The chat remains available; its height is controlled by dragging.
  }

  void _expandChatForInput() {
    if (mounted) {
      setState(() {
        _chatExpandedForInput = true;
        _chatManuallySized = false;
        _chatSheetSize = _sheetFocusSize;
      });
    }
  }

  void _activateInputMode() {
    _expandChatForInput();
    // Let the actual TextField tap establish the browser's native IME
    // connection. Calling TextInput.show manually can throw an
    // unexpected-null error in Flutter web on iOS Safari.
    _chatInputFocusNode.requestFocus();
    for (final delay in const [
      Duration(milliseconds: 80),
      Duration(milliseconds: 280),
      Duration(milliseconds: 600),
    ]) {
      Future<void>.delayed(delay, () {
        if (!mounted) return;
        _chatInputFocusNode.requestFocus();
        _pinChatToBottom(window: const Duration(milliseconds: 180));
      });
    }
  }

  /// Word quizzes must enter with an unfocused composer on iOS Safari.
  /// Programmatic focus before/after the async quiz request can leave Flutter
  /// believing the field is focused while the browser has no editable DOM
  /// connection. A real tap on the TextField can only recreate that connection
  /// when the FocusNode is not already holding stale focus.
  void _prepareWordQuizInput() {
    _expandChatForInput();
    _chatInputFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// End an input-owning mode without leaving a stale browser text connection.
  /// This is especially important after a composition answer: the field may
  /// still look focused after the quiz card has been removed.
  void _exitInputMode() {
    _chatInputFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    chatSession.exitMode();
  }

  /// Recreate the platform text-input connection after an async mode switch.
  /// On iOS Safari a request made while the old quiz is still busy can leave
  /// the Flutter field focused but with no keyboard to bring back on tap.
  void _restoreComposerFocusAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_inputEnabled) return;
      _chatInputFocusNode.unfocus();
      FocusScope.of(context).requestFocus(_chatInputFocusNode);
      _pinChatToBottom(window: const Duration(milliseconds: 180));
    });
  }

  Widget _buildGraphChatPanel({
    required ScrollController scrollController,
    required double graphAreaHeight,
    Map<String, Color> typeColors = const {},
    Map<String, Map<String, dynamic>> nodeById = const {},
  }) {
    // Only the feed rebuilds when the composer's height changes. The composer
    // is a sibling of this subtree (_buildPersistentInputBar), so it stays put
    // — which is the point: rebuilding it is what closed the keyboard.
    return ValueListenableBuilder<double>(
      valueListenable: _inputBarHeight,
      builder: (context, barHeight, _) => _graphChatPanel(
        scrollController: scrollController,
        graphAreaHeight: graphAreaHeight,
        typeColors: typeColors,
        nodeById: nodeById,
        listBottomInset: barHeight,
      ),
    );
  }

  Widget _graphChatPanel({
    required ScrollController scrollController,
    required double graphAreaHeight,
    required Map<String, Color> typeColors,
    required Map<String, Map<String, dynamic>> nodeById,
    required double listBottomInset,
  }) {
    return GraphChatPanel(
      messages: chatSession.messages,
      busy: chatSession.busy,
      typeColors: typeColors,
      nodeById: nodeById,
      scrollController: scrollController,
      title: (chatSession.activeSession?['title'] as String?)?.trim(),
      // The spark marks every cited node; _selectNode aims the camera at the
      // tapped one, so this must not aim it too.
      onNodeHighlight: nodeById.isEmpty
          ? (_) {}
          : (ids) => _highlightNodes(ids, moveCamera: false),
      // Tap = go there and stay selected; "열기" = that plus the full inspector.
      onNodeFocus: nodeById.isEmpty ? (_) {} : (node) => _selectNode(node),
      onNodeSelect: nodeById.isEmpty
          ? (_) {}
          : (node) => _selectNode(node, showSheet: true),
      onClearHistory: _deleteActiveRoom,
      listFooter: _chatListFooter(),
      quizMode: _isQuizMode,
      listBottomInset: listBottomInset,
      onHandleDragUpdate: (delta) {
        if (graphAreaHeight <= 0) return;
        _chatExpandedForInput = false;
        _chatManuallySized = true;
        final standardMin = _sheetMinChildSize(context, graphAreaHeight);
        // A long question now scrolls inside the quiz card. Do not make its
        // full natural height the sheet minimum: reserve a comfortable reading
        // viewport instead, so short cards remain compact and long cards stay
        // usable without forcing an oversized sheet.
        const quizReadViewportMin = 220.0;
        const quizReadViewportMax = 340.0;
        const quizChromeReserve = 86.0;
        final readableQuizHeight = _wordQuizContentHeight <= 0
            ? quizReadViewportMin
            : _wordQuizContentHeight
                .clamp(quizReadViewportMin, quizReadViewportMax)
                .toDouble();
        final wordQuizMin =
            ((readableQuizHeight + _inputBarHeight.value + quizChromeReserve) /
                    graphAreaHeight)
                .clamp(standardMin, _sheetFocusSize)
                .toDouble();
        final minSheetSize =
            chatSession.mode == ChatMode.quizWord ? wordQuizMin : standardMin;
        final next = (_chatSheetSize - delta / graphAreaHeight)
            .clamp(minSheetSize, _sheetFocusSize)
            .toDouble();
        setState(() {
          _chatSheetSize = next;
          _chatRestoredSize = next;
        });
      },
    );
  }

  /// 시트 밖, 화면 최하단에 항상 도킹된 입력바 — 시트 익스텐트와 무관하게
  /// 최소화 상태에서도 계속 탭 가능해야 한다.
  Widget _buildPersistentInputBar() {
    // Journal mode now reuses this same docked pill (mention field + mic/
    // attach) instead of a separate composer card, so it's never hidden here.
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: MeasureSize(
        onChange: (size) {
          if (!mounted || size.height == _inputBarHeight.value) return;
          final grew = size.height > _inputBarHeight.value;
          // Sampled before the rebuild: the feed's tail padding is derived
          // from this height, so a bar that grows (the suggestion rail
          // appearing, the input wrapping to a second line) pushes the tail
          // down *under* the bar unless the scroll offset follows it.
          final c = _activeChatScrollController;
          final wasAtBottom = c != null &&
              c.hasClients &&
              c.position.maxScrollExtent - c.position.pixels < 24;
          _inputBarHeight.value = size.height;
          // Not while the composer is focused. The pin jumpTo()s the feed every
          // 16ms for a quarter second, and on iOS Safari that scroll churn
          // takes the keyboard down with it — the field keeps Flutter-side
          // focus but loses the native input connection behind it.
          //
          // It reproduced exactly where the composer can still grow: picking a
          // speaker on lines 1-3 dismissed the keyboard, line 4 onwards did
          // not, because past the height cap the field scrolls internally, the
          // measured height stops changing, and this never runs.
          //
          // Nothing is lost by skipping it. The pin exists so a grown bar does
          // not hide the feed's last message — a reading concern. Someone mid
          // sentence is looking at what they are typing, and the feed is
          // re-pinned on the next focus change anyway (_onChatFocusChanged).
          if (grew && wasAtBottom && !_chatInputFocusNode.hasFocus) {
            _pinChatToBottom(window: const Duration(milliseconds: 260));
          }
        },
        child: ChatInputBar(
          inputController: _chatInputController,
          busy: chatSession.busy,
          onSend: _sendChat,
          modeLabel: _modeLabel(),
          onExitMode: _exitInputMode,
          modeActions: _wordQuizComposerActions(),
          onModeSelected: _onModeSelected,
          inputEnabled: _inputEnabled,
          inputHint: _inputHint,
          journalMode: _isJournalMode,
          journalFieldKey: _journalFieldKey,
          inputFocusNode: _chatInputFocusNode,
          suggestions: _quizStarting
              ? const []
              : chatSuggestionsFor(
                  mode: chatSession.mode,
                  messages: chatSession.messages,
                  busy: chatSession.busy,
                  journalBusy: journalTask.systemProcessing,
                ),
          onSuggestionPrompt: _sendSuggestion,
        ),
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
      // While typing, use every pixel above the keyboard. graphAreaHeight comes
      // from a LayoutBuilder inside the Scaffold body, so it already excludes
      // the IME — on web that only holds because KeyboardInsetScope injects the
      // measured keyboard height into MediaQuery (see utils/keyboard_inset.dart);
      // without it the browser reports no inset and the keyboard covers the feed.
      height: (_chatExpandedForInput && !_chatManuallySized)
          ? graphAreaHeight
          : _chatSheetSize * graphAreaHeight,
      child: AnimatedOpacity(
        opacity: _chatPeekThrough ? 0.18 : 1,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        child: IgnorePointer(
          ignoring: false,
          child: _buildGraphChatPanel(
            scrollController: _chatScrollController,
            graphAreaHeight: graphAreaHeight,
            typeColors: typeColors,
            nodeById: nodeById,
          ),
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
            ValueListenableBuilder<double>(
              valueListenable: _inputBarHeight,
              builder: (context, barHeight, child) => Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                // The panel itself is intentionally translucent. The mask must
                // be wider and end in an opaque version of that color, otherwise
                // the final bubble still ghosts through above the composer.
                height: barHeight + 56,
                child: child!,
              ),
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        context.shell.panelBackground.withValues(alpha: 0),
                        context.shell.panelBackground.withValues(alpha: 0.96),
                        context.shell.panelBackground.withValues(alpha: 1),
                      ],
                      stops: const [0, 0.46, 0.78],
                    ),
                  ),
                ),
              ),
            ),
            _buildPersistentInputBar(),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialNodeId != null) {
      _selectedNodeId = widget.initialNodeId;
    }
    _load();
    _prevJournalPhase = journalTask.phase;
    _prevComposePhase = composeSession.phase;
    _prevJournalGraphStatus = journalTask.entry?['graph_status']?.toString();
    _wasGraphReviewPending = _isLiveGraphReviewPending;
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
    _bottomPinTimer?.cancel();
    _chatPeekTimer?.cancel();
    _selectedStudyPollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    chatSession.removeListener(_onChatChanged);
    chatSession.errors.removeListener(_onChatError);
    journalTask.removeListener(_onJournalTaskChanged);
    composeSession.entriesChanged.removeListener(_onEntriesChanged);
    if (chatSession.onReferencedNodes == _onReferencedNodes) {
      chatSession.onReferencedNodes = null;
    }
    _chatInputController.removeListener(_onChatInputChanged);
    _chatInputFocusNode.removeListener(_onChatFocusChanged);
    if (_hintButtonRectPublished) keepKeyboardOverRect(null);
    _chatInputController.dispose();
    _chatInputFocusNode.dispose();
    _chatScrollController.dispose();
    _inputBarHeight.dispose();
    super.dispose();
  }

  /// Forward every composer keystroke to the live word-by-word cloze matcher
  /// while a word quiz is active — a match clears the composer for the next
  /// blank instead of waiting for the learner to hit send.
  void _onChatInputChanged() {
    if (chatSession.mode != ChatMode.quizWord) return;
    unawaited(chatSession
        .updateClozeDraft(
      _chatInputController.text,
      hintLevel: _clozeCardKey.currentState?.telemetryHintLevel ?? 0,
      revealedTokens:
          _clozeCardKey.currentState?.telemetryRevealedTokens ?? const [],
      answerRevealed:
          _clozeCardKey.currentState?.telemetryAnswerRevealed ?? false,
    )
        .then((clear) {
      if (clear && mounted) _chatInputController.clear();
    }));
  }

  /// Entering a different chat room resets the two things that are properties of
  /// the room being READ, not of the app: how tall the sheet is, and who holds
  /// the keyboard.
  ///
  /// Neither used to happen. A sheet dragged down to its minimum stayed there
  /// (`_chatManuallySized` latches on drag and nothing cleared it), so opening a
  /// new chat showed a sliver behind the input bar. And focus was simply lost —
  /// the sidebar that created the room closed and took the keyboard with it,
  /// while the reflow below only re-focuses after a reply lands, never on a new
  /// room. That is the "새 채팅 후 키보드가 안 올라온다" report.
  void _onChatSessionSwitched() {
    final id = chatSession.activeSession?['id']?.toString();
    if (id == _lastSessionId) return;
    final isFirstRoomOfSession = _lastSessionId == null;
    _lastSessionId = id;
    if (isFirstRoomOfSession) return; // opening the app, not switching rooms

    setState(() {
      _chatManuallySized = false;
      _chatExpandedForInput = false;
      // Back to the last height the user actually chose, not to whatever
      // minimum they left the previous room at.
      _chatSheetSize = _chatRestoredSize > _sheetDefaultSize
          ? _chatRestoredSize
          : _sheetDefaultSize;
    });
    // unfocus-then-refocus, not a bare requestFocus: on iOS Safari the node can
    // still believe it is focused while the browser has thrown the editable DOM
    // element away, and only recreating the connection brings the keyboard back.
    _restoreComposerFocusAfterBuild();
  }

  void _onChatChanged() {
    if (chatSession.messages.length != _lastMsgCount) {
      _lastMsgCount = chatSession.messages.length;
      _scrollChatToBottom();
    }
    _onChatSessionSwitched();
    final mode = chatSession.mode;
    // Entering journal mode (incl. from the timeline "+", which returns home
    // and flips the mode) — make sure the chat is showing and scroll to the
    // inline compose card so it's immediately in view.
    if (mode == ChatMode.journal && _lastChatMode != ChatMode.journal) {
      _ensureChatVisible();
    }
    // Quiz/distill/journal cards render as the chat list's footer item (see
    // _chatListFooter), not a fixed bar above the input — so switching into
    // one of these modes, or loading a new card into an already-active mode,
    // must scroll the list just like a new message would.
    final enteredFooterMode = mode != _lastChatMode &&
        (mode == ChatMode.distill ||
            mode == ChatMode.quizComposition ||
            mode == ChatMode.quizWord ||
            mode == ChatMode.journal);
    final distillReady = mode == ChatMode.distill &&
        _lastDistillLoading &&
        !chatSession.distillLoading;
    final quizId = chatSession.activeQuiz?['id']?.toString();
    final quizCardChanged =
        (mode == ChatMode.quizComposition || mode == ChatMode.quizWord) &&
            quizId != _lastActiveQuizId;
    final wordQuizJustSolved = mode == ChatMode.quizWord &&
        chatSession.wordQuizSolved &&
        !_lastWordQuizSolved;
    if (enteredFooterMode || distillReady || quizCardChanged) {
      _scrollChatToBottom();
    }
    if (enteredFooterMode && mode == ChatMode.journal) {
      _restoreComposerFocusAfterBuild();
    }
    if (wordQuizJustSolved) {
      // The next action is explicitly "Next question", so retaining the
      // composer focus only steals vertical space from the answer state.
      // Hide the platform IME as well as releasing Flutter focus; the latter
      // alone does not reliably dismiss iOS Safari's keyboard.
      _chatInputFocusNode.unfocus();
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
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
    _lastWordQuizSolved =
        mode == ChatMode.quizWord && chatSession.wordQuizSolved;
    _lastActiveQuizId = quizId;
    if (mounted) setState(() {});
  }

  void _onJournalTaskChanged() {
    final graphStatus = journalTask.entry?['graph_status']?.toString() ?? '';
    final graphReviewPending = _isLiveGraphReviewPending;
    final graphReviewJustBecameReady =
        graphReviewPending && !_wasGraphReviewPending;
    _maybeReloadGraph(_prevJournalPhase, journalTask.phase);
    if (graphStatus == 'graph_ready' &&
        _prevJournalGraphStatus != 'graph_ready') {
      _scheduleGraphReload();
    }
    _prevJournalPhase = journalTask.phase;
    _prevJournalGraphStatus = graphStatus;
    _wasGraphReviewPending = graphReviewPending;
    if (mounted) setState(() {});
    if (graphReviewJustBecameReady) {
      // The progress card is already in the feed; it grows in place when the
      // graph draft becomes reviewable. Keep following its new bottom while
      // that expanded content lays out so the required action is never hidden.
      _scrollChatToBottom(animated: false);
      _pinChatToBottom(window: const Duration(milliseconds: 1200));
    }
  }

  bool get _isLiveGraphReviewPending =>
      journalTask.phase == ComposePhase.needsInput &&
      !journalTask.speakerReviewOverride &&
      !journalTask.awaitingSpeakerAck &&
      isGraphReviewPending(journalTask.entry);

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

  // ── Dual view: 그래프 ↔ 오늘 복습 ────────────────────────────────────────

  /// Load today's due cards and glow the graph nodes they were built from.
  ///
  /// Due-ness is decided here rather than server-side because the review queue
  /// endpoint is a plain listing; filtering on the client keeps this a single
  /// read with no new endpoint, and the resulting quiz ids are handed straight
  /// to the deck so both views agree on the set.
  Future<void> _toggleTodayMode() async {
    if (_todayMode) {
      setState(() {
        _todayMode = false;
        _todayItems = const [];
        _glowIds = const {};
        _glowSeq++;
      });
      return;
    }

    setState(() {
      _todayMode = true;
      _todayLoading = true;
    });
    try {
      final data = await apiClient.listQuizQueueItems(
        queueKind: 'review',
        limit: 200,
      );
      final now = DateTime.now();
      final due = (data['items'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .where((item) {
        final raw = item['next_review_at']?.toString();
        if (raw == null || raw.isEmpty) return true;
        final at = DateTime.tryParse(raw);
        return at == null || !at.toLocal().isAfter(now);
      }).toList();

      final nodeIds = <String>{};
      for (final item in due) {
        final ids = item['source_node_ids'];
        if (ids is List) nodeIds.addAll(ids.map((e) => e.toString()));
      }
      if (!mounted) return;
      setState(() {
        _todayItems = due;
        _todayLoading = false;
        _glowIds = nodeIds;
        _glowSeq++;
      });
      if (nodeIds.isNotEmpty) {
        _canvasKey.currentState?.focusOnNodes(nodeIds);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _todayLoading = false;
        _todayMode = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('quizDeck.loadFailed', {'error': e}))),
      );
    }
  }

  Future<void> _startTodayDeck() async {
    if (_todayItems.isEmpty) return;
    // The deck mixes types; cloze is the deck-friendly default and the ids
    // pin the selection regardless of the type filter build_session applies.
    await Navigator.push(
      context,
      QuizDeckScreen.route(
        quizType: 'cloze',
        quizIds: _todayItems.map((e) => e['id'].toString()).toList(),
      ),
    );
    if (!mounted || !_todayMode) return;
    // Re-read so cards graded in the deck drop out of today's set.
    setState(() => _todayMode = false);
    await _toggleTodayMode();
  }

  /// 사후 교정: 검토에서 놓친 개념/정체성을 그래프에 직접 추가한다.
  /// (이름+타입 dedupe — 같은 이름·타입이 있으면 그 노드를 재사용)
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
        // 진술을 수정하면 기존 문제·표현이 즉시 보관으로 넘어간다. 카드의
        // 문제 수와 재생성 버튼이 그 결과를 바로 반영하도록 다시 읽는다.
        final selectedId = _selectedNodeId;
        if (selectedId != null &&
            _selectedNode != null &&
            isStatementNode(_selectedNode!)) {
          unawaited(_loadSelectedStudyQuizzes(selectedId));
        }
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

  /// A tapped suggestion chip. Same path as typing it, but the chat is
  /// surfaced first — chips are reachable while the sheet is minimized, and a
  /// reply arriving into a hidden feed would look like nothing happened.
  void _sendSuggestion(String text) {
    _ensureChatVisible();
    _sendChat(text);
  }

  /// The panel's clear button now deletes the active room (multi-room world).
  Future<void> _deleteActiveRoom() async {
    final id = chatSession.activeId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('kg.deleteRoomTitle')),
        content: Text(tr('kg.deleteRoomBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('common.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _glowIds = const {});
    await chatSession.deleteSession(id);
  }

  // ── + 버튼 모드 시스템 ───────────────────────────────────────────────────

  void _onModeSelected(String action) async {
    // Opening the mode menu must never resize the chat sheet. If the chat was
    // hidden, restore its previous height before entering a mode.
    _ensureChatVisible();
    final opensLanguagePicker = action == 'composition' || action == 'word';
    if (opensLanguagePicker) {
      // Do not layer a language picker over a previous mode or an already-open
      // iOS keyboard. Starting another quiz is equivalent to closing the old
      // one first, then opening the new chooser.
      if (chatSession.mode != ChatMode.normal) _exitInputMode();
      _chatInputFocusNode.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;
    }
    switch (action) {
      case 'journal':
        // One journal at a time, but only while the backend is actually
        // working. An entry parked on a review gate is set aside by
        // enterJournalMode instead of blocking — see _claimJournalPipeline.
        if (journalTask.systemProcessing) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('kg.journalBusySnackbar')),
            ),
          );
          return;
        }
        _activateInputMode();
        chatSession.enterJournalMode();
        break;
      case 'ocr':
        await _importFromPhoto();
        break;
      case 'distill':
        _activateInputMode();
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

  // ── 사진에서 글자 가져오기 (OCR) ──────────────────────────────────────────

  /// Photo → text → the journal composer. Stops there deliberately: the learner
  /// edits the recognised text and drives the normal extract/commit flow
  /// themselves, so a misread word never becomes a graph claim silently.
  ///
  /// A chat screenshot comes back as "@이름: 발화" lines, which register as
  /// speaker badges the moment they land in the field. Anything else comes back
  /// as plain text and belongs to 나 until the learner says otherwise — the
  /// composer never guesses a speaker from punctuation.
  Future<void> _importFromPhoto() async {
    // Same gate as the 'journal' menu action: this ends in journal mode, and
    // finding that out after the OCR call would waste a paid request.
    if (journalTask.systemProcessing) {
      _snack(tr('kg.journalBusySnackbar'));
      return;
    }

    final picked = await pickImageFile();
    if (!mounted || picked.isCancelled) return;

    if (picked.rejection != null) {
      _snack(switch (picked.rejection!) {
        ImageRejection.empty => tr('ocr.errorEmpty'),
        ImageRejection.tooLarge => tr('ocr.errorTooLarge'),
        ImageRejection.unsupportedFormat => tr('ocr.errorUnsupported'),
      });
      return;
    }

    final file = picked.file!;
    setState(() => _ocrBusy = true);
    Map<String, dynamic> result;
    try {
      result = await apiClient.ocrImage(
        file.bytes,
        filename: file.name,
        mimeType: file.mimeType,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _ocrBusy = false);
        _snack(tr('ocr.errorFailed', {'error': e}));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _ocrBusy = false);

    final text = result['text']?.toString() ?? '';
    if (text.trim().isEmpty) {
      _snack(tr('ocr.errorNoText'));
      return;
    }

    final confirmed = await OcrReviewSheet.show(
      context,
      initialText: text,
      speakers: (result['speakers'] as List?)?.map((e) => '$e').toList() ??
          const <String>[],
    );
    if (!mounted || confirmed == null || confirmed.isEmpty) return;

    _ensureChatVisible();
    _activateInputMode();
    chatSession.enterJournalMode();
    // The mention field is built by the rebuild that journal mode triggers, so
    // its state does not exist yet on this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _journalFieldKey.currentState?.setText(confirmed);
      _chatInputFocusNode.requestFocus();
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static List<({String key, String label, String flag})> get _quizLanguages =>
      kTargetLanguages;

  /// When the learner has more than one target language configured in their
  /// profile, ask which one this quiz session should draw from before
  /// starting it. With zero or one configured, skip the prompt entirely.
  Future<void> _startQuizWithLanguagePrompt(String quizType) async {
    if (mounted) setState(() => _quizStarting = true);
    try {
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
        // A quiz is entered after an asynchronous request. Do not retain (or
        // manufacture) composer focus across that transition: on mobile web it
        // can leave Flutter with a stale focus node that no longer owns a real
        // native text-input connection. The learner's next tap restores the
        // keyboard normally for both composition and word quizzes.
        _prepareWordQuizInput();
        await chatSession.startQuiz(quizType,
            language: langs.isNotEmpty ? langs.first : null);
        _prepareWordQuizInput();
        return;
      }
      if (!mounted) return;
      final chosen = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('kg.quizLanguagePrompt'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
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
        _prepareWordQuizInput();
        await chatSession.startQuiz(quizType, language: chosen);
        _prepareWordQuizInput();
      }
    } finally {
      if (mounted) setState(() => _quizStarting = false);
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
  // A confirmed answer has no valid text input. Disabling the field prevents
  // a tap from reopening the IME and shrinking the completed card.
  bool get _inputEnabled =>
      chatSession.mode != ChatMode.quizWord ||
      (chatSession.wordQuizUsesComposer && !chatSession.wordQuizSolved);

  String get _inputHint {
    if (_quizStarting && _modeLabel() == null) return tr('chat.hint.word');
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

  /// Whether the last build published a rect for the hint button — so the
  /// transition to hidden (quiz solved, mode exited) can clear it exactly
  /// once, rather than on every build that finds nothing to show.
  bool _hintButtonRectPublished = false;

  Widget? _wordQuizComposerActions() {
    if (chatSession.mode != ChatMode.quizWord ||
        !chatSession.wordQuizUsesComposer ||
        chatSession.wordQuizSolved) {
      if (_hintButtonRectPublished) {
        _hintButtonRectPublished = false;
        keepKeyboardOverRect(null);
      }
      return null;
    }
    // Same DOM issue as the @ picker (see keep_keyboard_on_tap.dart): this
    // button is canvas pixels, not a real element, so tapping it used to blur
    // the hidden <textarea> and take the keyboard down mid-answer. Reasserting
    // focus after the fact (the previous fix, still below as a belt) only
    // covered engines where the blur was transient; on the ones where it was
    // not, the keyboard closed and reopening it took a second tap. Publishing
    // this button's rect so index.html's listener never lets the press reach
    // the textarea is the actual fix; re-focusing stays as a harmless backstop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _wordQuizHintButtonKey.currentContext?.findRenderObject()
          as RenderBox?;
      if (box == null || !box.hasSize) return;
      _hintButtonRectPublished = true;
      keepKeyboardOverRect(box.localToGlobal(Offset.zero) & box.size);
    });
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Semantics(
          button: true,
          label: tr('clozeCard.letterHint'),
          child: GestureDetector(
            key: _wordQuizHintButtonKey,
            behavior: HitTestBehavior.opaque,
            onTap: _requestWordQuizHint,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                tr('clozeCard.letterHint'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _requestWordQuizHint() {
    if (!chatSession.wordQuizUsesComposer || chatSession.wordQuizSolved) return;
    final keepComposerFocused = _chatInputFocusNode.hasFocus;
    // The composer is deliberately NOT cleared here. It used to be, because the
    // blank rendered its draft and its hint exclusively and the hint would have
    // been hidden behind the draft — so asking for a hint silently threw away
    // whatever the learner had typed into that blank. The slot now draws the
    // hint beside the draft (ClozeQuizCard._hintGhost), so both survive.
    _clozeCardKey.currentState?.requestHint();
    // Belt to the DOM guard above: reassert focus in case some engine still
    // blurred anyway. A no-op once the guard is doing its job.
    if (keepComposerFocused) {
      _chatInputFocusNode.requestFocus();
    }
  }

  /// "3 / 8" position within the loaded quiz queue, or null when there is
  /// nothing to count against (queue not loaded yet, or already exhausted).
  String? _quizProgressLabel() {
    final position = chatSession.quizPosition;
    final total = chatSession.quizTotal;
    if (position == null || total == null) return null;
    return '$position / $total';
  }

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
          onCancel: _exitInputMode,
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
          onExit: _exitInputMode,
          progress: _quizProgressLabel(),
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
            // Leave the composer unfocused. A real tap on it is required for
            // iOS Safari to create a usable software-keyboard connection.
            _chatInputFocusNode.unfocus();
          },
          onExit: _exitInputMode,
          externalResult: chatSession.quizFeedback,
          clozeSolved: chatSession.wordQuizSolved,
          clozeCompletedWords: chatSession.clozeCompletedWords,
          clozeLiveDraft: chatSession.clozeLiveDraft,
          clozeCardKey: _clozeCardKey,
          onContentHeightChanged: (height) {
            if (!mounted || (height - _wordQuizContentHeight).abs() < 1) {
              return;
            }
            setState(() => _wordQuizContentHeight = height);
          },
          progress: _quizProgressLabel(),
        );
      case ChatMode.journal:
        // Composing now happens directly in the docked input pill (see
        // ChatInputBar's journalMode) — the feed only needs the "you're
        // writing a diary" banner (already appended as a journal_mode
        // message) plus, while the pipeline runs, the progress card.
        return null;
      case ChatMode.normal:
        return null;
    }
  }

  Widget? _quizStatusCard() {
    // Checked before `busy`, which stays true for the whole refill wait: a bare
    // 18px spinner for ~20s reads as a hang. Name the work and its cost instead.
    if (chatSession.quizRefilling) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('quiz.preparing'),
                    style: TextStyle(
                        color: context.shell.primaryText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('quiz.preparingHint'),
                    style:
                        TextStyle(color: context.shell.mutedText, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
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
                onPressed: _exitInputMode, child: Text(tr('quiz.close'))),
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

  /// Spark [nodeIds] and peek the graph through the chat.
  ///
  /// [moveCamera] is false when the caller is about to aim the camera itself.
  /// Both moving at once meant two overlapping 380ms glides — fit-the-whole-set
  /// followed by centre-on-one — which read as the graph lurching away and back.
  void _highlightNodes(Set<String> nodeIds, {bool moveCamera = true}) {
    _chatPeekTimer?.cancel();
    setState(() {
      _glowIds = nodeIds;
      _glowSeq++;
      // Referenced-node cards are a graph-navigation affordance on desktop as
      // well as mobile. The old width gate made the canvas invisible behind
      // the chat on normal web/desktop layouts.
      _chatPeekThrough = true;
    });
    if (moveCamera) _canvasKey.currentState?.focusOnNodes(nodeIds);
    // Let the user see the graph pan and glow, then restore the chat
    // automatically so the interaction never needs a second tap.
    _chatPeekTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _chatPeekThrough = false);
    });
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

    _selectedStudyPollTimer?.cancel();
    // Show the card immediately with what we have; upgrade to full detail.
    final nodeId = node['id']?.toString();
    final isStatement = isStatementNode(node);
    setState(() {
      _selectedNode = node;
      _selectedNodeId = nodeId;
      _selectedEdge = null;
      _selectedEdgeId = null;
      _selectedStudyQuizzes = null;
      _selectedStudyLoading = isStatement;
      _selectedRegenerating = false;
      _selectedGenerating = false;
    });
    _canvasKey.currentState?.centerOnNode(node['id'].toString());

    if (isStatement && nodeId != null) {
      unawaited(_loadSelectedStudyQuizzes(nodeId));
    }

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

  Future<void> _loadSelectedStudyQuizzes(String nodeId) async {
    try {
      final data = await apiClient.nodeStudyQuizzes(nodeId);
      if (!mounted || _selectedNodeId != nodeId) return;
      setState(() {
        _selectedStudyQuizzes = data;
        _selectedStudyLoading = false;
      });
      final statuses = data['material_status'] is Map
          ? (data['material_status'] as Map)
              .values
              .map((value) => value.toString())
              .toSet()
          : const <String>{};
      final generationStatus =
          ((data['generation'] as Map?)?['status'] ?? 'idle').toString();
      final isPreparing = statuses.any(
            const {'pending', 'analyzing', 'stale'}.contains,
          ) ||
          const {'queued', 'running'}.contains(generationStatus);
      _selectedStudyPollTimer?.cancel();
      if (isPreparing) {
        _selectedStudyPollTimer = Timer(
          const Duration(seconds: 2),
          () => _loadSelectedStudyQuizzes(nodeId),
        );
      }
    } catch (_) {
      if (!mounted || _selectedNodeId != nodeId) return;
      setState(() => _selectedStudyLoading = false);
    }
  }

  /// 수정된 진술의 문제·표현을 새로 만든다. 생성은 서버 백그라운드에서 돌기
  /// 때문에 새 문제가 붙을 때까지 카드 상태를 짧게 폴링해 준다.
  Future<void> _regenerateSelectedQuizzes(String nodeId) async {
    if (_selectedRegenerating) return;
    setState(() => _selectedRegenerating = true);
    try {
      await apiClient.regenerateNodeQuizzes(nodeId);
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (!mounted || _selectedNodeId != nodeId) return;
        await _loadSelectedStudyQuizzes(nodeId);
        final data = _selectedStudyQuizzes;
        final done = data != null && data['needs_regeneration'] != true;
        if (done) break;
      }
    } catch (e) {
      if (mounted) chatSession.errors.value = e.toString();
    } finally {
      if (mounted) setState(() => _selectedRegenerating = false);
    }
  }

  Future<void> _generateSelectedStudyQuizzes(String nodeId) async {
    if (_selectedGenerating) return;
    final before =
        ((_selectedStudyQuizzes?['word'] as Map?)?['count'] as num?)?.toInt() ??
            0;
    setState(() => _selectedGenerating = true);
    try {
      await apiClient.generateNodeStudyQuizzes(nodeId);
      for (var attempt = 0; attempt < 30; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted || _selectedNodeId != nodeId) return;
        await _loadSelectedStudyQuizzes(nodeId);
        final data = _selectedStudyQuizzes;
        final status =
            ((data?['generation'] as Map?)?['status'] ?? 'idle').toString();
        final count =
            (((data?['word'] as Map?)?['count']) as num?)?.toInt() ?? 0;
        if (!const {'queued', 'running'}.contains(status) && count >= before) {
          break;
        }
      }
    } catch (e) {
      if (mounted) chatSession.errors.value = e.toString();
    } finally {
      if (mounted) setState(() => _selectedGenerating = false);
    }
  }

  Future<void> _showSelectedExpressions(String nodeId) async {
    try {
      final data = await apiClient.getNodeExpressions(nodeId);
      if (!mounted || _selectedNodeId != nodeId) return;
      final raw = data['expressions_by_language'];
      final groups = raw is Map ? raw : const <String, dynamic>{};
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: const Icon(Icons.visibility_outlined),
                  title: Text(tr('kg.expressionSheetTitle')),
                  subtitle: Text(tr('kg.expressionSheetWarning')),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                    children: [
                      for (final entry in groups.entries) ...[
                        Text(
                          kLegacyLanguageLabelsKo[entry.key.toString()] ??
                              entry.key.toString(),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        for (final item in (entry.value as List? ?? const []))
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.auto_awesome, size: 18),
                            title: Text(
                              (item as Map)['expression']?.toString() ?? '',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle:
                                ((item)['meaning']?.toString() ?? '').isEmpty
                                    ? null
                                    : Text(item['meaning'].toString()),
                          ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) chatSession.errors.value = e.toString();
    }
  }

  Future<void> _selectEdge(Map<String, dynamic>? edge,
      {bool showSheet = false}) async {
    _selectedStudyPollTimer?.cancel();
    setState(() {
      _selectedEdge = edge;
      _selectedEdgeId = edge?['id']?.toString();
      _selectedNode = null;
      _selectedNodeId = null;
      _selectedStudyQuizzes = null;
      _selectedStudyLoading = false;
      _selectedRegenerating = false;
      _selectedGenerating = false;
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

  /// 숨김 모드에서는 head 타입 칩(Person/Speaker/Source)이 필터해도 빈
  /// 화면만 나오므로 범례 바에서 제외한다.
  List<Map<String, dynamic>> _legendEntityTypes(
    List<Map<String, dynamic>> entityTypes,
  ) {
    final visible = _hideHeads
        ? entityTypes
            .where((et) => !isStatementHeadType(et['name']?.toString()))
            .toList()
        : entityTypes;

    // Person is a subtype of Identity in the graph filter UI. Merge its count
    // into one Identity chip, creating that chip for Person-only graphs too.
    var personCount = 0;
    Map<String, dynamic>? identity;
    final result = <Map<String, dynamic>>[];
    for (final type in visible) {
      final name = canonicalEntityType(type['name']?.toString() ?? '');
      if (name == 'Person') {
        personCount += (type['count'] as num?)?.toInt() ?? 0;
      } else if (name == 'Identity') {
        identity = Map<String, dynamic>.from(type);
      } else {
        result.add(type);
      }
    }
    if (identity != null || personCount > 0) {
      result.add({
        'name': 'Identity',
        'count': ((identity?['count'] as num?)?.toInt() ?? 0) + personCount,
      });
    }
    return result;
  }

  void _toggleHideHeads() {
    setState(() {
      _hideHeads = !_hideHeads;
      if (_hideHeads) {
        // head 타입 필터는 숨김 모드에서 빈 화면이 되므로 해제.
        if (isStatementHeadType(_typeFilter)) _typeFilter = kAllTypesFilter;
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
    _selectedStudyPollTimer?.cancel();
    setState(() {
      _selectedNode = null;
      _selectedNodeId = null;
      _selectedEdge = null;
      _selectedEdgeId = null;
      _selectedStudyQuizzes = null;
      _selectedStudyLoading = false;
      _selectedRegenerating = false;
      _glowIds = const {};
      _glowSeq++;
    });
    _canvasKey.currentState?.clearInteractionFocus();
    // No refit: keep the camera where the user was exploring.
  }

  Future<void> _clearGraph() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('kg.clearGraphTitle')),
        content: Text(tr('kg.clearGraphBody')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('kg.clearGraphAction')),
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
        _typeFilter = kAllTypesFilter;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('kg.deletedStats', {
              'nodes': stats['nodes_deleted'],
              'edges': stats['edges_deleted'],
              'chunks': stats['chunks_deleted'],
            }),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('kg.deleteFailed', {'error': e}))),
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
              FilledButton(onPressed: _load, child: Text(tr('kg.retry'))),
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

    // 그래프가 비어 있어도 검색·줌·재배열·도구 숨김 버튼 등 툴바 전체는 그대로
    // 보여준다 — 도구 접근성이 노드 존재 여부에 좌우되지 않게 한다. compact
    // 모드만 툴바가 애초에 없는 더 단순한 레이아웃이라 힌트만 보여준다.
    if (nodes.isEmpty && widget.compact) {
      return _EmptyGraphHint(compact: true);
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
            child:
                _HideHeadsToggle(active: _hideHeads, onTap: _toggleHideHeads),
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
                    studyQuizzes: _selectedStudyQuizzes,
                    studyLoading: _selectedStudyLoading,
                    regenerating: _selectedRegenerating,
                    generating: _selectedGenerating,
                    onRegenerate: () {
                      final nodeId = _selectedNodeId;
                      if (nodeId == null) return;
                      unawaited(_regenerateSelectedQuizzes(nodeId));
                    },
                    onGenerate: () {
                      final nodeId = _selectedNodeId;
                      if (nodeId == null) return;
                      unawaited(_generateSelectedStudyQuizzes(nodeId));
                    },
                    onShowExpressions: () {
                      final nodeId = _selectedNodeId;
                      if (nodeId == null) return;
                      unawaited(_showSelectedExpressions(nodeId));
                    },
                    onStudyQuizzes: (quizType, quizIds, language) async {
                      if (quizType == 'composition') {
                        _activateInputMode();
                      } else {
                        _prepareWordQuizInput();
                      }
                      _ensureChatVisible();
                      await chatSession.startQuiz(
                        quizType,
                        language: language,
                        quizIds: quizIds,
                      );
                      if (quizType != 'composition') {
                        _prepareWordQuizInput();
                      }
                    },
                    onDetail: _showInspectorSheet,
                    onClose: _clearSelection,
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
        // 캔버스 바로 위, 검색바/범례보다 아래 레이어 — 노드가 없을 때만
        // 온보딩 힌트를 보여주되 툴바 조작은 그대로 통과시킨다. 채팅 시트가
        // 화면을 덮고 있는 기본 상태에서는 시트 자체의 빈 상태가 온보딩
        // 메시지 역할을 이미 하므로, 반투명 패널 뒤로 비쳐 겹쳐 보이지
        // 않도록 채팅을 숨겼을 때만 노출한다 (이중 빈 상태 방지).
        if (nodes.isEmpty)
          const Positioned.fill(
            child: IgnorePointer(child: _EmptyGraphHint()),
          ),
        if (_ocrBusy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.35),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                    vertical: AppSpacing.lg,
                  ),
                  decoration: BoxDecoration(
                    color: context.shell.panelBackground,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(color: context.shell.panelBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Text(
                        tr('ocr.working'),
                        style: TextStyle(color: context.shell.primaryText),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // Dual view toggle — sits under the search pill rather than inside it;
        // that pill is already at its icon budget at 390px.
        Positioned(
          top: _graphToolsVisible ? chipsTop + 48 : chipsTop,
          right: 12,
          child: _TodayPill(
            active: _todayMode,
            loading: _todayLoading,
            count: _todayItems.length,
            onToggle: _toggleTodayMode,
            onStart: _startTodayDeck,
          ),
        ),
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
              MaterialPageRoute<void>(builder: (_) => const GraphTrashScreen()),
            ).then((_) => _load()),
            onClearGraph: _clearGraph,
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
                hintText: tr('kg.searchHintLong'),
                hintStyle: TextStyle(color: shell.mutedText, fontSize: 13),
                prefixIcon:
                    Icon(Icons.search, size: 18, color: shell.mutedText),
                suffixText: matchCount == null
                    ? null
                    : tr('kg.matchCount', {'count': matchCount}),
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
            tooltip: tr('kg.refreshTooltip'),
            visualDensity: VisualDensity.compact,
            onPressed: onRefresh,
            icon: Icon(Icons.refresh, size: 20, color: shell.mutedText),
          ),
          IconButton(
            tooltip: tr('kg.fullscreenTooltip'),
            visualDensity: VisualDensity.compact,
            onPressed: onOpenFullscreen,
            icon: Icon(Icons.open_in_full, size: 20, color: shell.mutedText),
          ),
        ],
      ),
    );
  }
}

/// Dual-view toggle. Collapsed it is a single chip; active it grows a count and
/// a start button, so entering the deck is one tap from the graph.
class _TodayPill extends StatelessWidget {
  const _TodayPill({
    required this.active,
    required this.loading,
    required this.count,
    required this.onToggle,
    required this.onStart,
  });

  final bool active;
  final bool loading;
  final int count;
  final VoidCallback onToggle;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xE91A1A22) : const Color(0xF2FFFFFF);
    final accent = active ? AppColors.hubQuiz : shell.mutedText;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active
              ? AppColors.hubQuiz.withValues(alpha: 0.5)
              : shell.panelBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.10),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: loading ? null : onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (loading)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      )
                    else
                      Icon(Icons.style_outlined, size: 18, color: accent),
                    const SizedBox(width: 6),
                    Text(
                      tr('kg.todayToggle'),
                      style: TextStyle(
                        fontSize: 13,
                        color: accent,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (active && !loading) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.hubQuiz,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (active && !loading && count > 0)
              InkWell(
                onTap: onStart,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  color: AppColors.hubQuiz.withValues(alpha: 0.12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.play_arrow_rounded,
                        size: 18,
                        color: AppColors.hubQuiz,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        tr('kg.todayStart'),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.hubQuiz,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
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
                tooltip: tr('kg.menuTooltip'),
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
                  hintText: tr('kg.searchHintShort'),
                  hintStyle: TextStyle(color: hintColor, fontSize: 14),
                  suffixText: matchCount == null
                      ? null
                      : tr('kg.matchCount', {'count': matchCount}),
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
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
                ),
                onChanged: onQueryChanged,
              ),
            ),
            IconButton(
              tooltip: tr('kg.refreshTooltip'),
              onPressed: onRefresh,
              icon: Icon(Icons.refresh_rounded, color: shell.primaryText),
            ),
            // Destructive / rarely-used actions live behind the overflow menu
            // so they can't be fat-fingered while exploring.
            PopupMenuButton<String>(
              tooltip: tr('kg.moreTooltip'),
              icon: Icon(Icons.more_vert, color: shell.primaryText),
              color: shell.barBackground,
              onSelected: (v) {
                if (v == 'ontology') onOntology();
                if (v == 'refresh') onRefresh();
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
                      graphToolsVisible
                          ? tr('kg.hideGraphTools')
                          : tr('kg.showGraphTools'),
                      style: TextStyle(color: shell.primaryText, fontSize: 13),
                    ),
                  ),
                ),
                PopupMenuItem(
                  enabled: false,
                  height: 32,
                  child: Text(
                      tr('kg.nodeEdgeCount', {
                        'nodes': nodeCount,
                        'edges': edgeCount,
                      }),
                      style: TextStyle(color: shell.mutedText, fontSize: 12)),
                ),
                PopupMenuItem(
                  value: 'ontology',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.category_outlined,
                        color: AppColors.textMuted),
                    title: Text(tr('kg.ontology'),
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
                    title: Text(tr('kg.trash'),
                        style:
                            TextStyle(color: shell.primaryText, fontSize: 13)),
                  ),
                ),
                PopupMenuItem(
                  value: 'clear',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const Icon(Icons.delete_sweep, color: Colors.redAccent),
                    title: Text(tr('kg.clearGraphMenu'),
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 13)),
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
          message: active ? tr('kg.hideModeOff') : tr('kg.hideModeOn'),
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
                  active ? tr('kg.hideModeLabelOn') : tr('kg.hideModeLabelOff'),
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
    required this.studyQuizzes,
    required this.studyLoading,
    required this.regenerating,
    required this.generating,
    required this.onRegenerate,
    required this.onGenerate,
    required this.onShowExpressions,
    required this.onStudyQuizzes,
    required this.onDetail,
    required this.onClose,
  });

  final Map<String, dynamic>? node;
  final Map<String, dynamic>? edge;
  final List<Map<String, dynamic>> edges;
  final Map<String, Map<String, dynamic>> nodeById;
  final Map<String, Color> typeColors;
  final Map<String, dynamic>? studyQuizzes;
  final bool studyLoading;
  final bool regenerating;
  final bool generating;
  final VoidCallback onRegenerate;
  final VoidCallback onGenerate;
  final VoidCallback onShowExpressions;
  final Future<void> Function(
    String quizType,
    List<String> quizIds,
    String? language,
  ) onStudyQuizzes;
  final VoidCallback onDetail;
  final VoidCallback onClose;

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

  static const _languageLabels = kLegacyLanguageLabelsKo;

  Future<void> _startStudyQuiz(
    BuildContext context,
    String quizType,
    Map<String, dynamic> group,
  ) async {
    final allIds = (group['quiz_ids'] as List? ?? const [])
        .map((id) => id.toString())
        .toList();
    if (allIds.isEmpty) return;
    final byLanguage = <String, List<String>>{};
    final raw = group['by_language'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final ids = (entry.value as List? ?? const [])
            .map((id) => id.toString())
            .toList();
        if (ids.isNotEmpty) byLanguage[entry.key.toString()] = ids;
      }
    }
    if (byLanguage.length <= 1) {
      final language = byLanguage.keys.isEmpty ? null : byLanguage.keys.first;
      await onStudyQuizzes(quizType, allIds, language);
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                quizType == 'composition'
                    ? tr('kg.quizLangPickComposition')
                    : tr('kg.quizLangPickWord'),
              ),
            ),
            for (final language in byLanguage.keys)
              ListTile(
                leading: const Icon(Icons.translate_rounded),
                title: Text(_languageLabels[language] ?? language),
                trailing: Text(tr(
                    'kg.countItems', {'count': byLanguage[language]!.length})),
                onTap: () => Navigator.pop(sheetContext, language),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await onStudyQuizzes(quizType, byLanguage[chosen]!, chosen);
    }
  }

  Widget _studyLearningPanel(BuildContext context) {
    if (studyLoading) {
      return Row(children: [
        const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 9),
        Flexible(child: Text(tr('kg.analysisPreparing'))),
      ]);
    }
    final shell = context.shell;
    final word = (studyQuizzes?['word'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final composition =
        (studyQuizzes?['composition'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final expressions =
        (studyQuizzes?['expressions'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final generation =
        (studyQuizzes?['generation'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final rawStatuses = studyQuizzes?['material_status'];
    final statuses = rawStatuses is Map
        ? rawStatuses.values.map((value) => value.toString()).toSet()
        : const <String>{};
    final generationStatus = (generation['status'] ?? 'idle').toString();
    final isPreparing = generating ||
        regenerating ||
        const {'queued', 'running'}.contains(generationStatus) ||
        statuses.any(const {'pending', 'analyzing', 'stale'}.contains);
    final failed = statuses.contains('failed');
    final expressionCount = (expressions['count'] as num?)?.toInt() ?? 0;
    final availableCount =
        (expressions['available_count'] as num?)?.toInt() ?? 0;

    Widget quizButton(String type, Map<String, dynamic> group, String label) {
      final count = (group['count'] as num?)?.toInt() ?? 0;
      final reviewCount = (group['review_count'] as num?)?.toInt() ?? 0;
      return OutlinedButton.icon(
        onPressed:
            count == 0 ? null : () => _startStudyQuiz(context, type, group),
        icon: Icon(
            type == 'cloze'
                ? Icons.spellcheck_rounded
                : Icons.edit_note_rounded,
            size: 17),
        label: Text(reviewCount > 0
            ? '$label $count · ${tr('kg.reviewShort')} $reviewCount'
            : '$label $count'),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (expressionCount > 0) ...[
        InkWell(
          onTap: isPreparing ? null : onShowExpressions,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(children: [
              Icon(Icons.auto_awesome_outlined,
                  size: 17, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 7),
              Expanded(
                  child: Text(
                tr('kg.expressionCount', {'count': expressionCount}),
                style: const TextStyle(fontWeight: FontWeight.w700),
              )),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: shell.mutedText),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 26, bottom: 7),
          child: Text(tr('kg.expressionHiddenHint'),
              style: TextStyle(fontSize: 11, color: shell.mutedText)),
        ),
      ],
      if (isPreparing)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: .22)),
          ),
          child: Row(children: [
            const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('kg.generatingQualityTitle'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(tr('kg.generatingQualityBody'),
                    style: TextStyle(fontSize: 11.5, color: shell.mutedText)),
              ],
            )),
          ]),
        )
      else ...[
        Wrap(spacing: 8, runSpacing: 7, children: [
          quizButton('cloze', word, tr('kg.wordQuiz')),
          quizButton('composition', composition, tr('kg.compositionQuiz')),
        ]),
        if (availableCount > 0 ||
            ((word['count'] as num?)?.toInt() ?? 0) == 0 ||
            failed) ...[
          const SizedBox(height: 8),
          SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: failed ? onRegenerate : onGenerate,
                icon: Icon(failed
                    ? Icons.refresh_rounded
                    : Icons.auto_awesome_rounded),
                label: Text(failed
                    ? tr('kg.retryAnalysis')
                    : ((word['count'] as num?)?.toInt() ?? 0) == 0
                        ? tr('kg.createFromStatement')
                        : tr('kg.createMoreFromStatement',
                            {'count': availableCount})),
              )),
        ],
      ],
    ]);
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
                      tr('kg.connectionsCount',
                          {'type': type, 'degree': degree}),
                      style: TextStyle(
                          fontSize: 11, color: color.withValues(alpha: 0.9)),
                    ),
                    if (stmtPreview?.contextType != null) ...[
                      const SizedBox(width: 6),
                      StatementContextBadge(
                        type: stmtPreview!.contextType!,
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
                          '${isSpeakerLikeType(headNode['type']?.toString()) ? tr('kg.speakerLabel') : tr('kg.sourceLabel')}: ${headNode['name'] ?? '?'}',
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
            if (isStatement) ...[
              const SizedBox(height: 10),
              Text(
                tr('kg.quizFromStatement'),
                style: TextStyle(
                  color: shell.mutedText,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              _studyLearningPanel(context),
            ],
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDetail,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(tr('kg.detail'),
                      style: const TextStyle(fontSize: 12.5)),
                ),
                IconButton(
                  tooltip: tr('common.close'),
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
    final shell = context.shell;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        // Bounded width so the title never wraps mid-word into an awkward,
        // overlap-looking two lines.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Brand orbs — same "voice" as the assistant avatar / thinking
              // indicator, replacing the dated hub outline glyph.
              ThinkingOrbs(
                  size: compact ? 44 : 58, period: const Duration(seconds: 5)),
              const SizedBox(height: 20),
              Text(
                tr('graph.emptyTitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: shell.primaryText,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('graph.emptyBody'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: shell.mutedText,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
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
