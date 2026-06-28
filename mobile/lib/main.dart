import 'package:flutter/material.dart';

import 'screens/journal_hub_screen.dart';
import 'screens/knowledge_graph_screen.dart';
import 'screens/kg_debug_screen.dart';
import 'screens/kg_insight_screen.dart';
import 'screens/kg_timeline_screen.dart';
import 'screens/pipeline_debug_hub_screen.dart';
import 'screens/quiz_pipeline_hub_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/vocabulary_hub_screen.dart';
import 'screens/quiz_session_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/app_ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GraphRagApp());
}

class GraphRagApp extends StatelessWidget {
  const GraphRagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyLife English',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const MainShell(),
    );
  }
}

// ─── Main shell with bottom navigation ───────────────────────────────────────

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  // Shared date notifier: Insight heatmap tap → calendar sub-view auto-scrolls
  final _sharedDate = ValueNotifier<String?>(null);
  // Incremented every time the home tab becomes active → triggers timeline refresh
  final _timelineRefresh = ValueNotifier<int>(0);

  @override
  void dispose() {
    _sharedDate.dispose();
    _timelineRefresh.dispose();
    super.dispose();
  }

  static const _titles = ['홈', '돌아보기', '학습', '더보기'];
  static const _subtitles = [
    '타임라인 · 미디어 · 캘린더',
    '성장 통계 & 활동 현황',
    '퀴즈로 복습',
    '전체 메뉴 & 설정',
  ];

  @override
  Widget build(BuildContext context) {
    // Tab 0 (홈): KgTimelineScreen has its own AppBar — hide shell AppBar
    final showAppBar = _currentIndex != 0;

    return Scaffold(
      appBar: showAppBar
          ? AppHubAppBar(
              title: _titles[_currentIndex],
              subtitle: _subtitles[_currentIndex],
              actions: _currentIndex == 3
                  ? [
                      IconButton(
                        icon: const Icon(Icons.settings_outlined),
                        tooltip: '프로필 설정',
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const SettingsScreen()),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.bug_report_outlined),
                        tooltip: '파이프라인 디버그',
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => Scaffold(
                              appBar: AppBar(title: const Text('KG 파이프라인 디버그')),
                              body: const KgDebugScreen(),
                            ),
                          ),
                        ),
                      ),
                    ]
                  : null,
            )
          : null,
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: [
            _HomeTab(sharedDate: _sharedDate, refreshSignal: _timelineRefresh),
            KgInsightScreen(
              onDateSelected: (d) {
                _sharedDate.value = d;
                // Switch to home tab so calendar becomes visible
                setState(() => _currentIndex = 0);
              },
            ),
            const _LearnTab(),
            const _MyPageTab(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) {
          if (i == 0) _timelineRefresh.value++;
          setState(() => _currentIndex = i);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart_rounded),
            label: '돌아보기',
          ),
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school_rounded),
            label: '학습',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: '더보기',
          ),
        ],
      ),
    );
  }
}

// ─── Tab: 홈 (Timeline + Media + Calendar) ────────────────────────────────────

class _HomeTab extends StatefulWidget {
  const _HomeTab({required this.sharedDate, required this.refreshSignal});
  final ValueNotifier<String?> sharedDate;
  final ValueNotifier<int> refreshSignal;

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return KgTimelineScreen(
      sharedDate: widget.sharedDate,
      refreshSignal: widget.refreshSignal,
    );
  }
}

// ─── Tab: 학습 ────────────────────────────────────────────────────────────────

class _LearnTab extends StatelessWidget {
  const _LearnTab();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageH, AppSpacing.pageV, AppSpacing.pageH, AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSectionHeader(title: '나의 지식', subtitle: '내가 모아 둔 단어 · 사람과 관계'),
          const SizedBox(height: AppSpacing.md),
          AppHubTile(
            icon: Icons.library_books_outlined,
            title: '단어장',
            subtitle: '커스텀 단어장 관리 · 일기에서 추가',
            color: AppColors.accentWarm,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const VocabularyHubScreen())),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppHubTile(
            icon: Icons.hub_outlined,
            title: '지식 그래프',
            subtitle: '노드 · 관계 탐색',
            color: AppColors.hubGraph,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const KnowledgeGraphScreen())),
          ),
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: '퀴즈 유형', subtitle: '누적된 지식그래프 기반'),
          const SizedBox(height: AppSpacing.md),
          AppHubTile(
            icon: Icons.edit_outlined,
            title: '단어 완성',
            subtitle: '빈칸 채우기 클로즈 테스트',
            color: AppColors.hubQuiz,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const QuizSessionScreen(quizType: 'cloze'))),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppHubTile(
            icon: Icons.sort_by_alpha_rounded,
            title: '문장 배열',
            subtitle: '단어를 올바른 순서로 배열하기',
            color: AppColors.hubVoice,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const QuizSessionScreen(quizType: 'scramble'))),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppHubTile(
            icon: Icons.psychology_outlined,
            title: '뉘앙스 선택',
            subtitle: '상황에 맞는 표현 고르기',
            color: AppColors.accentWarm,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const QuizSessionScreen(quizType: 'mcq_nuance'))),
          ),
        ],
      ),
    );
  }
}

// ─── Tab: 더보기 ──────────────────────────────────────────────────────────────

class _MyPageTab extends StatelessWidget {
  const _MyPageTab();

  void _open(BuildContext context, Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageH, AppSpacing.pageV, AppSpacing.pageH, AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 프로필 카드 ──────────────────────────────────────────────────
          _ProfileHeader(onTap: () => _open(context, const SettingsScreen())),
          const SizedBox(height: AppSpacing.xl),

          // ── 내 일기 ──────────────────────────────────────────────────────────
          const AppSectionHeader(title: '내 기록', subtitle: '일기 · 지식그래프'),
          const SizedBox(height: AppSpacing.md),
          AppHubTile(
            icon: Icons.auto_stories_outlined,
            title: '내 일기',
            subtitle: '번역 · 화자 확인 · 지식그래프 이동',
            color: AppColors.accent,
            onTap: () => _open(context, const JournalHubScreen()),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppHubTile(
            icon: Icons.account_tree_rounded,
            title: '지식 그래프',
            subtitle: '내 지식 노드 전체 보기',
            color: AppColors.hubGraph,
            onTap: () => _open(context, const KnowledgeGraphScreen()),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ── 개발자 도구 ───────────────────────────────────────────────────
          const AppSectionHeader(title: '개발자 도구', subtitle: '내부 디버깅 전용'),
          const SizedBox(height: AppSpacing.md),
          AppHubTile(
            icon: Icons.account_tree_outlined,
            title: '파이프라인',
            subtitle: '음성·텍스트 기록별 처리 trace · GraphRAG 단계',
            color: AppColors.hubVoice,
            onTap: () => _open(context, const PipelineDebugHubScreen()),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppHubTile(
            icon: Icons.quiz_outlined,
            title: '문제 생성',
            subtitle: '지식 그래프 · Quiz Path trace',
            color: AppColors.hubQuiz,
            onTap: () => _open(context, const QuizPipelineHubScreen()),
          ),
        ],
      ),
    );
  }
}

// ─── Profile header card ──────────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withOpacity(0.35),
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          border: Border.all(color: cs.primary.withOpacity(0.18)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: cs.primary,
              child: Icon(Icons.person_rounded, color: cs.onPrimary, size: 28),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('내 프로필',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('레벨 · 목표 언어 · 학습 목적 설정',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.textMuted)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: cs.primary),
          ],
        ),
      ),
    );
  }
}
