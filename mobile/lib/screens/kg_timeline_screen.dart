import 'package:flutter/material.dart';

import '../api/client.dart';
import '../app_route_observer.dart';
import '../compose/compose_session_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'journal_hub_screen.dart';

// Context type → display color mapping
const _kTypeColors = {
  '개인일기': Color(0xFF14B8A6), // teal
  '회의록': Color(0xFF5B5FEF), // primary purple
  '책': Color(0xFFF59E0B), // amber
  '뉴스': Color(0xFFEF4444), // red
  '강연': Color(0xFF0D9488), // dark teal
  '논문': Color(0xFF4F46E5), // indigo
  '대화': Color(0xFF7C3AED), // purple
  '잡지': Color(0xFFEC4899), // pink
  '자료': Color(0xFF06B6D4), // cyan — AI·정리된 참고 지식
  '미분류': Color(0xFF94A3B8), // slate
};

Color _colorFor(String type) => _kTypeColors[type] ?? const Color(0xFF94A3B8);

// ─── Public screen ────────────────────────────────────────────────────────────

class KgTimelineScreen extends StatefulWidget {
  const KgTimelineScreen({
    super.key,
    required this.sharedDate,
    this.onOpenBuild,
    this.refreshSignal,
  });

  /// Cross-tab shared date. When Insight heatmap taps a date, this updates
  /// and the calendar sub-view scrolls to the correct month.
  final ValueNotifier<String?> sharedDate;

  /// Called when FAB is tapped — parent can push KgBuildScreen.
  final VoidCallback? onOpenBuild;

  /// Incremented by parent whenever this tab becomes active — triggers reload.
  final ValueNotifier<int>? refreshSignal;

  @override
  State<KgTimelineScreen> createState() => _KgTimelineScreenState();
}

class _KgTimelineScreenState extends State<KgTimelineScreen> with RouteAware {
  int _subView = 0; // 0=타임라인, 1=캘린더

  // Raw data — entry-centric (one card per journal entry). The graph is a live
  // derived layer: a card always reflects its entry's CURRENT Statement nodes,
  // so deleting/editing a node in the graph just updates the card on reload —
  // the timeline/calendar never splits per node, and never deletes the entry.
  List<Map<String, dynamic>> _cards =
      []; // entry-centric timeline + calendar cards
  bool _loading = true;
  String? _error;

  // Category filter (null = all)
  String? _catFilter;

  @override
  void initState() {
    super.initState();
    _load();
    widget.sharedDate.addListener(_onSharedDateChanged);
    widget.refreshSignal?.addListener(_load);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    widget.sharedDate.removeListener(_onSharedDateChanged);
    widget.refreshSignal?.removeListener(_load);
    super.dispose();
  }

  /// A route pushed over the home shell (compose / entry detail / graph) was
  /// popped — silently refresh so the timeline reflects the latest speakers &
  /// graph state without blanking the current cards.
  @override
  void didPopNext() => _load(silent: true);

  void _onSharedDateChanged() {
    if (widget.sharedDate.value != null) {
      setState(() => _subView = 1);
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
      // Single entry-centric source of truth for BOTH timeline and calendar.
      final cards = await apiClient.getKgTimeline();
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // On a silent background refresh, keep the existing cards on screen rather
      // than replacing them with a full-screen error.
      if (!silent)
        setState(() {
          _error = e.toString();
          _loading = false;
        });
    }
  }

  /// Open the source entry for a tapped timeline/calendar card. The timeline is
  /// refreshed on return via [didPopNext].
  Future<void> _onEntryTap(Map<String, dynamic> card) async {
    final entryId = card['entry_id']?.toString();
    if (entryId == null || entryId.isEmpty) return;
    await JournalHubScreen.openEntryDetail(context, entryId);
  }

  List<Map<String, dynamic>> get _filteredCards {
    if (_catFilter == null) return _cards;
    return _cards
        .where((c) => (c['source_type']?.toString() ?? '') == _catFilter)
        .toList();
  }

