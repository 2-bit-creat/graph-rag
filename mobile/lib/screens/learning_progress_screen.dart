import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'quiz_session_screen.dart';

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

class LearningProgressScreen extends StatefulWidget {
  const LearningProgressScreen({super.key});

  @override
  State<LearningProgressScreen> createState() => _LearningProgressScreenState();
}

class _LearningProgressScreenState extends State<LearningProgressScreen> {
  Map<String, dynamic>? _dashboard;
  Map<String, dynamic>? _profile;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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
    final profile = _profile!;
    var cloze = (profile['daily_cloze_target'] as num?)?.toInt() ?? 20;
    var composition =
        (profile['daily_composition_target'] as num?)?.toInt() ?? 5;
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
                Text('일일 학습 목표', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                const Text('활성 Target 언어마다 적용됩니다.'),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in const [
                      ('가볍게', 10, 2),
                      ('꾸준히', 20, 5),
                      ('집중', 40, 10),
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
                  label: '단어',
                  value: cloze,
                  onChanged: (value) => setSheetState(() => cloze = value),
                ),
                const SizedBox(height: 12),
                _GoalStepper(
                  label: '작문',
                  value: composition,
                  max: 50,
                  onChanged: (value) => setSheetState(() => composition = value),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    await apiClient.updateQuizProfileSettings(
                      dailyClozeTarget: cloze,
                      dailyCompositionTarget: composition,
                    );
                    if (context.mounted) Navigator.pop(context, true);
                  },
                  child: const Text('목표 저장'),
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
    if (_loading) {
      return const Scaffold(body: AppLoadingScreen(message: '학습 성장을 계산하는 중…'));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('내 학습률')),
        body: AppEmptyState(
          icon: Icons.cloud_off_rounded,
          title: '학습률을 불러오지 못했습니다',
          subtitle: '$_error',
          action: FilledButton(onPressed: _load, child: const Text('다시 시도')),
        ),
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('내 학습률'),
        actions: [
          IconButton(
            tooltip: '목표 설정',
            onPressed: _editGoals,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
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
            const _SectionTitle(
              title: '이번 주의 리듬',
              subtitle: '작은 학습이 쌓인 흐름을 확인해 보세요',
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
                    value: '${data['longest_streak'] ?? 0}일',
                    label: '최고 연속 기록',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MetricCard(
                    icon: Icons.task_alt_rounded,
                    color: const Color(0xFF5B67F1),
                    value: '${data['week_completed'] ?? 0}개',
                    label: '이번 주 완료',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MetricCard(
                    icon: Icons.track_changes_rounded,
                    color: const Color(0xFF13A88A),
                    value:
                        '${(((data['accuracy'] as num?)?.toDouble() ?? 0) * 100).round()}%',
                    label: '최근 정답률',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const _SectionTitle(
              title: '나의 배지',
              subtitle: '꾸준함이 새로운 배지를 열어 줍니다',
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
        ),
      ),
    );
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
      label: '현재 연속 학습 $streak일',
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
                        '$streak일 연속',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 27,
                        ),
                      ),
                      Text(
                        atRisk ? '오늘 한 문제로 불꽃을 지켜 주세요' : '오늘도 성장 기록을 이어가고 있어요',
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
                  '성장 Lv.${data['growth_level'] ?? 1}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Text(
                  '${data['total_xp'] ?? 0} XP · 오늘 +${data['today_xp'] ?? 0}',
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
                    today['perfect'] == true ? '오늘의 미션 완료!' : '오늘의 미션',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                ),
                IconButton(
                  tooltip: '목표 편집',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            Text(
              '${today['language_count'] ?? 1}개 Target 언어의 목표를 합산합니다',
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            _MissionRow(
              icon: Icons.spellcheck_rounded,
              label: '단어',
              current: (today['cloze'] as num?)?.toInt() ?? 0,
              goal: (today['cloze_goal'] as num?)?.toInt() ?? 0,
              color: const Color(0xFF5B67F1),
              onStart: onCloze,
            ),
            const SizedBox(height: 14),
            _MissionRow(
              icon: Icons.edit_note_rounded,
              label: '작문',
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
        FilledButton.tonal(onPressed: onStart, child: const Text('학습')),
      ],
    );
  }
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
                        _weekdays[DateTime.parse(row['date'].toString()).weekday - 1],
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
              data['title']?.toString() ?? '',
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
