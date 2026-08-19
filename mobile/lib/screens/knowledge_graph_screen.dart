import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../app_route_observer.dart';
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
import '../widgets/node_expression_sheet.dart';
import '../widgets/node_merge_sheet.dart';
import '../widgets/ocr_review_sheet.dart';
import '../widgets/ontology_settings_sheet.dart';
import '../widgets/quiz/cloze_quiz_card.dart';
import '../widgets/quiz/quiz_viewport_scope.dart';
import '../widgets/thinking_orbs.dart';

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
    with WidgetsBindingObserver, RouteAware {
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
  String? _generationNodeId;
  String? _generationNodeName;
  String? _generationLanguage;
  String? _generationStatus;
  String? _generationError;
  String? _openStudyNodeId;
  // Textract answers in a couple of seconds, but on a slow phone connection the
  // upload alone is long enough that a silent UI reads as a dead tap.
  bool _ocrBusy = false;

  /// A drag-to-merge is in flight (edge surgery + optional rename + reload).
  bool _merging = false;
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
  // Keep the first view calm: filters and canvas controls are still available
  // from the search bar's overflow menu, but no longer compete with the graph
  // and selected-node summary on every visit.
  bool _graphToolsVisible = false;
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
      // remember: false — 90% is the typing posture, not a browsing height the
      // user picked. Recording it meant one tap on the composer permanently
      // redefined "restore to the height you last chose", so every later
      // restore (leaving a quiz, switching rooms) buried the graph.
      _animateChatSheet(_sheetFocusSize, remember: false);
      _pinChatToBottom();
      return;
    }

    // Losing focus should not collapse the chat. A downward drag is the
    // explicit user action that restores the normal sheet height.
    if (_chatFocused) setState(() => _chatFocused = false);
  }

  /// [remember] records [target] as the height to come back to. Pass false for
  /// heights the app chose on the user's behalf rather than ones they set.
  void _animateChatSheet(double target, {bool remember = true}) {
    final min = _sheetMinChildSize(context, _chatAreaHeight);
    final next = target.clamp(min, _sheetFocusSize).toDouble();
    if (remember && next > min + 0.01) {
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

  /// Whether this screen is still the route the user is looking at.
  ///
  /// `mounted` is not the same question. A modal sheet (the OCR review sheet,
  /// the mode pickers) is pushed OVER this screen, which stays mounted with its
  /// listeners live — so a chat reply landing, or a delayed retry fired before
  /// the sheet opened, would still run the focus restores below and pull focus
  /// out of the field the user is typing in.
  ///
  /// On iOS Safari that is not a cosmetic focus wobble. Flutter web backs the
  /// focused field with a real DOM editable; moving focus programmatically tears
  /// that element down, and the node can be left believing it is focused while
  /// the browser has nothing to raise a keyboard for — the "커서는 찍히는데
  /// 키보드가 안 올라온다" state this file already documents at
  /// [_prepareWordQuizInput]. A tap cannot recover it, because Flutter sees no
  /// focus change to act on.
  ///
  /// Every ASYNCHRONOUS focus call in this screen is therefore gated on this.
  /// Synchronous ones made straight out of a user action are not: the user was
  /// on this route when they tapped.
  bool get _isTopRoute => ModalRoute.of(context)?.isCurrent ?? true;

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
        // Up to 600ms after the tap — long enough for the user to have opened
        // a sheet on top in the meantime, at which point this would steal the
        // sheet's keyboard rather than restore the composer's.
        if (!mounted || !_isTopRoute) return;
        _chatInputFocusNode.requestFocus();
        _pinChatToBottom(window: const Duration(milliseconds: 180));
      });
    }
  }

  /// Scramble cards must enter with an unfocused composer on iOS Safari.
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
    // Entering a quiz/journal mode raises the sheet to 90% (_expandChatForInput)
    // so the card has room. Leaving one never lowered it again, so closing a
    // quiz dropped the user on a wall of chat with the graph — the whole point
    // of this screen — still buried behind it, recoverable only by dragging a
    // handle they have no reason to know about. Restore the height they last
    // chose, the same way switching rooms does.
    if (!mounted) return;
    setState(() {
      _chatExpandedForInput = false;
      _chatManuallySized = false;
      _chatSheetSize = _chatRestoredSize > _sheetDefaultSize
          ? _chatRestoredSize
          : _sheetDefaultSize;
    });
  }

  /// Recreate the platform text-input connection after an async mode switch.
  /// On iOS Safari a request made while the old quiz is still busy can leave
  /// the Flutter field focused but with no keyboard to bring back on tap.
  void _restoreComposerFocusAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_inputEnabled || !_isTopRoute) return;
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
    // The graph is edge-to-edge, but the floating search/menu pill remains the
    // screen's navigation chrome. Leave it visible above a focused chat/quiz
    // instead of placing the first message or a long-running quiz status under
    // the system bar and search controls.
    final expandedTopInset = MediaQuery.paddingOf(context).top + 72.0;
    final expandedHeight = (graphAreaHeight - expandedTopInset)
        .clamp(
          0.0,
          graphAreaHeight,
        )
        .toDouble();
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
      // Keep system chrome and primary navigation readable, whichever path set
      // the height. Capping only the IME-expanded branch left every other route
      // to a tall sheet — a restored 0.9 height, a drag — free to run the feed
      // up under the status bar, where the first message collided with the
      // clock and the search pill showed through the panel.
      height: (_chatExpandedForInput && !_chatManuallySized)
          ? expandedHeight
          : (_chatSheetSize * graphAreaHeight).clamp(0.0, expandedHeight),
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
  /// Scrim + spinner shown while an OCR read or a node merge is in flight.
  ///
  /// Must be the LAST child of whatever Stack shows it. It used to live inside
  /// the canvas stack, which put it *under* the chat sheet: picking a photo
  /// looked like nothing happened at all for the length of a paid OCR call,
  /// and the scrim blocked only the graph it was already covering while the
  /// panel on top of it stayed tappable — the opposite of what it is for.
  Widget _busyOverlay() {
    if (!_ocrBusy && !_merging) return const SizedBox.shrink();
    return Positioned.fill(
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
                  _merging ? tr('nodeMerge.working') : tr('ocr.working'),
                  style: TextStyle(color: context.shell.primaryText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

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
              controlsBottomInset: _chatSheetSize * graphAreaHeight + 12,
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
            // Last: it has to cover the chat sheet and the composer, not sit
            // behind them.
            _busyOverlay(),
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The graph home is the bottom of the stack, so anything that edits the
    // graph from a pushed route — 저장공간 관리's graph/journal purges, the
    // trash — lands back here. Without this the canvas kept painting nodes the
    // server no longer had until a manual refresh.
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    _load();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
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
    if (wordQuizJustSolved && _isTopRoute) {
      // The next action is explicitly "Next question", so retaining the
      // composer focus only steals vertical space from the answer state.
      // Hide the platform IME as well as releasing Flutter focus; the latter
      // alone does not reliably dismiss iOS Safari's keyboard.
      //
      // Gated on the route: `primaryFocus` is whoever is actually editing, and
      // with a sheet on top that is the SHEET's field — this would blur it and
      // pull the keyboard down under the user's hands.
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
        // A reply can land at any moment, including while the user is halfway
        // through correcting OCR text in a sheet. Only reclaim the composer
        // when the composer is what they are looking at.
        if (mounted && _isTopRoute) _chatInputFocusNode.requestFocus();
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
        _startQuizWithLanguagePrompt('scramble');
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
        if (chatSession.activeQuiz?['quiz_type']?.toString() == 'composition') {
          return tr('chat.mode.composition');
        }
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
      chatSession.activeQuiz?['quiz_type']?.toString() == 'composition' ||
      (chatSession.wordQuizUsesComposer && !chatSession.wordQuizSolved);

  /// Placeholder for a quiz composer with no question behind it, or null when
  /// a card is loaded and the mode's normal hint applies.
  String? _quizlessInputHint() {
    if (chatSession.activeQuiz != null) return null;
    if (chatSession.quizUnavailable || chatSession.quizExhausted) {
      return tr('chat.hint.quizNone');
    }
    return tr('chat.hint.quizWaiting');
  }

  String get _inputHint {
    if (_quizStarting && _modeLabel() == null) return tr('chat.hint.word');
    switch (chatSession.mode) {
      case ChatMode.distill:
        return tr('chat.hint.distill');
      case ChatMode.quizComposition:
        // "Write your answer" over an empty screen invites typing an answer to
        // a question that has not arrived. Say what the app is doing instead —
        // and distinguish "still coming" from "there is nothing to ask", which
        // are the same blank composer but opposite advice.
        return _quizlessInputHint() ?? tr('chat.hint.composition');
      case ChatMode.quizWord:
        if (chatSession.activeQuiz?['quiz_type']?.toString() == 'composition') {
          return tr('chat.hint.composition');
        }
        return _quizlessInputHint() ?? tr('chat.hint.word');
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
    // No card loaded yet (first fetch, or a refill after the last question) is
    // not a state a hint belongs in: there is nothing to reveal, so the button
    // was a live-looking control whose only behaviour was to do nothing.
    if (chatSession.mode != ChatMode.quizWord ||
        chatSession.activeQuiz == null ||
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
      // The published rect is a DOM-level tap suppressor: index.html cancels
      // the default action of any press inside it, so the hidden <textarea>
      // never takes focus. That is exactly right over this button and exactly
      // wrong anywhere else — a rect left up while a sheet covers the screen
      // sits over the SHEET's text field, where a tap then places a caret and
      // raises no keyboard at all. The composer keeps rebuilding underneath a
      // sheet, so this must withdraw the rect rather than re-publish it.
      final box = _wordQuizHintButtonKey.currentContext?.findRenderObject()
          as RenderBox?;
      if (!_isTopRoute || box == null || !box.hasSize) {
        if (_hintButtonRectPublished) {
          _hintButtonRectPublished = false;
          keepKeyboardOverRect(null);
        }
        return;
      }
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

  void _focusWordQuizInput() {
    if (!chatSession.wordQuizUsesComposer || chatSession.wordQuizSolved) return;
    _chatInputFocusNode.requestFocus();
    _pinChatToBottom(window: const Duration(milliseconds: 260));
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
          onSubmit: ({answer, order, selectedIndex, hintLevel = 0}) =>
              chatSession.submitWordQuiz(
                  answer: answer,
                  order: order,
                  selectedIndex: selectedIndex,
                  hintLevel: hintLevel),
          onHint: chatSession.requestScrambleHint,
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
          onClozeInputTap: _focusWordQuizInput,
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
    if (chatSession.busy) {
      return _QuizStatusPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('quiz.loading'),
                        style: TextStyle(
                          color: context.shell.primaryText,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        tr('quiz.loadingHint'),
                        style: TextStyle(
                          color: context.shell.mutedText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _exitInputMode,
                child: Text(tr('quiz.close')),
              ),
            ),
          ],
        ),
      );
    }
    if (chatSession.quizUnavailable) {
      return _QuizStatusPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('quiz.noCardsTitle'),
              style: TextStyle(
                color: context.shell.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr('quiz.noCardsBody'),
              style: TextStyle(color: context.shell.mutedText, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _exitInputMode,
                  child: Text(tr('quiz.close')),
                ),
              ],
            ),
          ],
        ),
      );
    }
    if (chatSession.quizExhausted) {
      return _QuizStatusPanel(
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
  Future<String?> _pickGenerationLanguage(String nodeId) async {
    Map<String, dynamic>? data =
        _selectedNodeId == nodeId ? _selectedStudyQuizzes : null;
    data ??= await apiClient.nodeStudyQuizzes(nodeId);
    final raw = data['material_status'];
    final languages = raw is Map
        ? raw.keys.map((value) => value.toString().toLowerCase()).toList()
        : <String>[];
    if (languages.isEmpty || !mounted) return null;
    return showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(tr('kg.pickGenerationLanguage'))),
            for (final language in languages)
              ListTile(
                leading: Text(
                  kTargetLanguages
                          .where((item) => item.key == language)
                          .firstOrNull
                          ?.flag ??
                      '',
                  style: const TextStyle(fontSize: 22),
                ),
                title: Text(langLabel(language)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(sheetContext, language),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _startSelectedGeneration(
    String nodeId, {
    required bool regenerate,
  }) async {
    // One generation at a time — but say so. Returning silently left the
    // learner pressing 생성 on a second Statement with no response at all, and
    // no way to tell a busy queue from a dead button.
    if (_generationStatus == 'running') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('kg.generationBusy', {
            'name': _generationNodeName ?? '',
          })),
          action: _generationNodeId == null
              ? null
              : SnackBarAction(
                  label: tr('kg.tapToOpen'),
                  onPressed: () => unawaited(_openGenerationNode()),
                ),
        ),
      );
      return;
    }
    final language = await _pickGenerationLanguage(nodeId);
    if (language == null || !mounted) return;
    final before =
        ((_selectedStudyQuizzes?['scramble'] as Map?)?['count'] as num?)
                ?.toInt() ??
            0;
    setState(() {
      _generationNodeId = nodeId;
      _generationNodeName = _selectedNode?['name']?.toString() ?? '';
      _generationLanguage = language;
      _generationStatus = 'running';
      _generationError = null;
      _selectedRegenerating = regenerate;
      _selectedGenerating = !regenerate;
    });
    try {
      if (regenerate) {
        await apiClient.regenerateNodeQuizzes(nodeId, language: language);
      } else {
        await apiClient.generateNodeStudyQuizzes(nodeId, language: language);
      }
      unawaited(_monitorGeneration(
        nodeId,
        beforeCount: before,
        regenerate: regenerate,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generationStatus = 'failed';
        _generationError = e.toString();
        _selectedRegenerating = false;
        _selectedGenerating = false;
      });
    }
  }

  Future<void> _monitorGeneration(
    String nodeId, {
    required int beforeCount,
    required bool regenerate,
  }) async {
    for (var attempt = 0; attempt < 90; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted || _generationNodeId != nodeId) return;
      try {
        final data = await apiClient.nodeStudyQuizzes(nodeId);
        if (_selectedNodeId == nodeId) {
          setState(() {
            _selectedStudyQuizzes = data;
            _selectedStudyLoading = false;
          });
        }
        final generation = (data['generation'] as Map?) ?? const {};
        final status = (generation['status'] ?? 'idle').toString();
        final count =
            (((data['scramble'] as Map?)?['count']) as num?)?.toInt() ?? 0;
        // A run that ended badly is terminal news, not something to keep
        // waiting on. Surface the worker's own error instead of spinning for
        // three more minutes and then blaming a timeout.
        if (status == 'failed') {
          setState(() {
            _generationStatus = 'failed';
            _generationError =
                generation['error']?.toString() ?? tr('kg.generationFailed');
            _selectedRegenerating = false;
            _selectedGenerating = false;
          });
          return;
        }
        final settled = !const {'queued', 'running'}.contains(status);
        final produced = regenerate
            ? data['needs_regeneration'] != true && count > 0
            : count > beforeCount;
        // A finished run that added nothing (every expression already had its
        // card, or the quality gate rejected the lot) used to look identical to
        // one still working, and rode the loop to the timeout. Stop on the run
        // itself, and report the empty result as its own outcome.
        if (!settled) continue;
        if (!produced && status != 'idle') {
          // Those two causes are not the same news. "이미 카드가 다 있어요" sends
          // the learner to a list that does not exist when the statement has no
          // stored expressions at all — the quality gate (score < 70) rejected
          // every candidate, which is what a short chat line normally yields.
          final storedExpressions =
              (((data['expressions'] as Map?)?['count']) as num?)?.toInt() ?? 0;
          setState(() {
            _generationStatus =
                storedExpressions > 0 ? 'empty' : 'empty_no_expression';
            _generationError = generation['error']?.toString();
            _selectedRegenerating = false;
            _selectedGenerating = false;
          });
          return;
        }
        if (!produced) continue;
        setState(() {
          _generationStatus = 'complete';
          _generationError = null;
          _selectedRegenerating = false;
          _selectedGenerating = false;
        });
        return;
      } catch (e) {
        if (attempt < 89) continue;
        setState(() {
          _generationStatus = 'failed';
          _generationError = e.toString();
          _selectedRegenerating = false;
          _selectedGenerating = false;
        });
      }
    }
    if (mounted && _generationNodeId == nodeId) {
      // Its own status, not 'failed'. This clock running out says the client
      // gave up watching; the run on the server may still be working, and
      // calling that a failure is a claim this code cannot make.
      setState(() {
        _generationStatus = 'timeout';
        _generationError = tr('kg.generationTimedOut');
        _selectedRegenerating = false;
        _selectedGenerating = false;
      });
    }
  }

  /// Open the Statement the pill is reporting on, study section expanded.
  ///
  /// Reachable while the run is still going, not only once it finishes: the
  /// pill names a node, so tapping it should go there — waiting is not a reason
  /// to make it inert.
  Future<void> _openGenerationNode() async {
    final nodeId = _generationNodeId;
    if (nodeId == null) return;
    final node = (_graph?['nodes'] as List<dynamic>? ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .where((value) => value['id']?.toString() == nodeId)
        .firstOrNull;
    if (node == null) return;
    setState(() => _openStudyNodeId = nodeId);
    await _selectNode(node);
  }

  /// The Statement's extracted wordbook — reviewable, and prunable.
  ///
  /// Extraction is the one step whose output the learner cannot correct
  /// anywhere else, so this sheet owns selection and deletion (the server drops
  /// the quizzes each deleted expression produced). Reload the study panel
  /// afterwards so its counts match what is actually left.
  Future<void> _showSelectedExpressions(String nodeId) async {
    try {
      final data = await apiClient.getNodeExpressions(nodeId);
      if (!mounted || _selectedNodeId != nodeId) return;
      final raw = data['expressions_by_language'];
      final groups = raw is Map ? raw : const <String, dynamic>{};
      final visibleGroups = Map<String, dynamic>.fromEntries(
        groups.entries
            .where(
              (entry) =>
                  entry.value is List && (entry.value as List).isNotEmpty,
            )
            .map((entry) => MapEntry(entry.key.toString(), entry.value)),
      );
      final changed = await showNodeExpressionSheet(
        context: context,
        nodeId: nodeId,
        expressionsByLanguage: visibleGroups,
      );
      if (changed && mounted && _selectedNodeId == nodeId) {
        await _loadSelectedStudyQuizzes(nodeId);
      }
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

    // Every legacy identity spelling (Person/Speaker/화자) folds into the one
    // Identity chip — on a graph that hasn't been through the backfill these
    // are the same category, and showing them separately reads as duplicates.
    // Source keeps its own chip; it is a deliberately distinct identity.
    var identityCount = 0;
    var sawIdentity = false;
    final result = <Map<String, dynamic>>[];
    for (final type in visible) {
      final name = canonicalEntityType(type['name']?.toString() ?? '');
      if (isNonSourceIdentityType(name)) {
        identityCount += (type['count'] as num?)?.toInt() ?? 0;
        sawIdentity = true;
      } else {
        result.add(type);
      }
    }
    if (sawIdentity) {
      result.add({'name': 'Identity', 'count': identityCount});
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

  /// A node was dragged onto another one on the canvas: ask, then merge.
  ///
  /// The canvas only judges the gesture and whether the pair is mergeable
  /// ([canMergeNodes]); the decision, the surviving name and the request live
  /// here. Backend-side this is one call — `/kg/nodes/{id}/reclassify` with
  /// `merge_into` — which reassigns edges, carries journal provenance, alias
  /// embeddings and the importance score over, and learns the absorbed name as
  /// an alias so future mentions resolve to the survivor on their own.
  Future<void> _confirmNodeMerge(
    Map<String, dynamic> source,
    Map<String, dynamic> target,
  ) async {
    final sourceId = source['id'].toString();
    final targetId = target['id'].toString();
    final movingEdges = (_graph?['edges'] as List<dynamic>? ?? []).where((raw) {
      if (raw is! Map) return false;
      return raw['source_id'].toString() == sourceId ||
          raw['target_id'].toString() == sourceId;
    }).length;

    final keptName = await NodeMergeSheet.show(
      context,
      source: source,
      target: target,
      movingEdgeCount: movingEdges,
    );
    if (keptName == null || !mounted) return;

    setState(() => _merging = true);
    try {
      final result = await apiClient.reclassifyNode(
        sourceId,
        mergeInto: targetId,
      );
      // Renaming is a second call on purpose: the merge must land even if the
      // rename fails, and the survivor keeps its own name in that case rather
      // than the merge being rolled back over a label.
      final targetName = nodeDisplayLabel(target);
      if (keptName.trim().isNotEmpty && keptName != targetName) {
        await apiClient.updateNode(
          targetId,
          name: keptName,
          type: target['type']?.toString() ?? 'Identity',
        );
      }
      if (!mounted) return;
      // The merged node was the selected one on the canvas — its inspector now
      // points at something that no longer exists.
      if (_selectedNodeId == sourceId) _clearSelection();
      _snack(tr('nodeMerge.done', {
        'name': keptName,
        'edges':
            '${(result['edges_reassigned'] as num?)?.toInt() ?? movingEdges}',
      }));
      await _load();
    } catch (e) {
      if (!mounted) return;
      _snack(tr('nodeMerge.failed', {'error': e}));
    } finally {
      if (mounted) setState(() => _merging = false);
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

    final body = SizedBox.expand(
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
    if (widget.compact) return body;

    // Android's back key hides the IME at the platform level without telling
    // Flutter to drop focus, and the view kept the keyboard's inset afterwards:
    // the app stayed drawn into the shortened viewport with a ~700px black band
    // where the keyboard had been, and it did not recover on its own. Taking
    // back ourselves — release focus, hide the IME through the same channel the
    // app uses everywhere else — resolves the inset and also gives back its
    // expected Android meaning here (leave the input posture, don't leave the
    // app). A second press still pops.
    return PopScope(
      canPop: !_chatInputFocusNode.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_chatInputFocusNode.hasFocus) return;
        _chatInputFocusNode.unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
        unawaited(
            SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      },
      child: body,
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
          onNodeMergeRequest: _confirmNodeMerge,
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
          bottom: selectionCardBottom + (_generationStatus == null ? 0 : 54),
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
                    key: ValueKey(
                      '${_selectedNodeId ?? _selectedEdgeId}:${_openStudyNodeId == _selectedNodeId}',
                    ),
                    node: _selectedNode,
                    edge: _selectedEdge,
                    edges: edges,
                    nodeById: nodeById,
                    typeColors: typeColors,
                    studyQuizzes: _selectedStudyQuizzes,
                    studyLoading: _selectedStudyLoading,
                    regenerating: _selectedRegenerating,
                    generating: _selectedGenerating,
                    studyInitiallyExpanded: _openStudyNodeId == _selectedNodeId,
                    onRegenerate: () {
                      final nodeId = _selectedNodeId;
                      if (nodeId == null) return;
                      unawaited(_startSelectedGeneration(
                        nodeId,
                        regenerate: true,
                      ));
                    },
                    onGenerate: () {
                      final nodeId = _selectedNodeId;
                      if (nodeId == null) return;
                      unawaited(_startSelectedGeneration(
                        nodeId,
                        regenerate: false,
                      ));
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
        if (_generationStatus != null)
          Positioned(
            right: 64,
            bottom: selectionCardBottom,
            child: _GenerationStatusPill(
              status: _generationStatus!,
              nodeName: _generationNodeName ?? '',
              language: _generationLanguage,
              error: _generationError,
              // Always tappable. 'running' and 'empty' go to the Statement (the
              // one place that shows what it does and does not have yet); the
              // outcomes with nothing to show just dismiss.
              onTap: const {'failed', 'timeout'}.contains(_generationStatus)
                  ? () => setState(() {
                        _generationStatus = null;
                        _generationError = null;
                      })
                  : _openGenerationNode,
              onDismiss: () => setState(() {
                _generationStatus = null;
                _generationError = null;
              }),
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
        // The OCR/merge scrim used to sit here. `overlays` is explicitly the
        // layer *below* the chat scrim and sheet, so it was invisible for the
        // whole of a paid OCR call — _canvasWithChat now paints it last.
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
            onToggleGraphTools: () =>
                setState(() => _graphToolsVisible = !_graphToolsVisible),
            graphToolsVisible: _graphToolsVisible,
          ),
        ),
      ],
    );
  }
}

/// Shared frame for the quiz footer's non-question states: preparing, loading,
/// nothing to ask, session finished.
///
/// The footer slot is top-aligned inside a sheet stretched to the whole graph
/// area, which is right for a question card (it can be taller than the screen)
/// and wrong for these. A ~20s refill wait rendered as two lines of text pinned
/// under the floating search pill with a thousand pixels of empty graph below
/// it — indistinguishable from a screen that failed to load. Filling the
/// viewport and centring the message makes the wait read as a state the app is
/// deliberately in, and putting it on a bordered surface stops the text from
/// floating loose over the canvas.
class _QuizStatusPanel extends StatelessWidget {
  const _QuizStatusPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final card = Container(
      decoration: BoxDecoration(
        color: shell.subtleSurface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: shell.panelBorder),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: child,
    );
    final available = QuizViewportScope.maybeHeightOf(context);
    if (available == null || available <= 0) return card;
    return SizedBox(
      height: available,
      // Scrollable so a long "nothing to ask" body still reaches its buttons
      // when the keyboard has taken most of the sheet.
      child: Center(
        child: SingleChildScrollView(child: card),
      ),
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
                // 휴지통·그래프 전체 삭제는 여기 없다: 되돌릴 수 없는 동작이
                // 탐색용 토글 바로 옆에 있으면 안 되고, 사진·음성처럼 삭제
                // 수단이 없던 데이터와 한 자리에서 다뤄야 한다.
                // → 내 프로필 › 저장공간 관리 (StorageManagerScreen).
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
    required this.studyInitiallyExpanded,
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
  final bool studyInitiallyExpanded;
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
    final scramble =
        (studyQuizzes?['scramble'] as Map?)?.cast<String, dynamic>() ??
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
    final storedExpressionCount = (expressions['count'] as num?)?.toInt() ?? 0;
    final scrambleCount = (scramble['count'] as num?)?.toInt() ?? 0;
    final expressionCount =
        storedExpressionCount > scrambleCount
            ? storedExpressionCount
            : scrambleCount;
    Widget quizAction(String type, Map<String, dynamic> group, String label) {
      final count = (group['count'] as num?)?.toInt() ?? 0;
      final reviewCount = (group['review_count'] as num?)?.toInt() ?? 0;
      return _StudyActionRow(
        onPressed:
            count == 0 ? null : () => _startStudyQuiz(context, type, group),
        icon:
            type == 'scramble' ? Icons.low_priority_rounded : Icons.notes_rounded,
        label: label,
        trailing: reviewCount > 0
            ? tr('kg.quizCountWithReview', {
                'count': count,
                'review': reviewCount,
              })
            : tr('kg.countItems', {'count': count}),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (expressionCount > 0) ...[
        _StudyActionRow(
          onPressed: isPreparing ? null : onShowExpressions,
          icon: Icons.translate_rounded,
          label: tr('kg.expressions'),
          trailing: '$expressionCount',
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
        quizAction('scramble', scramble, tr('kg.wordQuiz')),
        quizAction('composition', composition, tr('kg.compositionQuiz')),
        if (failed)
          _StudyActionRow(
            onPressed: onRegenerate,
            icon: Icons.refresh_rounded,
            label: tr('kg.retryAnalysis'),
            showDivider: false,
          ),
      ],
    ]);
  }

  String _studySummary() {
    if (studyLoading) return tr('kg.analysisPreparing');
    final scramble = (studyQuizzes?['scramble'] as Map?)?['count'] as num?;
    final composition =
        (studyQuizzes?['composition'] as Map?)?['count'] as num?;
    final expressions =
        (studyQuizzes?['expressions'] as Map?)?['count'] as num?;
    final quizCount = (scramble?.toInt() ?? 0) + (composition?.toInt() ?? 0);
    final rawExpressionCount = expressions?.toInt() ?? 0;
    final scrambleCount = scramble?.toInt() ?? 0;
    final expressionCount =
        rawExpressionCount > scrambleCount
            ? rawExpressionCount
            : scrambleCount;
    return tr('kg.studySummary', {
      'quizzes': quizCount,
      'expressions': expressionCount,
    });
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
                          '${isNonSourceIdentityType(headNode['type']?.toString()) ? tr('kg.speakerLabel') : tr('kg.sourceLabel')}: ${headNode['name'] ?? '?'}',
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
              const SizedBox(height: 6),
              Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                ),
                child: ExpansionTile(
                  initiallyExpanded: studyInitiallyExpanded,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 6),
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    Icons.school_outlined,
                    size: 18,
                    color: shell.mutedText,
                  ),
                  title: Text(
                    tr('kg.learningSection'),
                    style: TextStyle(
                      color: shell.primaryText,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    _studySummary(),
                    style: TextStyle(fontSize: 10.5, color: shell.mutedText),
                  ),
                  children: [_studyLearningPanel(context)],
                ),
              ),
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

class _GenerationStatusPill extends StatelessWidget {
  const _GenerationStatusPill({
    required this.status,
    required this.nodeName,
    required this.language,
    required this.error,
    required this.onTap,
    this.onDismiss,
  });

  final String status;
  final String nodeName;
  final String? language;
  final String? error;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final running = status == 'running';
    final complete = status == 'complete';
    final failed = status == 'failed';
    final timedOut = status == 'timeout';
    final emptyNoExpression = status == 'empty_no_expression';
    final empty = status == 'empty' || emptyNoExpression;
    final tone = complete
        ? AppColors.accent
        : failed
            ? Theme.of(context).colorScheme.error
            : (timedOut || empty)
                ? AppColors.accentWarm
                : shell.primaryText;
    final title = complete
        ? tr('kg.generationComplete')
        : failed
            ? tr('kg.generationFailed')
            : timedOut
                ? tr('kg.generationTimedOut')
                : emptyNoExpression
                    ? tr('kg.generationNoExpression')
                    : empty
                        ? tr('kg.generationEmpty')
                        : tr('kg.generationInProgress');
    // The subtitle used to be the language plus a fixed reassurance, and the
    // real reason a run failed lived only in a Tooltip — which a touch device
    // never shows. Put it where it can actually be read.
    final detail = (failed || timedOut) && (error?.isNotEmpty ?? false)
        ? error!
        : emptyNoExpression
            ? tr('kg.generationNoExpressionHint')
            : empty
                ? tr('kg.generationEmptyHint')
                : language == null
                    ? null
                    : '${langLabel(language!)} · '
                        '${complete ? tr('kg.tapToOpen') : running ? tr('kg.youCanKeepBrowsing') : tr('kg.tapToOpen')}';
    return Tooltip(
      message: failed ? (error ?? '') : nodeName,
      child: Material(
        color: shell.panelBackground,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 230),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: shell.panelBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .18),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (running)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tone,
                    ),
                  )
                else
                  Icon(
                    complete
                        ? Icons.check_circle_outline_rounded
                        : empty
                            ? Icons.inbox_rounded
                            : timedOut
                                ? Icons.schedule_rounded
                                : Icons.error_outline_rounded,
                    size: 18,
                    color: tone,
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tone,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 10, color: shell.mutedText),
                        ),
                    ],
                  ),
                ),
                // A run still going has no dismiss — its own completion clears
                // it. Every settled outcome does, so a pill the learner has
                // read never has to be waited out.
                if (!running && onDismiss != null) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: onDismiss,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: shell.mutedText,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StudyActionRow extends StatelessWidget {
  const _StudyActionRow({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.trailing,
    this.showDivider = true,
  });

  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback? onPressed;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Column(
      children: [
        InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 17, color: shell.mutedText),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: onPressed == null
                          ? shell.mutedText.withValues(alpha: .55)
                          : shell.primaryText,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: TextStyle(fontSize: 11, color: shell.mutedText),
                  ),
                const SizedBox(width: 3),
                Icon(Icons.chevron_right_rounded,
                    size: 17, color: shell.mutedText),
              ],
            ),
          ),
        ),
        if (showDivider)
          Divider(height: 1, color: shell.panelBorder.withValues(alpha: .65)),
      ],
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
