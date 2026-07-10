import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'journal_hub_screen.dart';
import 'kg_debug_screen.dart';
import 'kg_insight_screen.dart';
import 'pipeline_debug_hub_screen.dart';
import 'quiz_generation_screen.dart';
import 'quiz_pipeline_hub_screen.dart';
import 'quiz_queue_screen.dart';
import 'settings_screen.dart';
import 'tutor_vocab_screen.dart';
import 'vocabulary_hub_screen.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  bool _devToolsExpanded = false;

  void _open(Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('메뉴')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH, AppSpacing.pageV, AppSpacing.pageH, AppSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileHeader(onTap: () => _open(const SettingsScreen())),
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(title: '기록', subtitle: '일기 · 학습'),
            const SizedBox(height: AppSpacing.md),
            AppHubTile(
              icon: Icons.auto_stories_outlined,
              title: '내 일기',
              subtitle: '번역 · 화자 확인 · 지식그래프 반영',
              color: AppColors.accent,
              onTap: () => _open(const JournalHubScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.bar_chart_rounded,
              title: '인사이트',
              subtitle: '성장 통계 & 자동 현황',
              color: AppColors.hubVoice,
              onTap: () => _open(
                Scaffold(
                  appBar: AppBar(title: const Text('인사이트')),
                  body: const KgInsightScreen(),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            const AppSectionHeader(
                title: '학습', subtitle: '표현 · 단어장 · 복습 도구'),
            const SizedBox(height: AppSpacing.md),
            AppHubTile(
              icon: Icons.style_rounded,
              title: '튜터에 배운 표현',
              subtitle: '강의 중 저장한 표현 모음 · 복습 출제 포함',
              color: AppColors.accentWarm,
              onTap: () => _open(const TutorVocabScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.menu_book_rounded,
              title: '단어장 · 표현 저장',
              subtitle: '내 단어장 · 그래프에서 추출한 표현',
              color: AppColors.accent,
              onTap: () => _open(const VocabularyHubScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.playlist_add_check_rounded,
              title: '퀴즈 큐',
              subtitle: '대기 · 복습 설정 문제 관리',
              color: AppColors.hubQuiz,
              onTap: () => _open(const QuizQueueScreen()),
            ),
            const SizedBox(height: AppSpacing.xl),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _devToolsExpanded = !_devToolsExpanded),
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Row(
                    children: [
                      const Expanded(
                        child: AppSectionHeader(
                          title: '개발자 도구',
                          subtitle: '문제 생성 · 파이프라인 디버그',
                        ),
                      ),
                      Icon(
                        _devToolsExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        color: context.mutedText,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_devToolsExpanded) ...[
              const SizedBox(height: AppSpacing.md),
              AppHubTile(
                icon: Icons.auto_fix_high_rounded,
                title: '문제 생성',
                subtitle: '일기 기른 샘플 문제 만들기 · 대기열 관리',
                color: AppColors.hubQuiz,
                onTap: () => _open(const QuizGenerationScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.account_tree_outlined,
                title: '파이프라인',
                subtitle: '생성·스테이징·기록 처리 trace · GraphRAG 단계',
                color: AppColors.hubVoice,
                onTap: () => _open(const PipelineDebugHubScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.quiz_outlined,
                title: 'Quiz Path',
                subtitle: '지식그래프 · Quiz Path trace',
                color: AppColors.hubQuiz,
                onTap: () => _open(const QuizPipelineHubScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.bug_report_outlined,
                title: 'KG 디버그',
                subtitle: 'KG 파이프라인 실행 기록',
                color: AppColors.hubVoice,
                onTap: () => _open(
                  Scaffold(
                    appBar: AppBar(title: const Text('KG 파이프라인 디버그')),
                    body: const KgDebugScreen(),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

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
          color: cs.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
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
                  Text('마이프로필',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('이름 · 모국어 · 학습 목적 설정',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.mutedText)),
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
