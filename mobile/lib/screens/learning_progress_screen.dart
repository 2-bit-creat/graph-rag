import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'kg_insight_screen.dart';
import 'quiz_session_screen.dart';

List<String> get _weekdays => [
  tr('progress.weekdayMon'), tr('progress.weekdayTue'), tr('progress.weekdayWed'),
  tr('progress.weekdayThu'), tr('progress.weekdayFri'), tr('progress.weekdaySat'),
  tr('progress.weekdaySun'),
];

/// 내 학습률 — quiz progress AND the record insights that used to live on their
/// own "기록 인사이트" page.
///
/// The two screens answered nearly the same question ("how am I doing?") from
/// two angles (what I studied vs. what I recorded), so they were two menu
/// entries competing for one intent. They're now two tabs behind a single
/// destination. The 기록 tab's network calls are deferred until it is first
/// opened, so the merge costs nothing to anyone who only ever looks at 학습.
class LearningProgressScreen extends StatefulWidget {
  const LearningProgressScreen({super.key});

  @override
  State<LearningProgressScreen> createState() => _LearningProgressScreenState();
}

class _LearningProgressScreenState extends State<LearningProgressScreen>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _dashboard;
  Map<String, dynamic>? _profile;
  Object? _error;
  bool _loading = true;

  late final TabController _tabs;
  bool _insightVisited = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    // Track the *animation*, not just `index`: a drag moves the view before the
    // index commits, so keying off index alone would show a blank page for the
    // whole swipe.
    _tabs.animation?.addListener(_onTabMoved);
    _load();
  }

  @override
  void dispose() {
    _tabs.animation?.removeListener(_onTabMoved);
    _tabs.dispose();
    super.dispose();
  }

  /// Build the 기록 tab only once it has actually started coming into view.
  void _onTabMoved() {
    if (_insightVisited) return;
    if ((_tabs.animation?.value ?? 0) <= 0.001) return;
    setState(() => _insightVisited = true);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        apiClient.getQuizProgressDashboard(),
        apiClient.getQuizProfile(),
      ]);
      if (!mounted) return;
      setState(() {
        _dashboard = results[0];
        _profile = results[1];
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _start(String type) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QuizSessionScreen(quizType: type)),
    );
    await _load();
  }

  Future<void> _editGoals() async {
    // Reachable from the app bar, which is now painted before the first load
    // finishes — an unguarded `_profile!` would throw on an early tap.
    final profile = _profile;
    if (profile == null) return;
    var cloze = (profile['daily_cloze_target'] as num?)?.toInt() ?? 20;
    var composition =
        (profile['daily_composition_target'] as num?)?.toInt() ?? 5;
    var saving = false;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('progress.goalSheetTitle'), style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(tr('progress.goalSheetSubtitle')),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in [
                      (tr('progress.presetLight'), 10, 2),
                      (tr('progress.presetSteady'), 20, 5),
                      (tr('progress.presetIntense'), 40, 10),
                    ])
                      ChoiceChip(
                        label: Text(preset.$1),
                        selected: cloze == preset.$2 && composition == preset.$3,
                        onSelected: (_) => setSheetState(() {
                          cloze = preset.$2;
                          composition = preset.$3;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                _GoalStepper(
                  label: tr('progress.words'),
                  value: cloze,
                  onChanged: (value) => setSheetState(() => cloze = value),
                ),
                const SizedBox(height: 12),
                _GoalStepper(
                  label: tr('progress.writing'),
                  value: composition,
                  max: 50,
                  onChanged: (value) => setSheetState(() => composition = value),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  // A failed save used to throw out of the callback and leave
                  // the sheet sitting open with no explanation, looking like a
                  // dead button.
                  onPressed: saving
                      ? null
                      : () async {
                          setSheetState(() => saving = true);
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await apiClient.updateQuizProfileSettings(
                              dailyClozeTarget: cloze,
                              dailyCompositionTarget: composition,
                            );
                            if (context.mounted) Navigator.pop(context, true);
                          } catch (error) {
                            setSheetState(() => saving = false);
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(tr('progress.goalSaveFailed')),
                              ),
                            );
                          }
                        },
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(tr('progress.saveGoal')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('progress.title')),
        actions: [
          // Goal editing belongs to the 학습 tab only; showing it over 기록
          // would be an action with nothing to act on.
          AnimatedBuilder(
            animation: _tabs,
            builder: (context, _) => _tabs.index == 0
                ? IconButton(
                    tooltip: tr('progress.goalTooltip'),
                    onPressed: _profile == null ? null : _editGoals,
                    icon: const Icon(Icons.tune_rounded),
                  )
                : const SizedBox.shrink(),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: tr('progress.tabLearning')),
            Tab(text: tr('progress.tabRecord')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildLearningTab(context),
          // Deferred: nothing here hits the network until the tab is reached.
          // Kept alive afterwards — TabBarView disposes off-screen children, so
          // without this the 기록 tab would refetch its stats on every switch
          // back. The 학습 tab needs no equivalent: its data lives in this state,
          // not in the child.
          _insightVisited
              ? const _KeepAlive(child: KgInsightScreen())
              : const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget _buildLearningTab(BuildContext context) {
    if (_loading) {
      return AppLoadingScreen(message: tr('progress.loading'));
    }
    if (_error != null) {
      return AppEmptyState(
        icon: Icons.cloud_off_rounded,
        title: tr('progress.loadFailed'),
        subtitle: '$_error',
        action: FilledButton(onPressed: _load, child: Text(tr('progress.retry'))),
      );
    }
    final data = _dashboard!;
    final today = Map<String, dynamic>.from(data['today'] as Map);
    final week = (data['week'] as List? ?? const [])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final achievements = (data['achievements'] as List? ?? const [])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final totalXp = (data['total_xp'] as num?)?.toInt() ?? 0;
    final startXp = (data['level_start_xp'] as num?)?.toInt() ?? 0;
    final nextXp = (data['next_level_xp'] as num?)?.toInt() ?? 100;
    final levelProgress =
        ((totalXp - startXp) / (nextXp - startXp).clamp(1, 1 << 30)).clamp(0.0, 1.0);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
        children: [
          _HeroCard(data: data, levelProgress: levelProgress),
          const SizedBox(height: 14),
          _TodayMissionCard(
            today: today,
            onCloze: () => _start('cloze'),
            onComposition: () => _start('composition'),
            onEdit: _editGoals,
          ),
          const SizedBox(height: 18),
          _SectionTitle(
            title: tr('progress.weekTitle'),
            subtitle: tr('progress.weekSubtitle'),
          ),
          const SizedBox(height: 10),
          _WeekCard(week: week),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  icon: Icons.local_fire_department_rounded,
                  color: const Color(0xFFFF7A45),
                  value: tr('progress.days', {'count': data['longest_streak'] ?? 0}),
                  label: tr('progress.longestStreak'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  icon: Icons.task_alt_rounded,
                  color: const Color(0xFF5B67F1),
                  value: tr('progress.items', {'count': data['week_completed'] ?? 0}),
                  label: tr('progress.weekCompleted'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  icon: Icons.track_changes_rounded,
                  color: const Color(0xFF13A88A),
                  value:
                      '${(((data['accuracy'] as num?)?.toDouble() ?? 0) * 100).round()}%',
                  label: tr('progress.recentAccuracy'),
                ),
              ),
            ],
          ),
          if (achievements.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle(
              title: tr('progress.badgesTitle'),
              subtitle: tr('progress.badgesSubtitle'),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 154,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: achievements.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) =>
                    _AchievementCard(data: achievements[index]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Holds a TabBarView page's State across tab switches.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.data, required this.levelProgress});
  final Map<String, dynamic> data;
  final double levelProgress;

  @override
  Widget build(BuildContext context) {
    final streak = (data['current_streak'] as num?)?.toInt() ?? 0;
    final atRisk = data['streak_at_risk'] == true;
    return Semantics(
      label: tr('progress.streakSemantics', {'streak': streak}),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF5A50E8), Color(0xFF8C4FE7), Color(0xFFFF754D)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6954E8).withValues(alpha: .25),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .17),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.local_fire_department_rounded,
                    color: Color(0xFFFFE082),
                    size: 38,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('progress.streakDays', {'streak': streak}),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 27,
                        ),
                      ),
                      Text(
                        // With no streak yet there is nothing to continue or
                        // protect — "오늘도 이어가고 있어요" under a bold 0일
                        // contradicts the number right above it. Invite a start.
                        streak <= 0
                            ? tr('progress.streakNone')
                            : (atRisk
                                ? tr('progress.streakAtRisk')
                                : tr('progress.streakOnTrack')),
                        style: TextStyle(color: Colors.white.withValues(alpha: .84)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Text(
                  tr('progress.growthLevel', {'level': data['growth_level'] ?? 1}),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Text(
                  tr('progress.xpSummary', {'total': data['total_xp'] ?? 0, 'today': data['today_xp'] ?? 0}),
                  style: TextStyle(color: Colors.white.withValues(alpha: .9)),
                ),
              ],
            ),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: levelProgress,
                minHeight: 9,
                backgroundColor: Colors.white.withValues(alpha: .2),
                valueColor: const AlwaysStoppedAnimation(Color(0xFFFFE082)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodayMissionCard extends StatelessWidget {
  const _TodayMissionCard({
    required this.today,
    required this.onCloze,
    required this.onComposition,
    required this.onEdit,
  });
  final Map<String, dynamic> today;
  final VoidCallback onCloze;
  final VoidCallback onComposition;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => AppSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    today['perfect'] == true ? tr('progress.missionDone') : tr('progress.missionTitle'),
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                ),
                IconButton(
                  tooltip: tr('progress.goalEditTooltip'),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            Text(
              tr('progress.missionSubtitle', {'count': today['language_count'] ?? 1}),
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            _MissionRow(
              icon: Icons.spellcheck_rounded,
              label: tr('progress.words'),
              current: (today['cloze'] as num?)?.toInt() ?? 0,
              goal: (today['cloze_goal'] as num?)?.toInt() ?? 0,
              color: const Color(0xFF5B67F1),
              onStart: onCloze,
            ),
            const SizedBox(height: 14),
            _MissionRow(
              icon: Icons.edit_note_rounded,
              label: tr('progress.writing'),
              current: (today['composition'] as num?)?.toInt() ?? 0,
              goal: (today['composition_goal'] as num?)?.toInt() ?? 0,
              color: const Color(0xFF13A88A),
              onStart: onComposition,
            ),
          ],
        ),
      );
}

class _MissionRow extends StatelessWidget {
  const _MissionRow({
    required this.icon,
    required this.label,
    required this.current,
    required this.goal,
    required this.color,
    required this.onStart,
  });
  final IconData icon;
  final String label;
  final int current;
  final int goal;
  final Color color;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final progress = goal == 0 ? 0.0 : (current / goal).clamp(0.0, 1.0);
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text('$current / $goal'),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 7,
                  color: color,
                  backgroundColor: color.withValues(alpha: .12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.tonal(onPressed: onStart, child: Text(tr('progress.startStudy'))),
      ],
    );
  }
}

