import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// MyLife English — polished mobile-first design tokens.
class AppColors {
  static const primary = Color(0xFF5B5FEF);
  static const primaryDark = Color(0xFF4347D4);
  static const accent = Color(0xFF14B8A6);
  static const accentWarm = Color(0xFFF59E0B);
  static const surfaceLight = Color(0xFFF8F9FC);
  static const surfaceCard = Color(0xFFFFFFFF);
  static const textMuted = Color(0xFF64748B);
  static const graphBg = Color(0xFFF5F7FA);
  static const graphBgDark = Color(0xFF08080C);
  static const graphSurface = Color(0xFFFFFFFF);
  static const graphLabelLight = Color(0xFFF0F0F5);

  static const hubVoice = Color(0xFF0D9488);
  static const hubQuiz = Color(0xFF7C3AED);
  static const hubGraph = Color(0xFF4F46E5);
  static const hubRecord = Color(0xFFEF4444);
}

class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const pageH = 20.0;
  static const pageV = 16.0;
  static const radiusSm = 10.0;
  static const radiusMd = 14.0;
  static const radiusLg = 18.0;
  static const radiusXl = 22.0;
}

ThemeData buildAppTheme({Brightness brightness = Brightness.light}) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: brightness,
    primary: AppColors.primary,
    secondary: AppColors.accent,
    surface: isDark ? const Color(0xFF12151C) : AppColors.surfaceLight,
  );

  final textTheme = TextTheme(
    headlineMedium: TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: scheme.onSurface,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: scheme.onSurface,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      height: 1.45,
      color: scheme.onSurface,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      height: 1.4,
      color: scheme.onSurface,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      height: 1.35,
      color: AppColors.textMuted,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: textTheme.titleMedium?.copyWith(fontSize: 17),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? scheme.surfaceContainerHigh : AppColors.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.25 : 0.5),
        ),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      thickness: 1,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.primaryContainer.withValues(alpha: 0.4),
    ),
  );
}
