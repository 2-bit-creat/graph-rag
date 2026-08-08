import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

// ─── Statement description parser ────────────────────────────────────────────
// context_type is a canonical Korean value from the backend taxonomy — kept
// as-is here; display translation happens via _kSourceLabels below.

String _stmtCtxType(Map<String, dynamic> node) {
  final f = node['context_type']?.toString();
  if (f != null && f.isNotEmpty) return f;
  final desc = (node['description'] as String? ?? '').trim();
  if (desc.startsWith('{')) {
    try { return ((jsonDecode(desc) as Map)['context_type'] as String? ?? '미분류').trim(); } catch (_) {}
  }
  return desc.split('\n').first.trim().isEmpty ? '미분류' : desc.split('\n').first.trim();
}

// Same canonical taxonomy as kg_timeline_screen's _kTypeLabels.
Map<String, String> get _kSourceLabels => {
      '개인일기': tr('timeline.typePersonalDiary'),
      '회의록': tr('timeline.typeMeetingNotes'),
      '책': tr('timeline.typeBook'),
      '뉴스': tr('timeline.typeNews'),
      '강연': tr('timeline.typeLecture'),
      '논문': tr('timeline.typePaper'),
      '대화': tr('timeline.typeConversation'),
      '잡지': tr('timeline.typeMagazine'),
      '자료': tr('timeline.typeMaterial'),
      '미분류': tr('inspector.uncategorized'),
    };
String _sourceLabelFor(String type) => _kSourceLabels[type] ?? type;

// ─── Color palette for donut segments ─────────────────────────────────────────

const List<Color> _kSegmentColors = [
  AppColors.primary,
  AppColors.accent,
  AppColors.accentWarm,
  Color(0xFF8B5CF6),
  Color(0xFFEC4899),
  Color(0xFF14B8A6),
];

// ─── Screen ───────────────────────────────────────────────────────────────────

class KgInsightScreen extends StatefulWidget {
  const KgInsightScreen({super.key, this.onDateSelected});

  /// Called when the user taps a heatmap cell with entries.
  /// Parent (MainShell) can use this to sync the calendar sub-view.
  final void Function(String date)? onDateSelected;

  @override
  State<KgInsightScreen> createState() => _KgInsightScreenState();
}

class _KgInsightScreenState extends State<KgInsightScreen> {
  Map<String, dynamic>? _stats;
  bool _loading = true;
  String? _error;
  String? _selectedDate;         // tapped heatmap date (ISO "2026-06-26")

