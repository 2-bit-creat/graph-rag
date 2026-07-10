import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Consistent page padding.
class AppPage extends StatelessWidget {
  const AppPage({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ??
          const EdgeInsets.fromLTRB(
            AppSpacing.pageH,
            AppSpacing.pageV,
            AppSpacing.pageH,
            AppSpacing.xxl,
          ),
      child: child,
    );
  }
}

class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              if (subtitle != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class AppHeroHeader extends StatelessWidget {
  const AppHeroHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.mutedText,
            )),
      ],
    );
  }
}

class AppHubTile extends StatelessWidget {
  const AppHubTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                      color.withValues(alpha: 0.18),
                      color.withValues(alpha: 0.08),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (badge != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Icon(Icons.arrow_forward_ios_rounded,
                  size: 14, color: scheme.onSurface.withValues(alpha: 0.35)),
            ],
          ),
        ),
      ),
    );
  }
}

class AppPrimaryBanner extends StatelessWidget {
  const AppPrimaryBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onTap,
    this.color,
    this.actionIcon,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onTap;
  final Color? color;
  final IconData? actionIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? AppColors.hubRecord;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.14),
            scheme.primary.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: accent, size: 26),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                FilledButton.tonal(
                  onPressed: onTap,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent.withValues(alpha: 0.18),
                    foregroundColor: accent,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(actionIcon ?? Icons.arrow_forward_rounded, size: 16, color: accent),
                      const SizedBox(width: 4),
                      Text(actionLabel),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppSurfaceCard extends StatelessWidget {
  const AppSurfaceCard({
    super.key,
    required this.child,
    this.padding,
    this.color,
    this.tint,
  });

  final Widget child;
  final EdgeInsets? padding;
  final Color? color;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = color ?? scheme.surfaceContainerLow.withValues(alpha: 0.65);
    final borderColor = (tint ?? scheme.outlineVariant).withValues(alpha: 0.35);
    return Material(
      color: bg,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
        child: child,
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: scheme.primary),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: AppSpacing.lg),
            action!,
          ],
        ],
      ),
    );
  }
}

class AppHubAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppHubAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
  });

  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  @override
  Size get preferredSize => Size.fromHeight(subtitle != null ? 56 : 48);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: preferredSize.height,
      actions: actions,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title),
          if (subtitle != null)
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class AppLoadingScreen extends StatelessWidget {
  const AppLoadingScreen({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(message!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class AppPhaseStepper extends StatelessWidget {
  const AppPhaseStepper({
    super.key,
    required this.phases,
    required this.currentIndex,
  });

  final List<String> phases;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < phases.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(bottom: 14),
                color: i <= currentIndex
                    ? scheme.primary.withValues(alpha: 0.5)
                    : scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
          _PhaseDot(
            label: phases[i],
            state: i < currentIndex
                ? _PhaseState.done
                : i == currentIndex
                    ? _PhaseState.active
                    : _PhaseState.pending,
          ),
        ],
      ],
    );
  }
}

enum _PhaseState { done, active, pending }

class _PhaseDot extends StatelessWidget {
  const _PhaseDot({required this.label, required this.state});

  final String label;
  final _PhaseState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color dotColor;
    final Widget icon;
    switch (state) {
      case _PhaseState.done:
        dotColor = AppColors.accent;
        icon = const Icon(Icons.check_rounded, size: 14, color: Colors.white);
      case _PhaseState.active:
        dotColor = scheme.primary;
        icon = SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: scheme.onPrimary,
          ),
        );
      case _PhaseState.pending:
        dotColor = scheme.outlineVariant;
        icon = const SizedBox.shrink();
    }
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
          child: Center(child: icon),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: state == _PhaseState.active ? FontWeight.w600 : FontWeight.w500,
            color: state == _PhaseState.pending
                ? context.mutedText
                : scheme.onSurface,
          ),
        ),
      ],
    );
  }
}