/// One malformed date in the week payload used to throw out of `build` and blank
/// the whole screen; a missing label costs nothing by comparison.
String _weekdayLabel(Object? raw) {
  final parsed = DateTime.tryParse(raw?.toString() ?? '');
  return parsed == null ? '' : _weekdays[parsed.weekday - 1];
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.week});
  final List<Map<String, dynamic>> week;

  @override
  Widget build(BuildContext context) {
    final maxValue = week.fold<int>(
      1,
      (max, row) {
        final value = ((row['cloze'] as num?)?.toInt() ?? 0) +
            ((row['composition'] as num?)?.toInt() ?? 0);
        return value > max ? value : max;
      },
    );
    return AppSurfaceCard(
      child: SizedBox(
        height: 150,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final row in week)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        '${((row['cloze'] as num?)?.toInt() ?? 0) + ((row['composition'] as num?)?.toInt() ?? 0)}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Flexible(
                        child: FractionallySizedBox(
                          heightFactor: ((((row['cloze'] as num?)?.toDouble() ?? 0) +
                                      ((row['composition'] as num?)?.toDouble() ?? 0)) /
                                  maxValue)
                              .clamp(.06, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF5B67F1), Color(0xFF9B5DE5)],
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _weekdayLabel(row['date']),
                        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                      ),
                      if (row['perfect'] == true)
                        const Icon(Icons.star_rounded, size: 13, color: Color(0xFFFFB020))
                      else
                        const SizedBox(height: 13),
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

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => AppSurfaceCard(
        child: Column(
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
        ),
      );
}