  // Day feed, fetched per tapped date instead of filtered out of a full graph
  // dump. Cached so re-tapping a day is instant.
  final Map<String, List<Map<String, dynamic>>> _dayFeeds = {};
  String? _dayFeedLoading;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final stats = await apiClient.getKgStats();
      if (mounted) {
        setState(() {
          _stats = stats;
          _dayFeeds.clear();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadDay(String date) async {
    if (_dayFeeds.containsKey(date) || _dayFeedLoading == date) return;
    setState(() => _dayFeedLoading = date);
    try {
      final rows = await apiClient.getKgStatementsByDate(date);
      if (!mounted) return;
      setState(() {
        _dayFeeds[date] = rows;
        _dayFeedLoading = null;
      });
    } catch (_) {
      // A failed day feed shouldn't blank the dashboard behind it — fall back
      // to an empty list, which renders the "nothing this day" line.
      if (!mounted) return;
      setState(() {
        _dayFeeds[date] = const [];
        _dayFeedLoading = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return AppLoadingScreen(message: tr('insight.loadingMessage'));
    if (_error != null) {
      final isOffline = _error!.contains(tr('client.connectionFailed')) ||
          _error!.contains('connectionError');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOffline ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
                size: 56,
                color: isOffline ? AppColors.textMuted : Colors.redAccent,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                isOffline ? tr('insight.offlineTitle') : tr('insight.errorTitle'),
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              // Offline used to print the developer's uvicorn command here —
              // meaningless (and slightly alarming) to an actual learner.
              Text(
                isOffline
                    ? tr('insight.offlineSubtitle')
                    : tr('insight.errorSubtitle'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(tr('common.retry')),
              ),
            ],
          ),
        ),
      );
    }

    final stats = _stats!;
    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH, AppSpacing.pageV,
          AppSpacing.pageH, AppSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Stats grid ───────────────────────────────────────────────
            _StatsGrid(stats: stats),
            const SizedBox(height: AppSpacing.xxl),

            // ── Heatmap ──────────────────────────────────────────────────
            AppSectionHeader(title: tr('insight.heatmapTitle'), subtitle: tr('insight.heatmapSubtitle')),
            const SizedBox(height: AppSpacing.md),
            _HeatmapGrid(
              dailyActivity: (stats['daily_activity'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>(),
              selectedDate: _selectedDate,
              onDateTapped: (date) {
                setState(() {
                  _selectedDate = _selectedDate == date ? null : date;
                });
                if (_selectedDate != null) {
                  widget.onDateSelected?.call(_selectedDate!);
                  _loadDay(_selectedDate!);
                }
              },
            ),

            // ── Day feed ─────────────────────────────────────────────────
            if (_selectedDate != null) ...[
              const SizedBox(height: AppSpacing.lg),
              _DayFeed(
                date: _selectedDate!,
                statements: _dayFeeds[_selectedDate!],
                loading: _dayFeedLoading == _selectedDate,
              ),
            ],

            const SizedBox(height: AppSpacing.xxl),

            // ── Donut chart ──────────────────────────────────────────────
            AppSectionHeader(title: tr('insight.donutTitle'), subtitle: tr('insight.donutSubtitle')),
            const SizedBox(height: AppSpacing.md),
            _SourceDonut(
              distribution: (stats['source_distribution'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>(),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Stats grid ───────────────────────────────────────────────────────────────

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});
  final Map<String, dynamic> stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _StatCard(
          label: tr('insight.statTotalRecords'),
          value: '${stats['total_statements'] ?? 0}',
          icon: Icons.format_quote_rounded,
          color: AppColors.primary,
        )),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: _StatCard(
          label: tr('insight.statTotalConcepts'),
          value: '${stats['total_concepts'] ?? 0}',
          icon: Icons.label_outline,
          color: AppColors.accent,
        )),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: _StatCard(
          label: tr('insight.statStreak'),
          value: tr('insight.streakDaysSuffix', {'count': stats['streak_days'] ?? 0}),
          icon: Icons.local_fire_department_rounded,
          color: AppColors.accentWarm,
        )),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                  height: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Heatmap grid ─────────────────────────────────────────────────────────────

class _HeatmapGrid extends StatelessWidget {
  const _HeatmapGrid({
    required this.dailyActivity,
    required this.selectedDate,
    required this.onDateTapped,
  });
  final List<Map<String, dynamic>> dailyActivity;
  final String? selectedDate;
  final void Function(String) onDateTapped;

  static const int _weeks = 13; // ~3 months — fits on one phone screen
  static const int _days = 7;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    // Align to Sunday of the current week (7 * 52 = 364 days back)
    final startOffset = today.weekday % 7; // days since Sunday
    final startDay = today.subtract(Duration(days: startOffset + (_weeks - 1) * 7 + 6));

    final countMap = <String, int>{};
    for (final e in dailyActivity) {
      countMap[e['date'] as String] = (e['count'] as num).toInt();
    }
    final maxCount = countMap.values.fold(0, (a, b) => a > b ? a : b);

    Color cellColor(String date) {
      final c = countMap[date] ?? 0;
      if (c == 0) return Theme.of(context).colorScheme.surfaceContainerHighest;
      final intensity = maxCount > 0 ? (c / maxCount).clamp(0.15, 1.0) : 0.3;
      return AppColors.primary.withValues(alpha: intensity);
    }

    return AppSurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          // Day-of-week labels
          Row(
            children: [
              const SizedBox(width: 14),
              ...List.generate(_weeks, (w) {
                final date = startDay.add(Duration(days: w * 7));
                // Show month label on first day of month in that column
                final label = (date.day <= 7) ? DateFormat(tr('insight.monthFormat')).format(date) : '';
                return Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 8), textAlign: TextAlign.center),
                );
              }),
            ],
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: _days * 12.0 + (_days - 1) * 2.0,
            child: Row(
              children: [
                // Day labels (Mon/Wed/Fri)
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                        tr('insight.weekdaySunShort'),
                        tr('insight.weekdayMonShort'),
                        tr('insight.weekdayTueShort'),
                        tr('insight.weekdayWedShort'),
                        tr('insight.weekdayThuShort'),
                        tr('insight.weekdayFriShort'),
                        tr('insight.weekdaySatShort'),
                      ]
                      .map((d) => SizedBox(
                            width: 12,
                            child: Text(d, style: const TextStyle(fontSize: 7),
                                textAlign: TextAlign.center),
                          ))
                      .toList(),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Row(
                    children: List.generate(_weeks, (w) {
                      return Expanded(
                        child: Column(
                          children: List.generate(_days, (d) {
                            final date = startDay.add(Duration(days: w * 7 + d));
                            if (date.isAfter(today)) {
                              return const Expanded(child: SizedBox.shrink());
                            }
                            final iso = DateFormat('yyyy-MM-dd').format(date);
                            final isSelected = selectedDate == iso;
                            final isToday = iso == DateFormat('yyyy-MM-dd').format(today);
                            return Expanded(
                              child: GestureDetector(
                                onTap: () => onDateTapped(iso),
                                child: Container(
                                  margin: const EdgeInsets.all(1),
                                  decoration: BoxDecoration(
                                    color: cellColor(iso),
                                    borderRadius: BorderRadius.circular(2),
                                    border: Border.all(
                                      color: isSelected
                                          ? AppColors.primary
                                          : isToday
                                              ? AppColors.primary.withValues(alpha: 0.5)
                                              : Colors.transparent,
                                      width: isSelected ? 1.5 : 1,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(tr('insight.less'), style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted, fontSize: 10,
              )),
              const SizedBox(width: 4),
              ...List.generate(5, (i) => Container(
                width: 10, height: 10,
                margin: const EdgeInsets.only(right: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15 + i * 0.17),
                  borderRadius: BorderRadius.circular(2),
                ),
              )),
              const SizedBox(width: 4),
              Text(tr('insight.more'), style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted, fontSize: 10,
              )),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Day feed ─────────────────────────────────────────────────────────────────

class _DayFeed extends StatelessWidget {
  const _DayFeed({
    required this.date,
    required this.statements,
    required this.loading,
  });
  final String date;

  /// Null until this day's feed has been fetched.
  final List<Map<String, dynamic>>? statements;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final rows = statements;
    if (rows == null || loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeader(
          title: DateFormat(tr('insight.monthDayFormat')).format(DateTime.parse(date)),
          subtitle: tr('insight.recordCountSuffix', {'count': rows.length}),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (rows.isEmpty)
          Text(tr('insight.noStatementsThisDay'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textMuted))
        else
          for (final s in rows) ...[
            AppSurfaceCard(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _sourceLabelFor(_stmtCtxType(s)),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s['name']?.toString() ?? '',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
      ],
    );
  }
}

// ─── Donut chart ──────────────────────────────────────────────────────────────

class _SourceDonut extends StatefulWidget {
  const _SourceDonut({required this.distribution});
  final List<Map<String, dynamic>> distribution;

  @override
  State<_SourceDonut> createState() => _SourceDonutState();
}

class _SourceDonutState extends State<_SourceDonut> {
  int _touchedIndex = -1;

  @override
  Widget build(BuildContext context) {
    if (widget.distribution.isEmpty) {
      return AppEmptyState(
        icon: Icons.pie_chart_outline,
        title: tr('insight.noDataTitle'),
        subtitle: tr('insight.noDataSubtitle'),
      );
    }

    final total = widget.distribution
        .fold<int>(0, (sum, e) => sum + (e['count'] as num).toInt());

    final sections = widget.distribution.asMap().entries.map((entry) {
      final i = entry.key;
      final e = entry.value;
      final count = (e['count'] as num).toInt();
      final pct = total > 0 ? count / total : 0.0;
      final isTouched = i == _touchedIndex;
      final color = _kSegmentColors[i % _kSegmentColors.length];
      return PieChartSectionData(
        value: count.toDouble(),
        color: color,
        radius: isTouched ? 60 : 52,
        title: isTouched ? '${(pct * 100).toStringAsFixed(1)}%' : '',
        titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
      );
    }).toList();

    return AppSurfaceCard(
      child: Column(
        children: [
          SizedBox(
            height: 200,
            child: PieChart(
              PieChartData(
                sections: sections,
                centerSpaceRadius: 48,
                sectionsSpace: 2,
                pieTouchData: PieTouchData(
                  touchCallback: (event, response) {
                    if (!event.isInterestedForInteractions ||
                        response == null ||
                        response.touchedSection == null) {
                      setState(() => _touchedIndex = -1);
                      return;
                    }
                    setState(() => _touchedIndex =
                        response.touchedSection!.touchedSectionIndex);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.sm,
            alignment: WrapAlignment.center,
            children: widget.distribution.asMap().entries.map((entry) {
              final i = entry.key;
              final e = entry.value;
              final color = _kSegmentColors[i % _kSegmentColors.length];
              final count = (e['count'] as num).toInt();
              final pct = total > 0 ? (count / total * 100).toStringAsFixed(0) : '0';
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 10, height: 10,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(
                    '${_sourceLabelFor(e['source']?.toString() ?? '')} $pct%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
