import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme_controller.dart';

/// Top-right light / dark mode switch for the graph home shell.
class AppThemeToggleButton extends StatelessWidget {
  const AppThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appThemeController,
      builder: (context, _) {
        final dark = appThemeController.isDark;
        return IconButton(
          tooltip: dark ? tr('theme.lightModeTooltip') : tr('theme.darkModeTooltip'),
          onPressed: appThemeController.toggle,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Icon(
              dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              key: ValueKey(dark),
            ),
          ),
        );
      },
    );
  }
}
