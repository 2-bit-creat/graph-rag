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

/// Consolidated "?ë³´ê¸? menu. Everything the app can do that isn't the chat home
/// lives here in one place: user tools grouped by purpose, plus a collapsed
/// developer section (ë¬¸ì  ?ì±Â·?ì´?ë¼???ë²ê·? that isn't locked ??just tucked away.
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
      appBar: AppBar(title: const Text('ë©ë´')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH, AppSpacing.pageV, AppSpacing.pageH, AppSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileHeader(onTap: () => _open(const SettingsScreen())),
            const SizedBox(height: AppSpacing.xl),

            // ?? ??ê¸°ë¡ ????????????????????????????????????????????????????
            const AppSectionHeader(title: '??ê¸°ë¡', subtitle: '?¼ê¸° Â· ?µê³'),
            const SizedBox(height: AppSpacing.md),
            AppHubTile(
              icon: Icons.auto_stories_outlined,
              title: '???¼ê¸°',
              subtitle: 'ë²ì­ Â· ?ì ?ì¸ Â· ì§?ê·¸?í ?´ë',
              color: AppColors.accent,
              onTap: () => _open(const JournalHubScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.bar_chart_rounded,
              title: '?ìë³´ê¸°',
              subtitle: '?±ì¥ ?µê³ & ?ë ?í©',
              color: AppColors.hubVoice,
              onTap: () => _open(
                Scaffold(
                  appBar: AppBar(title: const Text('?ìë³´ê¸°')),
                  body: const KgInsightScreen(),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // ?? ?ìµ ??????????????????????????????????????????????????????
            const AppSectionHeader(title: '?ìµ', subtitle: '?í Â· ?¨ì´??Â· ë³µìµ ??),
            const SizedBox(height: AppSpacing.md),
            AppHubTile(
              icon: Icons.style_rounded,
              title: '?í°? ë°°ì´ ?í',
              subtitle: '?·ê°?¸ë ?í ëª¨ì Â· ë³µìµ ì¶ì  ?¬ë£',
              color: AppColors.accentWarm,
              onTap: () => _open(const TutorVocabScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.menu_book_rounded,
              title: '?¨ì´??Â· ?í ???,
              subtitle: '???¨ì´??Â· ê·¸ë?ì??ì¶ì¶???í',
              color: AppColors.accent,
              onTap: () => _open(const VocabularyHubScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.playlist_add_check_rounded,
              title: '?´ì¦ ??,
              subtitle: '?ê¸?Â· ë³µìµ ?ì  ë¬¸ì  ê´ë¦?,
              color: AppColors.hubQuiz,
              onTap: () => _open(const QuizQueueScreen()),
            ),
            const SizedBox(height: AppSpacing.xl),

            // ?¤ì  ì§ì?ì? ?ë¨ ?ë¡???¤ëê° ê²¸í??ì¤ë³µ ????ê±°).
            // ?? ê°ë°???êµ¬ (?í, ? ê¸ ?ì) ?????????????????????????????
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
                          title: 'ê°ë°???êµ¬',
                          subtitle: 'ë¬¸ì  ?ì± Â· ?ì´?ë¼???ë²ê·?,
                        ),
                      ),
                      Icon(
                        _devToolsExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
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
                title: 'ë¬¸ì  ?ì±',
                subtitle: '?¼ê¸° ê¸°ë° ?ë¬¸ ë¬¸ì  ë§ë¤ê¸?Â· ?ê¸???ê´ë¦?,
                color: AppColors.hubQuiz,
                onTap: () => _open(const QuizGenerationScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.account_tree_outlined,
                title: '?ì´?ë¼??,
                subtitle: '?ì±Â·?ì¤??ê¸°ë¡ë³?ì²ë¦¬ trace Â· GraphRAG ?¨ê³',
                color: AppColors.hubVoice,
                onTap: () => _open(const PipelineDebugHubScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.quiz_outlined,
                title: 'Quiz Path',
                subtitle: 'ì§??ê·¸ë??Â· Quiz Path trace',
                color: AppColors.hubQuiz,
                onTap: () => _open(const QuizPipelineHubScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.bug_report_outlined,
                title: 'KG ?ë²ê·?,
                subtitle: 'KG ?ì´?ë¼???¤í ê¸°ë¡',
                color: AppColors.hubVoice,
                onTap: () => _open(
                  Scaffold(
                    appBar: AppBar(title: const Text('KG ?ì´?ë¼???ë²ê·?)),
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
                  Text('???ë¡??,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('?ë²¨ Â· ëª©í ?¸ì´ Â· ?ìµ ëª©ì  ?¤ì ',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.mutedText)),
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
