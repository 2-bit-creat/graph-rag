import 'package:flutter/material.dart';

import '../auth/account_controller.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../theme/app_theme_controller.dart';
import '../widgets/app_ui.dart';
import 'accounts_overview_screen.dart';
import 'pipeline_debug_hub_screen.dart';
import 'quiz_generation_screen.dart';
import 'quiz_pipeline_hub_screen.dart';
import 'kg_debug_screen.dart';
import 'settings_screen.dart';

/// 계정 · 설정. 내 일기/돌아보기/단어장/퀴즈 큐 같은 자주 쓰는 목적지는 이제
/// [ChatSidebar]의 컴팩트 nav 블록에서 바로 열린다 — 여긴 자주 안 쓰는 항목
/// (테마·계정 전환·데이터 삭제)과 잠금 없는 개발자 도구, 그리고 상단 프로필
/// 헤더를 통한 레벨/언어 편집 진입점만 남는다. 사이드바 하단 프로필 행을
/// 탭하면 곧장 이 화면으로 들어온다 (탭 하나 = 목적지 하나, Gemini의 계정
/// 행과 동일한 패턴).
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

  Future<void> _confirmDeleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('account.deleteData')),
        content: Text(tr('account.deleteConfirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('account.deleteData')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await accountController.deleteCurrentServerSide();
      // current=null makes the app root show the entry screen; pop to it.
      if (mounted) nav.popUntil((r) => r.isFirst);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('계정 · 설정')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH, AppSpacing.pageV, AppSpacing.pageH, AppSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileHeader(onTap: () => _open(const SettingsScreen())),
            const SizedBox(height: AppSpacing.md),
            const _ThemeModeTile(),
            const SizedBox(height: AppSpacing.xl),

            AppSectionHeader(title: tr('account.switch'), subtitle: accountController.current ?? ''),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.switch_account_rounded,
              title: tr('account.switch'),
              subtitle: accountController.current ?? '',
              color: AppColors.hubGraph,
              onTap: () async {
                final nav = Navigator.of(context);
                await accountController.signOut();
                if (mounted) nav.popUntil((r) => r.isFirst);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.delete_forever_rounded,
              title: tr('account.deleteData'),
              subtitle: '',
              color: Colors.red,
              onTap: _confirmDeleteAccount,
            ),
            const SizedBox(height: AppSpacing.xl),

            // 설정 진입점은 상단 프로필 헤더가 겸한다(중복 타일 제거).
            // ── 개발자 도구 (접힘, 잠금 없음) ─────────────────────────────
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () =>
                    setState(() => _devToolsExpanded = !_devToolsExpanded),
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
                        _devToolsExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: AppColors.textMuted,
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
                subtitle: '일기 기반 작문 문제 만들기 · 대기 큐 관리',
                color: AppColors.hubQuiz,
                onTap: () => _open(const QuizGenerationScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.account_tree_outlined,
                title: '파이프라인',
                subtitle: '음성·텍스트 기록별 처리 trace · GraphRAG 단계',
                color: AppColors.hubVoice,
                onTap: () => _open(const PipelineDebugHubScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.quiz_outlined,
                title: 'Quiz Path',
                subtitle: '지식 그래프 · Quiz Path trace',
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
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.groups_outlined,
                title: '계정 개요',
                subtitle: '서버의 전체 계정 · 대략적인 DB 사용량',
                color: AppColors.hubGraph,
                onTap: () => _open(const AccountsOverviewScreen()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 일반/야간 모드 전환 — 그래프 화면 상단을 비우기 위해 메뉴로 이전.
/// [AppHubTile]과 같은 표면·라운딩을 쓰되, 탐색이 아닌 즉시 토글이라
/// 트레일링 [Switch]로 상태를 바로 보여준다.
class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: appThemeController,
      builder: (context, _) {
        final dark = appThemeController.isDark;
        return Material(
          color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: appThemeController.toggle,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.hubGraph.withValues(alpha: 0.18),
                          AppColors.hubGraph.withValues(alpha: 0.08),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        dark
                            ? Icons.dark_mode_rounded
                            : Icons.light_mode_rounded,
                        key: ValueKey(dark),
                        color: AppColors.hubGraph,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('화면 모드',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(dark ? '야간 모드' : '일반 모드',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                  Switch(
                    value: dark,
                    onChanged: (_) => appThemeController.toggle(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
