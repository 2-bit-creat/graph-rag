import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 기억 그래프 — polished mobile-first design tokens.
class AppColors {
  static const primary = Color(0xFF5B5FEF);
  static const primaryDark = Color(0xFF4347D4);
  static const accent = Color(0xFF14B8A6);
  static const accentWarm = Color(0xFFF59E0B);
  static const surfaceLight = Color(0xFFF8F9FC);
  static const surfaceCard = Color(0xFFFFFFFF);
  /// Light-mode fallback only — prefer [BuildContext.mutedText] in widgets.
  static const textMuted = Color(0xFF64748B);
  static const textMutedDark = Color(0xFFC4CEDE);
  static const graphBg = Color(0xFFF5F7FA);
  static const graphBgDark = Color(0xFF08080C);
  static const graphSurface = Color(0xFFFFFFFF);
  static const graphLabelLight = Color(0xFFF0F0F5);
  static const graphLabelDark = Color(0xFF1E293B);

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

/// Theme-aware text colors — use instead of hardcoded [AppColors.textMuted].
extension AppThemeContext on BuildContext {
  bool get isDarkTheme => Theme.of(this).brightness == Brightness.dark;

  Color get mutedText => Theme.of(this).colorScheme.onSurfaceVariant;

  Color get subtleText =>
      Theme.of(this).colorScheme.onSurface.withValues(alpha: isDarkTheme ? 0.62 : 0.55);

  /// Chat / graph panel chrome derived from the active [ThemeData].
  AppShellTheme get shell => AppShellTheme(this);
}

/// Shared colors for chat sidebar, graph panels, and compose bars.
class AppShellTheme {
  AppShellTheme(this._context);

  final BuildContext _context;

  bool get _isDark => Theme.of(_context).brightness == Brightness.dark;
  ColorScheme get _scheme => Theme.of(_context).colorScheme;

  Color get primaryText => _scheme.onSurface;

  Color get mutedText => _scheme.onSurfaceVariant;

  Color get panelBackground =>
      _isDark ? const Color(0xFF151820) : AppColors.surfaceCard;

  Color get panelBorder =>
      _scheme.outlineVariant.withValues(alpha: _isDark ? 0.45 : 0.55);

  Color get subtleSurface => _scheme.surfaceContainerHighest.withValues(
        alpha: _isDark ? 0.55 : 0.45,
      );

  Color get barBackground =>
      _isDark ? const Color(0xFF12151C) : AppColors.surfaceLight;

  Color get graphBackground =>
      _isDark ? AppColors.graphBgDark : AppColors.graphBg;

  Color get toolbarBackground =>
      _isDark ? const Color(0xFF101018) : const Color(0xFFEEF1F7);

  Color get graphLabel =>
      _isDark ? AppColors.graphLabelLight : AppColors.graphLabelDark;

  Color get graphInputFill =>
      _isDark ? const Color(0xFF1A1A22) : const Color(0xFFFFFFFF);

  Color get graphBorder =>
      _isDark ? const Color(0xFF2D2D38) : const Color(0xFFD8DEE9);

  Color get graphMuted =>
      _isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B);
}

ThemeData buildAppTheme({Brightness brightness = Brightness.light}) {
  final isDark = brightness == Brightness.dark;
  final baseScheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: brightness,
    primary: AppColors.primary,
    secondary: AppColors.accent,
    surface: isDark ? const Color(0xFF12151C) : AppColors.surfaceLight,
  );
  final scheme = baseScheme.copyWith(
    onSurfaceVariant: isDark ? AppColors.textMutedDark : AppColors.textMuted,
    onPrimaryContainer: isDark ? const Color(0xFFE8EAFF) : const Color(0xFF1E1B4B),
    primaryContainer: isDark ? const Color(0xFF3A3D72) : baseScheme.primaryContainer,
    outlineVariant: isDark ? const Color(0xFF3A4254) : const Color(0xFFD8DEE9),
  );

  final chipLabelUnselected = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: isDark ? AppColors.textMutedDark : scheme.onSurfaceVariant,
  );
  final chipLabelSelected = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: isDark ? const Color(0xFFEEF2FF) : scheme.onPrimaryContainer,
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
      color: scheme.onSurfaceVariant,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: scheme.onSurface,
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
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.55 : 0.45),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.85)),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.45 : 0.35),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
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
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      labelStyle: chipLabelUnselected,
      secondaryLabelStyle: chipLabelSelected,
      side: BorderSide(
        color: scheme.outlineVariant.withValues(alpha: isDark ? 0.55 : 0.75),
      ),
      backgroundColor:
          isDark ? scheme.surfaceContainerHighest : scheme.surfaceContainerLow,
      selectedColor: isDark
          ? scheme.primary.withValues(alpha: 0.38)
          : scheme.primaryContainer.withValues(alpha: 0.88),
      disabledColor: scheme.onSurface.withValues(alpha: 0.08),
      checkmarkColor: isDark ? const Color(0xFFEEF2FF) : scheme.primary,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: isDark ? 0.22 : 0.15),
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.12),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.primaryContainer.withValues(alpha: 0.4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? const Color(0xFF1A1F2B) : AppColors.surfaceCard,
      titleTextStyle: textTheme.titleMedium,
      contentTextStyle: textTheme.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? const Color(0xFF1A1F2B) : AppColors.surfaceCard,
      modalBackgroundColor: isDark ? const Color(0xFF1A1F2B) : AppColors.surfaceCard,
    ),
  );
}