  Set<String> get _allCategories {
    final cats = <String>{};
    for (final c in _cards) {
      final st = c['source_type']?.toString();
      if (st != null && st.isNotEmpty) cats.add(st);
    }
    return cats;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('홈'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(88),
          child: Column(
            children: [
              // Segment control
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Split the available width into two equal halves so each
                    // segment is wide enough for its label (no vertical wrap).
                    final segWidth = (constraints.maxWidth - 6) / 2;
                    return SegmentedButton<int>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      segments: [
                        ButtonSegment(
                          value: 0,
                          label: SizedBox(
                            width: segWidth,
                            child: const Text(
                              '타임라인',
                              textAlign: TextAlign.center,
                              softWrap: false,
                              overflow: TextOverflow.fade,
                            ),
                          ),
                        ),
                        ButtonSegment(
                          value: 1,
                          label: SizedBox(
                            width: segWidth,
                            child: const Text(
                              '캘린더',
                              textAlign: TextAlign.center,
                              softWrap: false,
                              overflow: TextOverflow.fade,
                            ),
                          ),
                        ),
                      ],
                      selected: {_subView},
                      onSelectionChanged: (s) =>
                          setState(() => _subView = s.first),
                    );
                  },
                ),
              ),
              // Category filter chips
              if (_allCategories.isNotEmpty)
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _FilterChipWidget(
                        label: '전체',
                        color: theme.colorScheme.primary,
                        selected: _catFilter == null,
                        onTap: () => setState(() => _catFilter = null),
                      ),
                      ..._allCategories.map((cat) => _FilterChipWidget(
                            label: cat,
                            color: _colorFor(cat),
                            selected: _catFilter == cat,
                            onTap: () => setState(() =>
                                _catFilter = _catFilter == cat ? null : cat),
                          )),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      body: _loading
          ? const AppLoadingScreen(message: '기록을 불러오는 중...')
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : IndexedStack(
                  index: _subView,
                  children: [
                    _TimelineSubView(
                      cards: _filteredCards,
                      onEntryTap: _onEntryTap,
                    ),
                    _CalendarSubView(
                      cards: _cards,
                      sharedDate: widget.sharedDate,
                      catFilter: _catFilter,
                      onEntryTap: _onEntryTap,
                      onAddEntry: () => composeSession.open(startNew: true),
                    ),
                  ],
                ),
      // 작성 창 오버레이 — 일기 생성/상태 변경 시 composeSession.entriesChanged를
      // 통해 타임라인이 갱신되므로 여기서 별도 reload는 필요 없다. 세션이 살아
      // 있는 동안은 우하단 미니 창이 FAB 자리를 대신하므로 FAB를 숨긴다.
      floatingActionButton: ListenableBuilder(
        listenable: composeSession,
        builder: (context, _) => composeSession.isActive
            ? const SizedBox.shrink()
            : FloatingActionButton(
                onPressed: () => composeSession.open(startNew: true),
                tooltip: '새 기록 추가',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }
}

// ─── Filter chip ──────────────────────────────────────────────────────────────

class _FilterChipWidget extends StatelessWidget {
  const _FilterChipWidget({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? color : color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : color,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Sub-view: Timeline ───────────────────────────────────────────────────────

class _TimelineSubView extends StatelessWidget {
  const _TimelineSubView({required this.cards, required this.onEntryTap});

  /// One card per uploaded file (journal entry) — NOT per Statement node.
  final List<Map<String, dynamic>> cards;
  final void Function(Map<String, dynamic> card) onEntryTap;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return const Center(
        child: AppEmptyState(
          icon: Icons.auto_stories_outlined,
          title: '아직 기록이 없습니다',
          subtitle: '+ 버튼을 눌러 첫 번째 기록을 남겨보세요',
        ),
      );
    }

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final c in cards) {
      final raw = c['created_at'] as String? ?? '';
      final date = raw.length >= 10 ? raw.substring(0, 10) : '알 수 없음';
      groups.putIfAbsent(date, () => []).add(c);
    }
    final sortedDates = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      itemCount: sortedDates.length,
      itemBuilder: (_, gi) {
        final date = sortedDates[gi];
        final items = groups[date]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DateHeader(date: date),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 2,
                        color: AppColors.primary.withOpacity(0.15),
                        margin: const EdgeInsets.only(left: 7),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      children: [
                        for (final c in items)
                          _EntryCard(card: c, onTap: () => onEntryTap(c)),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        );
      },
    );
  }
}

