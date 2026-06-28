import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'journal_compose_screen.dart';
import 'journal_hub_screen.dart';
import 'knowledge_graph_screen.dart';

// Context type → display color mapping
const _kTypeColors = {
  '개인일기': Color(0xFF14B8A6),   // teal
  '회의록':  Color(0xFF5B5FEF),   // primary purple
  '책':     Color(0xFFF59E0B),   // amber
  '뉴스':   Color(0xFFEF4444),   // red
  '강연':   Color(0xFF0D9488),   // dark teal
  '논문':   Color(0xFF4F46E5),   // indigo
  '대화':   Color(0xFF7C3AED),   // purple
  '잡지':   Color(0xFFEC4899),   // pink
  '미분류':  Color(0xFF94A3B8),   // slate
};

Color _colorFor(String type) =>
    _kTypeColors[type] ?? const Color(0xFF94A3B8);

// ── Statement description helpers ───────────────────────────────────────────
// Supports new JSON format {"context_type":"...","content":"..."} and
// legacy "context_type\ncontent" plain-text format.

({String ctx, String content}) _parseStmtDesc(Map<String, dynamic> node) {
  // Prefer structured fields from NodeOut if backend already parsed them
  final ctxField = node['context_type']?.toString();
  final contentField = node['content']?.toString();
  if (ctxField != null || contentField != null) {
    return (ctx: ctxField?.trim().isEmpty == true ? '미분류' : (ctxField ?? '미분류'),
            content: contentField?.trim() ?? (node['name'] as String? ?? ''));
  }

  final desc = (node['description'] as String? ?? '').trim();
  if (desc.startsWith('{')) {
    try {
      final map = (json.decode(desc) as Map).cast<String, dynamic>();
      final ct = (map['context_type'] as String? ?? '').trim();
      final co = (map['content'] as String? ?? '').trim();
      return (ctx: ct.isEmpty ? '미분류' : ct, content: co.isEmpty ? (node['name'] as String? ?? '') : co);
    } catch (_) {}
  }
  // legacy \n format
  final parts = desc.split('\n');
  final ct = parts.first.trim();
  final co = parts.length > 1 ? parts.sublist(1).join('\n').trim() : '';
  return (ctx: ct.isEmpty ? '미분류' : ct,
          content: co.isEmpty ? (node['name'] as String? ?? '') : co);
}

String _ctxType(Map<String, dynamic> node) => _parseStmtDesc(node).ctx;
String _stmtText(Map<String, dynamic> node) => _parseStmtDesc(node).content;

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

class _KgTimelineScreenState extends State<KgTimelineScreen> {
  int _subView = 0; // 0=타임라인, 1=캘린더

  // Raw data
  List<Map<String, dynamic>> _statements = [];
  Map<String, Map<String, dynamic>> _calDays = {}; // date → {total, context_types}
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
  void dispose() {
    widget.sharedDate.removeListener(_onSharedDateChanged);
    widget.refreshSignal?.removeListener(_load);
    super.dispose();
  }