/// The dashboard's `title` field is a Korean literal baked into the backend, so
/// an English account was reading Korean badge names on an otherwise English
/// screen. Localise off the stable `id` and fall back to the server string for
/// any badge the app doesn't know yet.
String _badgeTitle(Map<String, dynamic> data) {
  final id = data['id']?.toString() ?? '';
  final key = 'progress.badge.$id';
  final localized = tr(key);
  if (localized != key) return localized;
  return data['title']?.toString() ?? '';
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final unlocked = data['unlocked'] == true;
    final current = (data['current'] as num?)?.toInt() ?? 0;
    final target = (data['target'] as num?)?.toInt() ?? 1;
    return SizedBox(
      width: 132,
      child: AppSurfaceCard(
        child: Column(
          children: [
            CircleAvatar(
              radius: 25,
              backgroundColor: (unlocked ? const Color(0xFFFFB020) : AppColors.textMuted)
                  .withValues(alpha: .14),
              child: Icon(
                unlocked ? Icons.workspace_premium_rounded : Icons.lock_outline_rounded,
                color: unlocked ? const Color(0xFFFFA000) : AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _badgeTitle(data),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: (current / target).clamp(0.0, 1.0),
              minHeight: 5,
              borderRadius: BorderRadius.circular(99),
            ),
            const SizedBox(height: 3),
            Text('$current / $target', style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          Text(subtitle, style: const TextStyle(color: AppColors.textMuted)),
        ],
      );
}

class _GoalStepper extends StatelessWidget {
  const _GoalStepper({
    required this.label,
    required this.value,
    required this.onChanged,
    this.max = 100,
  });
  final String label;
  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800))),
          IconButton(
            onPressed: value <= 0 ? null : () => onChanged((value - 1).clamp(0, max)),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 42,
            child: Text('$value', textAlign: TextAlign.center),
          ),
          IconButton(
            onPressed: value >= max ? null : () => onChanged((value + 1).clamp(0, max)),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      );
}
