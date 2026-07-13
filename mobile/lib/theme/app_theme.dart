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
  static const textMuted = Color(0xFF94A3B8);
  static const graphBg = Color(0xFFF5F7FA);
  static const graphBgDark = Color(0xFF08080C);
  // Subtle radial "nebula" glow at the viewport center of the graph canvas.
  static const graphNebulaCore = Color(0xFF0D0D16);
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

/// Graph-home shell palette — sidebar, app bar, chat panel, canvas chrome.
@immutable
class AppShellTheme extends ThemeExtension<AppShellTheme> {
  const AppShellTheme({
    required this.graphBackground,
    required this.appBarBackground,
    required this.appBarForeground,
    required this.sidebarBackground,
    required this.panelBackground,
    required this.panelBorder,
    required this.primaryText,
    required this.mutedText,
    required this.toolbarBackground,
    required this.toolbarBorder,
    required this.subtleSurface,
    required this.barBackground,
  });

  final Color graphBackground;
  final Color appBarBackground;
  final Color appBarForeground;
  final Color sidebarBackground;
  final Color panelBackground;
  final Color panelBorder;
  final Color primaryText;
  final Color mutedText;
  final Color toolbarBackground;
  final Color toolbarBorder;

  /// Faint filled surface for input fields, inline cards, math blocks — sits a
  /// step off [panelBackground] in both themes.
  final Color subtleSurface;

  /// Slightly recessed bar background (pipeline lock/review strips, mode menus).
  final Color barBackground;

  static const dark = AppShellTheme(
    graphBackground: AppColors.graphBgDark,
    appBarBackground: Color(0xFF101018),
    appBarForeground: AppColors.graphLabelLight,
    sidebarBackground: Color(0xFF12151C),
    panelBackground: Color(0xE6101018),
    panelBorder: Color(0xFF2D2D38),
    primaryText: AppColors.graphLabelLight,
    mutedText: Color(0x8CF0F0F5),
    toolbarBackground: Color(0xFF101018),
    toolbarBorder: Color(0xFF2D2D38),
    subtleSurface: Color(0x14FFFFFF),
    barBackground: Color(0xFF1A1A24),
  );

  static const light = AppShellTheme(
    graphBackground: Color(0xFFEEF1F7),
    appBarBackground: Color(0xFFF8F9FC),
    appBarForeground: AppColors.graphLabelDark,
    sidebarBackground: Color(0xFFF8F9FC),
    panelBackground: Color(0xF5FFFFFF),
    panelBorder: Color(0xFFD8DEE9),
    primaryText: AppColors.graphLabelDark,
    mutedText: AppColors.textMuted,
    toolbarBackground: Color(0xFFF8F9FC),
    toolbarBorder: Color(0xFFD8DEE9),
    subtleSurface: Color(0x0A0F172A),
    barBackground: Color(0xFFEEF1F7),
  );

  @override
  AppShellTheme copyWith({
    Color? graphBackground,
    Color? appBarBackground,
    Color? appBarForeground,
    Color? sidebarBackground,
    Color? panelBackground,
    Color? panelBorder,
    Color? primaryText,
    Color? mutedText,
    Color? toolbarBackground,
    Color? toolbarBorder,
    Color? subtleSurface,
    Color? barBackground,
  }) {
    return AppShellTheme(
      graphBackground: graphBackground ?? this.graphBackground,
      appBarBackground: appBarBackground ?? this.appBarBackground,
      appBarForeground: appBarForeground ?? this.appBarForeground,
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      panelBackground: panelBackground ?? this.panelBackground,
      panelBorder: panelBorder ?? this.panelBorder,
      primaryText: primaryText ?? this.primaryText,
      mutedText: mutedText ?? this.mutedText,
      toolbarBackground: toolbarBackground ?? this.toolbarBackground,
      toolbarBorder: toolbarBorder ?? this.toolbarBorder,
      subtleSurface: subtleSurface ?? this.subtleSurface,
      barBackground: barBackground ?? this.barBackground,
    );
  }

  @override
  AppShellTheme lerp(ThemeExtension<AppShellTheme>? other, double t) {
    if (other is! AppShellTheme) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppShellTheme(
      graphBackground: l(graphBackground, other.graphBackground),
      appBarBackground: l(appBarBackground, other.appBarBackground),
      appBarForeground: l(appBarForeground, other.appBarForeground),
      sidebarBackground: l(sidebarBackground, other.sidebarBackground),
      panelBackground: l(panelBackground, other.panelBackground),
      panelBorder: l(panelBorder, other.panelBorder),
      primaryText: l(primaryText, other.primaryText),
      mutedText: l(mutedText, other.mutedText),
      toolbarBackground: l(toolbarBackground, other.toolbarBackground),
      toolbarBorder: l(toolbarBorder, other.toolbarBorder),
      subtleSurface: l(subtleSurface, other.subtleSurface),
      barBackground: l(barBackground, other.barBackground),
    );
  }
}

extension AppShellThemeX on BuildContext {
  AppShellTheme get shell =>
      Theme.of(this).extension<AppShellTheme>() ?? AppShellTheme.dark;

  // Shorthand tokens — several widgets read these directly off the context.
  Color get mutedText => shell.mutedText;
  Color get subtleText => shell.mutedText;
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

  final shell = isDark ? AppShellTheme.dark : AppShellTheme.light;

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
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.6 : 0.5),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.primaryContainer.withValues(alpha: 0.4),
    ),
    extensions: [shell],
  );
}