/// One timeline card = one journal entry (uploaded file). Groups all Statement
/// nodes derived from that entry; tapping opens the source entry.
class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.card, required this.onTap});
  final Map<String, dynamic> card;
  final VoidCallback onTap;

  /// 다음 행동 힌트 (label, icon, color, spinning) — 그래프 미완료 카드가
  /// 막다른 길이 되지 않도록 상태별 안내를 붙인다. null이면 표시 안 함.
  (String, IconData, Color, bool)? _nextStepHint(BuildContext context) {
    final status = card['status']?.toString() ?? '';
    final hasGraph = card['has_graph'] == true;
    final theme = Theme.of(context);
    if (hasGraph) return null;
    switch (status) {
      case 'processing':
        return (
          'AI 처리 중',
          Icons.hourglass_top_rounded,
          theme.colorScheme.onSurfaceVariant,
          true
        );
      case 'graph_processing':
        return (
          '그래프 생성 중',
          Icons.hourglass_top_rounded,
          theme.colorScheme.onSurfaceVariant,
          true
        );
      case 'graph_staging_ready':
        return (
          '그래프 초안 검토 대기 — 탭해서 확정',
          Icons.fact_check_outlined,
          const Color(0xFFB45309),
          false
        );
      case 'failed':
        return (
          '처리 실패',
          Icons.error_outline_rounded,
          theme.colorScheme.error,
          false
        );
      case 'graph_failed':
        return (
          '그래프 생성 실패 — 탭해서 다시 시도',
          Icons.refresh_rounded,
          theme.colorScheme.error,
          false
        );
      default:
        return (
          '탭해서 지식그래프 만들기',
          Icons.account_tree_outlined,
          AppColors.primary,
          false
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = (card['source_type']?.toString() ?? '').trim().isEmpty
        ? '미분류'
        : card['source_type'].toString();
    final color = _colorFor(label);
    final statements = ((card['statements'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final speakers = ((card['speakers'] as List?) ?? [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final hasGraph = card['has_graph'] == true;
    final preview = card['preview']?.toString() ?? '';

    final raw = card['created_at'] as String? ?? '';
    String timeStr = '';
    if (raw.length >= 16) {
      final dt = DateTime.tryParse(raw)?.toLocal();
      if (dt != null) {
        timeStr =
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.18), width: 1),
          boxShadow: [
            BoxShadow(
                color: color.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: type chip + time
            Container(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
              decoration: BoxDecoration(
                color: color.withOpacity(0.07),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(14)),
              ),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: color),
                    ),
                  ),
                  if (statements.length > 1) ...[
                    const SizedBox(width: 6),
                    Text('진술 ${statements.length}',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                  const Spacer(),
                  if (timeStr.isNotEmpty)
                    Text(timeStr,
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            // Body
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!hasGraph) ...[
                    if (preview.isNotEmpty)
                      Text(
                        preview,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    // 다음 행동 힌트 — 카드가 막다른 길이 되지 않게.
                    ...() {
                      final hint = _nextStepHint(context);
                      if (hint == null) return const <Widget>[];
                      final (label, icon, hintColor, spinning) = hint;
                      return <Widget>[
                        if (preview.isNotEmpty) const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (spinning)
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: hintColor,
                                ),
                              )
                            else
                              Icon(icon, size: 14, color: hintColor),
                            const SizedBox(width: 5),
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: hintColor,
                              ),
                            ),
                          ],
                        ),
                      ];
                    }(),
                  ] else
                    for (final s in statements)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 8),
                              child: Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                    color: color, shape: BoxShape.circle),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                s['content']?.toString().trim().isNotEmpty ==
                                        true
                                    ? s['content'].toString()
                                    : (s['title']?.toString() ?? ''),
                                style:
                                    const TextStyle(fontSize: 14, height: 1.35),
                              ),
                            ),
                          ],
                        ),
                      ),
                  if (speakers.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final sp in speakers)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.person,
                                    size: 11,
                                    color: theme.colorScheme.onSurfaceVariant),
                                const SizedBox(width: 3),
                                Text(sp,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: theme
                                            .colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.date});
  final String date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);
    final isToday = date == todayStr;

    // Parse for friendly display
    final dt = DateTime.tryParse(date);
    String label;
    if (dt != null) {
      const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
      final wd = weekdays[dt.weekday - 1];
      label = isToday
          ? '오늘 · ${dt.month}/${dt.day}($wd)'
          : '${dt.month}/${dt.day}($wd)';
    } else {
      label = date;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 10),
      child: Row(
        children: [
          // Timeline dot
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: isToday
                  ? AppColors.primary
                  : theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: Border.all(
                color: isToday
                    ? AppColors.primary
                    : theme.colorScheme.outline.withOpacity(0.4),
                width: isToday ? 0 : 1.5,
              ),
            ),
            child: isToday
                ? const Icon(Icons.circle, size: 8, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: isToday
                  ? AppColors.primary
                  : theme.colorScheme.onSurface.withOpacity(0.7),
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sub-view: Calendar ───────────────────────────────────────────────────────

class _CalendarSubView extends StatefulWidget {
  const _CalendarSubView({
    required this.cards,
    required this.sharedDate,
    required this.onEntryTap,
    this.catFilter,
    this.onAddEntry,
  });

  /// One card per journal entry — identical source to the Timeline.
  final List<Map<String, dynamic>> cards;
  final ValueNotifier<String?> sharedDate;
  final void Function(Map<String, dynamic>) onEntryTap;
  final String? catFilter;

  /// 빈 오늘 날짜 탭 → 바로 기록 시작 (Day One의 tap-empty-day 패턴).
  final VoidCallback? onAddEntry;

  @override
  State<_CalendarSubView> createState() => _CalendarSubViewState();
}

class _CalendarSubViewState extends State<_CalendarSubView> {
  // monthOffset: 0 = current month, 1 = last month, 2 = 2 months ago …
  int _monthOffset = 0;
  String? _selectedDate;

  @override
  void initState() {
    super.initState();
    widget.sharedDate.addListener(_onSharedDate);
    _selectedDate = widget.sharedDate.value;
    if (_selectedDate != null) _jumpToDate(_selectedDate!);
  }

  @override
  void dispose() {
    widget.sharedDate.removeListener(_onSharedDate);
    super.dispose();
  }

  void _onSharedDate() {
    final d = widget.sharedDate.value;
    if (d == null) return;
    setState(() {
      _selectedDate = d;
      _jumpToDate(d);
    });
  }

  void _jumpToDate(String dateStr) {
    final target = DateTime.tryParse(dateStr);
    if (target == null) return;
    final now = DateTime.now();
    final offset = (now.year - target.year) * 12 + (now.month - target.month);
    _monthOffset = offset.clamp(0, 120);
  }

  DateTime get _displayMonth {
    final now = DateTime.now();
    return DateTime(now.year, now.month - _monthOffset);
  }

  /// Entries grouped by creation date (yyyy-MM-dd) — same grouping the Timeline
  /// uses, so each day shows exactly the cards the Timeline would for that date.
  Map<String, List<Map<String, dynamic>>> _cardsByDate() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final c in widget.cards) {
      final raw = c['created_at']?.toString() ?? '';
      if (raw.length < 10) continue;
      map.putIfAbsent(raw.substring(0, 10), () => []).add(c);
    }
    return map;
  }

  /// 모든 날짜가 탭에 반응한다 — 빈 날짜도 무반응 대신 피드백을 주고,
  /// 빈 '오늘'은 바로 기록을 시작할 수 있게 한다.
  void _onDayTap(String dateStr) {
    final hasCards = (_cardsByDate()[dateStr] ?? const []).isNotEmpty;
    if (hasCards) {
      setState(() => _selectedDate = _selectedDate == dateStr ? null : dateStr);
      return;
    }
    final now = DateTime.now();
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final isToday = dateStr == todayStr;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(isToday ? '오늘은 아직 기록이 없어요' : '이 날의 기록이 없어요'),
        duration: const Duration(seconds: 2),
        action: isToday && widget.onAddEntry != null
            ? SnackBarAction(label: '기록하기', onPressed: widget.onAddEntry!)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final month = _displayMonth;
    final theme = Theme.of(context);
    final byDate = _cardsByDate();

    var selCards = _selectedDate == null
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(byDate[_selectedDate!] ?? const []);
    if (widget.catFilter != null) {
      selCards = selCards
          .where(
              (c) => (c['source_type']?.toString() ?? '') == widget.catFilter)
          .toList();
    }

    return Stack(
      children: [
        // Calendar always fills full available space
        Column(
          children: [
            // Month navigation header
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: () => setState(() {
                      _monthOffset++;
                      _selectedDate = null;
                    }),
                  ),
                  Expanded(
                    child: Text(
                      '${month.year}년 ${month.month}월',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  // 과거 달에서 한 번에 현재로 — 미아 방지.
                  if (_monthOffset != 0)
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => setState(() {
                        _monthOffset = 0;
                        _selectedDate = null;
                      }),
                      child: const Text('오늘'),
                    ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _monthOffset == 0
                        ? null
                        : () => setState(() {
                              _monthOffset--;
                              _selectedDate = null;
                            }),
                  ),
                ],
              ),
            ),
            // Month grid takes remaining space (좌우 스와이프로 월 이동)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final v = details.primaryVelocity ?? 0;
                  if (v.abs() < 200) return;
                  setState(() {
                    if (v < 0 && _monthOffset > 0)
                      _monthOffset--; // ← 스와이프: 다음 달
                    if (v > 0) _monthOffset++; // → 스와이프: 이전 달
                    _selectedDate = null;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: _MonthGrid(
                    month: month,
                    cardsByDate: byDate,
                    selectedDate: _selectedDate,
                    catFilter: widget.catFilter,
                    onDayTap: _onDayTap,
                  ),
                ),
              ),
            ),
          ],
        ),
        // Dim backdrop when panel is open
        if (_selectedDate != null && selCards.isNotEmpty)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _selectedDate = null),
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.18)),
            ),
          ),
        // Selected date panel overlaid at bottom — does not affect calendar layout
        if (_selectedDate != null && selCards.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _DayPanel(
              date: _selectedDate!,
              cards: selCards,
              onClose: () => setState(() => _selectedDate = null),
              onEntryTap: widget.onEntryTap,
            ),
          ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.cardsByDate,
    required this.selectedDate,
    required this.onDayTap,
    this.catFilter,
  });
  final DateTime month;
  final Map<String, List<Map<String, dynamic>>> cardsByDate;
  final String? selectedDate;
  final String? catFilter;
  final void Function(String) onDayTap;

  static const _weekLabels = ['일', '월', '화', '수', '목', '금', '토'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstWeekday =
        DateTime(month.year, month.month, 1).weekday % 7; // Sun=0
    final today = DateTime.now();
    final todayStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final cells = <Widget>[];
    // Empty leading cells
    for (int i = 0; i < firstWeekday; i++) {
      cells.add(const SizedBox.shrink());
    }
    // Day cells
    for (int day = 1; day <= daysInMonth; day++) {
      final dateStr =
          '${month.year}-${month.month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      final dayCards = cardsByDate[dateStr] ?? const <Map<String, dynamic>>[];
      cells.add(_DayCell(
        day: day,
        cards: dayCards,
        isToday: dateStr == todayStr,
        isSelected: dateStr == selectedDate,
        catFilter: catFilter,
        // 빈 날짜도 탭 가능 — 피드백/기록하기는 onDayTap이 처리.
        onTap: () => onDayTap(dateStr),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        // Weekday header
        Row(
          children: _weekLabels
              .map((l) => Expanded(
                    child: Center(
                      child: Text(
                        l,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: l == '일'
                              ? Colors.red.shade400
                              : l == '토'
                                  ? Colors.blue.shade400
                                  : theme.colorScheme.onSurface
                                      .withOpacity(0.5),
                        ),
                      ),
                    ),
                  ))
              .toList(),
        ),
        const SizedBox(height: 4),
        // Day grid — Column of Expanded Rows guarantees all 6 rows fill available height
        Expanded(
          child: Column(
            children: List.generate(6, (row) {
              final rowCells = cells
                  .sublist(
                    (row * 7).clamp(0, cells.length),
                    ((row + 1) * 7).clamp(0, cells.length),
                  )
                  .toList();
              // Pad to 7 if last row is short
              while (rowCells.length < 7) rowCells.add(const SizedBox.shrink());
              return Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rowCells.map((c) => Expanded(child: c)).toList(),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.cards,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
    this.catFilter,
  });
  final int day;
  final List<Map<String, dynamic>> cards;
  final bool isToday;
  final bool isSelected;
  final VoidCallback? onTap;
  final String? catFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = cards.isNotEmpty;
    // Indicator dots = this day's distinct entry source types (Timeline colors).
    final types = <String>[];
    for (final c in cards) {
      final t = (c['source_type']?.toString() ?? '').trim();
      final label = t.isEmpty ? '미분류' : t;
      if (catFilter != null && label != catFilter) continue;
      if (!types.contains(label)) types.add(label);
    }
    final showDots = types.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withOpacity(0.15)
              : isToday
                  ? AppColors.primary.withOpacity(0.05)
                  : null,
          borderRadius: BorderRadius.circular(6),
          border: isToday
              ? Border.all(color: AppColors.primary, width: 1.5)
              : isSelected
                  ? Border.all(color: AppColors.primary.withOpacity(0.5))
                  : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$day',
              style: TextStyle(
                fontSize: 11,
                fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                color: isToday
                    ? AppColors.primary
                    : hasData
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withOpacity(0.35),
              ),
            ),
            if (showDots) ...[
              const SizedBox(height: 1),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: types
                    .take(3)
                    .map((t) => Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: _colorFor(t),
                            shape: BoxShape.circle,
                          ),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Selected-day bottom panel
class _DayPanel extends StatelessWidget {
  const _DayPanel({
    required this.date,
    required this.cards,
    required this.onClose,
    required this.onEntryTap,
  });
  final String date;
  final List<Map<String, dynamic>> cards;
  final VoidCallback onClose;
  final void Function(Map<String, dynamic>) onEntryTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // "2026-07-02" 대신 "7월 2일 (목)" — 타임라인 날짜 헤더와 같은 어휘.
    final dt = DateTime.tryParse(date);
    String dateLabel = date;
    if (dt != null) {
      const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
      dateLabel = '${dt.month}월 ${dt.day}일 (${weekdays[dt.weekday - 1]})';
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 360),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Text(
                  dateLabel,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${cards.length}건',
                  style: theme.textTheme.bodySmall,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: cards.length,
              itemBuilder: (_, i) => _EntryCard(
                card: cards[i],
                onTap: () => onEntryTap(cards[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Error view ───────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: AppColors.hubRecord),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('다시 시도')),
          ],
        ),
      ),
    );
  }
}