  void _onSharedDateChanged() {
    if (widget.sharedDate.value != null) {
      setState(() => _subView = 1);
    }
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        apiClient.getGraph(),
        apiClient.getKgCalendarData(),
      ]);
      final graph = results[0];
      final calData = results[1];

      final nodes = ((graph['nodes'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final stmts = nodes.where((n) => n['type'] == 'Statement').toList();
      stmts.sort((a, b) {
        final ta = DateTime.tryParse(a['created_at'] as String? ?? '') ?? DateTime(2000);
        final tb = DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime(2000);
        return tb.compareTo(ta);
      });

      final days = ((calData['days'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final calMap = <String, Map<String, dynamic>>{};
      for (final d in days) {
        calMap[d['date'] as String] = d;
      }

      if (!mounted) return;
      setState(() {
        _statements = stmts;
        _calDays = calMap;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  /// Timeline/calendar node tap → open '내 일기' for the source entry when known,
  /// falling back to the knowledge graph (e.g. legacy nodes without provenance).
  Future<void> _onNodeTap(Map<String, dynamic> node) async {
    final entryId = node['source_entry_id']?.toString();
    if (entryId != null && entryId.isNotEmpty) {
      await JournalHubScreen.openEntryDetail(context, entryId);
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => KnowledgeGraphScreen(
            initialNodeId: node['id']?.toString(),
          ),
        ),
      );
    }
    _load();
  }

  List<Map<String, dynamic>> get _filtered {
    if (_catFilter == null) return _statements;
    return _statements.where((n) => _ctxType(n) == _catFilter).toList();
  }

  Set<String> get _allCategories {
    return _statements.map((n) => _ctxType(n)).toSet();
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
                      onSelectionChanged: (s) => setState(() => _subView = s.first),
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
                        onTap: () => setState(() => _catFilter = _catFilter == cat ? null : cat),
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
                      statements: _filtered,
                      onNodeTap: _onNodeTap,
                    ),
                    _CalendarSubView(
                      calDays: _calDays,
                      statements: _statements,
                      sharedDate: widget.sharedDate,
                      catFilter: _catFilter,
                      onNodeTap: _onNodeTap,
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const JournalComposeScreen()),
          );
          _load();
        },
        tooltip: '새 기록 추가',
        child: const Icon(Icons.add),
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
  const _TimelineSubView({required this.statements, required this.onNodeTap});
  final List<Map<String, dynamic>> statements;
  final void Function(Map<String, dynamic> node) onNodeTap;

  @override
  Widget build(BuildContext context) {
    if (statements.isEmpty) {
      return const Center(
        child: AppEmptyState(
          icon: Icons.auto_stories_outlined,
          title: '아직 기록이 없습니다',
          subtitle: '+ 버튼을 눌러 첫 번째 기록을 남겨보세요',
        ),
      );
    }

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final n in statements) {
      final raw = n['created_at'] as String? ?? '';
      final date = raw.length >= 10 ? raw.substring(0, 10) : '알 수 없음';
      groups.putIfAbsent(date, () => []).add(n);
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
            // Timeline column with connecting line
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left timeline line
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
                        for (final n in items) _StatementListTile(node: n, onTap: () => onNodeTap(n)),
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
              color: isToday ? AppColors.primary : theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: Border.all(
                color: isToday ? AppColors.primary : theme.colorScheme.outline.withOpacity(0.4),
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
              color: isToday ? AppColors.primary : theme.colorScheme.onSurface.withOpacity(0.7),
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatementListTile extends StatelessWidget {
  const _StatementListTile({required this.node, required this.onTap});
  final Map<String, dynamic> node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _ctxType(node);
    final content = _stmtText(node);
    final color = _colorFor(label);
    final raw = node['created_at'] as String? ?? '';
    String timeStr = '';
    if (raw.length >= 16) {
      final dt = DateTime.tryParse(raw)?.toLocal();
      if (dt != null) {
        timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header bar with color accent
          Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
            decoration: BoxDecoration(
              color: color.withOpacity(0.07),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
                  ),
                ),
                const Spacer(),
                if (timeStr.isNotEmpty)
                  Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          // Content
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Text(
              content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    ),
    );
  }
}


// ─── Sub-view: Calendar ───────────────────────────────────────────────────────

class _CalendarSubView extends StatefulWidget {
  const _CalendarSubView({
    required this.calDays,
    required this.statements,
    required this.sharedDate,
    required this.onNodeTap,
    this.catFilter,
  });
  final Map<String, Map<String, dynamic>> calDays;
  final List<Map<String, dynamic>> statements;
  final ValueNotifier<String?> sharedDate;
  final void Function(Map<String, dynamic>) onNodeTap;
  final String? catFilter;

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

  @override
  Widget build(BuildContext context) {
    final month = _displayMonth;
    final theme = Theme.of(context);

    final selStmts = _selectedDate == null
        ? <Map<String, dynamic>>[]
        : widget.statements.where((n) {
            final raw = n['created_at'] as String? ?? '';
            return raw.startsWith(_selectedDate!);
          }).toList();

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
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
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
            // Month grid takes remaining space
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: _MonthGrid(
                  month: month,
                  calDays: widget.calDays,
                  selectedDate: _selectedDate,
                  catFilter: widget.catFilter,
                  onDayTap: (d) => setState(() => _selectedDate = _selectedDate == d ? null : d),
                  showMonthLabel: false,
                ),
              ),
            ),
          ],
        ),
        // Dim backdrop when panel is open
        if (_selectedDate != null && selStmts.isNotEmpty)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _selectedDate = null),
              child: ColoredBox(color: Colors.black.withOpacity(0.18)),
            ),
          ),
        // Selected date panel overlaid at bottom — does not affect calendar layout
        if (_selectedDate != null && selStmts.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _DayPanel(
              date: _selectedDate!,
              statements: selStmts,
              onClose: () => setState(() => _selectedDate = null),
              onNodeTap: widget.onNodeTap,
            ),
          ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    super.key,
    required this.month,
    required this.calDays,
    required this.selectedDate,
    required this.onDayTap,
    this.catFilter,
    this.showMonthLabel = true,
  });
  final DateTime month;
  final Map<String, Map<String, dynamic>> calDays;
  final String? selectedDate;
  final String? catFilter;
  final void Function(String) onDayTap;
  final bool showMonthLabel;

  static const _weekLabels = ['일', '월', '화', '수', '목', '금', '토'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstWeekday = DateTime(month.year, month.month, 1).weekday % 7; // Sun=0
    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final cells = <Widget>[];
    // Empty leading cells
    for (int i = 0; i < firstWeekday; i++) {
      cells.add(const SizedBox.shrink());
    }
    // Day cells
    for (int day = 1; day <= daysInMonth; day++) {
      final dateStr = '${month.year}-${month.month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      final data = calDays[dateStr];
      final isToday = dateStr == todayStr;
      final isSelected = dateStr == selectedDate;
      cells.add(_DayCell(
        day: day,
        data: data,
        isToday: isToday,
        isSelected: isSelected,
        catFilter: catFilter,
        onTap: data != null ? () => onDayTap(dateStr) : null,
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        if (showMonthLabel)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(
              '${month.year}년 ${month.month}월',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
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
                                  : theme.colorScheme.onSurface.withOpacity(0.5),
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
              final rowCells = cells.sublist(
                (row * 7).clamp(0, cells.length),
                ((row + 1) * 7).clamp(0, cells.length),
              ).toList();
              // Pad to 7 if last row is short
              while (rowCells.length < 7) rowCells.add(const SizedBox.shrink());
              return Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rowCells
                      .map((c) => Expanded(child: c))
                      .toList(),
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
    required this.data,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
    this.catFilter,
  });
  final int day;
  final Map<String, dynamic>? data;
  final bool isToday;
  final bool isSelected;
  final VoidCallback? onTap;
  final String? catFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = data != null;
    List<String> types = [];
    if (hasData) {
      types = (data!['context_types'] as List).cast<String>();
      if (catFilter != null) {
        types = types.where((t) => t == catFilter).toList();
      }
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
                    .take(2)
                    .map((t) => Container(
                          width: 3,
                          height: 3,
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
    required this.statements,
    required this.onClose,
    required this.onNodeTap,
  });
  final String date;
  final List<Map<String, dynamic>> statements;
  final VoidCallback onClose;
  final void Function(Map<String, dynamic>) onNodeTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
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
                  date,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${statements.length}건',
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
              itemCount: statements.length,
              itemBuilder: (_, i) => _StatementListTile(node: statements[i], onTap: () => onNodeTap(statements[i])),
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
            const Icon(Icons.error_outline, size: 48, color: AppColors.hubRecord),
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
