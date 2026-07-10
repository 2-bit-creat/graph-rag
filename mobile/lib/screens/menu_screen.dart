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

/// Consolidated "?Â”Ã«Â³Â´ÃªÂ¸? menu. Everything the app can do that isn't the chat home
/// lives here in one place: user tools grouped by purpose, plus a collapsed
/// developer section (Ã«Â¬Â¸Ã¬Â Âœ ?ÂÃ¬Â„Â±Ã‚Â·?ÂŒÃ¬ÂÂ´?Â„Ã«ÂÂ¼???Â”Ã«Â²Â„ÃªÂ·? that isn't locked ??just tucked away.
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
      appBar: AppBar(title: const Text('Ã«Â©Â”Ã«Â‰Â´')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH, AppSpacing.pageV, AppSpacing.pageH, AppSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileHeader(onTap: () => _open(const SettingsScreen())),
            const SizedBox(height: AppSpacing.xl),

            // ?Â€?Â€ ??ÃªÂ¸Â°Ã«Â¡Â ?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€
            const AppSectionHeader(title: '??ÃªÂ¸Â°Ã«Â¡Â', subtitle: '?Â¼ÃªÂ¸Â° Ã‚Â· ?ÂµÃªÂ³Â„'),
            const SizedBox(height: AppSpacing.md),
            AppHubTile(
              icon: Icons.auto_stories_outlined,
              title: '???Â¼ÃªÂ¸Â°',
              subtitle: 'Ã«Â²ÂˆÃ¬Â—Â­ Ã‚Â· ?Â”Ã¬ÂžÂ ?Â•Ã¬ÂÂ¸ Ã‚Â· Ã¬Â§Â€?ÂÃªÂ·Â¸?Â˜Ã­Â”Â„ ?Â´Ã«ÂÂ™',
              color: AppColors.accent,
              onTap: () => _open(const JournalHubScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.bar_chart_rounded,
              title: '?ÂŒÃ¬Â•Â„Ã«Â³Â´ÃªÂ¸Â°',
              subtitle: '?Â±Ã¬ÂžÂ¥ ?ÂµÃªÂ³Â„ & ?ÂœÃ«ÂÂ™ ?Â„Ã­Â™Â©',
              color: AppColors.hubVoice,
              onTap: () => _open(
                Scaffold(
                  appBar: AppBar(title: const Text('?ÂŒÃ¬Â•Â„Ã«Â³Â´ÃªÂ¸Â°')),
                  body: const KgInsightScreen(),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // ?Â€?Â€ ?Â™Ã¬ÂŠÂµ ?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€
            const AppSectionHeader(title: '?Â™Ã¬ÂŠÂµ', subtitle: '?ÂœÃ­Â˜Â„ Ã‚Â· ?Â¨Ã¬Â–Â´??Ã‚Â· Ã«Â³ÂµÃ¬ÂŠÂµ ??),
            const SizedBox(height: AppSpacing.md),
            AppHubTile(
              icon: Icons.style_rounded,
              title: '?ÂœÃ­Â„Â°?Â€ Ã«Â°Â°Ã¬ÂšÂ´ ?ÂœÃ­Â˜Â„',
              subtitle: '?Â·ÃªÂ°Âˆ?Â¸Ã«ÂÂ˜ ?ÂœÃ­Â˜Â„ Ã«ÂªÂ¨Ã¬ÂÂŒ Ã‚Â· Ã«Â³ÂµÃ¬ÂŠÂµ Ã¬Â¶ÂœÃ¬Â Âœ ?Â¬Ã«Â£ÂŒ',
              color: AppColors.accentWarm,
              onTap: () => _open(const TutorVocabScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.menu_book_rounded,
              title: '?Â¨Ã¬Â–Â´??Ã‚Â· ?ÂœÃ­Â˜Â„ ?Â€??,
              subtitle: '???Â¨Ã¬Â–Â´??Ã‚Â· ÃªÂ·Â¸Ã«ÂžÂ˜?Â„Ã¬Â—Â??Ã¬Â¶Â”Ã¬Â¶Âœ???ÂœÃ­Â˜Â„',
              color: AppColors.accent,
              onTap: () => _open(const VocabularyHubScreen()),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppHubTile(
              icon: Icons.playlist_add_check_rounded,
              title: '?Â´Ã¬Â¦Âˆ ??,
              subtitle: '?Â€ÃªÂ¸?Ã‚Â· Ã«Â³ÂµÃ¬ÂŠÂµ ?ÂˆÃ¬Â Â• Ã«Â¬Â¸Ã¬Â Âœ ÃªÂ´Â€Ã«Â¦?,
              color: AppColors.hubQuiz,
              onTap: () => _open(const QuizQueueScreen()),
            ),
            const SizedBox(height: AppSpacing.xl),

            // ?Â¤Ã¬Â Â• Ã¬Â§Â„Ã¬ÂžÂ…?ÂÃ¬? ?ÂÃ«Â‹Â¨ ?Â„Ã«Â¡Âœ???Â¤Ã«ÂÂ”ÃªÂ°Â€ ÃªÂ²Â¸Ã­Â•Âœ??Ã¬Â¤Â‘Ã«Â³Âµ ?Â€???ÂœÃªÂ±Â°).
            // ?Â€?Â€ ÃªÂ°ÂœÃ«Â°Âœ???Â„ÃªÂµÂ¬ (?Â‘Ã­ÂžÂ˜, ?Â ÃªÂ¸Âˆ ?Â†Ã¬ÂÂŒ) ?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€?Â€
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
                          title: 'ÃªÂ°ÂœÃ«Â°Âœ???Â„ÃªÂµÂ¬',
                          subtitle: 'Ã«Â¬Â¸Ã¬Â Âœ ?ÂÃ¬Â„Â± Ã‚Â· ?ÂŒÃ¬ÂÂ´?Â„Ã«ÂÂ¼???Â”Ã«Â²Â„ÃªÂ·?,
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
                title: 'Ã«Â¬Â¸Ã¬Â Âœ ?ÂÃ¬Â„Â±',
                subtitle: '?Â¼ÃªÂ¸Â° ÃªÂ¸Â°Ã«Â°Â˜ ?Â‘Ã«Â¬Â¸ Ã«Â¬Â¸Ã¬Â Âœ Ã«Â§ÂŒÃ«Â“Â¤ÃªÂ¸?Ã‚Â· ?Â€ÃªÂ¸???ÃªÂ´Â€Ã«Â¦?,
                color: AppColors.hubQuiz,
                onTap: () => _open(const QuizGenerationScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.account_tree_outlined,
                title: '?ÂŒÃ¬ÂÂ´?Â„Ã«ÂÂ¼??,
                subtitle: '?ÂŒÃ¬Â„Â±Ã‚Â·?ÂÃ¬ÂŠÂ¤??ÃªÂ¸Â°Ã«Â¡ÂÃ«Â³?Ã¬Â²Â˜Ã«Â¦Â¬ trace Ã‚Â· GraphRAG ?Â¨ÃªÂ³Â„',
                color: AppColors.hubVoice,
                onTap: () => _open(const PipelineDebugHubScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.quiz_outlined,
                title: 'Quiz Path',
                subtitle: 'Ã¬Â§Â€??ÃªÂ·Â¸Ã«ÂžÂ˜??Ã‚Â· Quiz Path trace',
                color: AppColors.hubQuiz,
                onTap: () => _open(const QuizPipelineHubScreen()),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppHubTile(
                icon: Icons.bug_report_outlined,
                title: 'KG ?Â”Ã«Â²Â„ÃªÂ·?,
                subtitle: 'KG ?ÂŒÃ¬ÂÂ´?Â„Ã«ÂÂ¼???Â¤Ã­Â–Â‰ ÃªÂ¸Â°Ã«Â¡Â',
                color: AppColors.hubVoice,
                onTap: () => _open(
                  Scaffold(
                    appBar: AppBar(title: const Text('KG ?ÂŒÃ¬ÂÂ´?Â„Ã«ÂÂ¼???Â”Ã«Â²Â„ÃªÂ·?)),
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
                  Text('???Â„Ã«Â¡Âœ??,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('?ÂˆÃ«Â²Â¨ Ã‚Â· Ã«ÂªÂ©Ã­Â‘Âœ ?Â¸Ã¬Â–Â´ Ã‚Â· ?Â™Ã¬ÂŠÂµ Ã«ÂªÂ©Ã¬Â Â ?Â¤Ã¬Â Â•',
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
