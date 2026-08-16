/// RITMA app theme — WHOOP structure reinterpreted as a clean light system.
///
/// White/near-white surfaces, near-black primary text, gray secondary text,
/// hairline dividers, RITMA green accent. No purple-primary branding.
/// Dark mode stays functional via the same green seed (charcoal surfaces).
library;

import 'package:flutter/material.dart';

abstract final class AppTheme {
  /// RITMA brand identity:
  /// - brandGreen  #2E9E6B — brand/selected/CTA (authoritative green:
  ///   no pre-existing green existed in the project; introduced as the
  ///   RITMA brand accent, harmonized with the Noana blue #2EA3F2).
  /// - brandOrange #F47421 — legacy secondary CTA (kept as secondary).
  /// - brandBlue   #2EA3F2 — informational accent.
  /// - brandPurple #713795 — legacy identity; demoted, no longer primary.
  static const Color brandGreen = Color(0xFF2E9E6B);
  static const Color brandGreenSoft = Color(0xFFE4F4EC);
  static const Color brandOrange = Color(0xFFF47421);
  static const Color brandBlue = Color(0xFF2EA3F2);
  static const Color brandPurple = Color(0xFF713795);

  static ColorScheme _scheme(Brightness brightness) {
    final light = brightness == Brightness.light;
    final base = ColorScheme.fromSeed(
      seedColor: brandGreen,
      brightness: brightness,
    );
    return base.copyWith(
      // Surfaces: white / near-white in light; charcoal in dark.
      surface: light ? const Color(0xFFFFFFFF) : base.surface,
      surfaceContainerLowest:
          light ? const Color(0xFFFFFFFF) : base.surfaceContainerLowest,
      surfaceContainerLow:
          light ? const Color(0xFFFAFAFA) : base.surfaceContainerLow,
      surfaceContainer:
          light ? const Color(0xFFF5F5F5) : base.surfaceContainer,
      surfaceContainerHigh:
          light ? const Color(0xFFF0F0F0) : base.surfaceContainerHigh,
      // RITMA green primary + soft mint container.
      primary: light ? brandGreen : base.primary,
      onPrimary: light ? Colors.white : base.onPrimary,
      primaryContainer:
          light ? brandGreenSoft : base.primaryContainer,
      onPrimaryContainer:
          light ? const Color(0xFF0B3D27) : base.onPrimaryContainer,
      // Legacy orange stays secondary (site CTA), blue stays tertiary.
      secondary: light ? brandOrange : base.secondary,
      onSecondary: light ? const Color(0xFF331400) : base.onSecondary,
      secondaryContainer:
          light ? const Color(0xFFFFE1CC) : base.secondaryContainer,
      onSecondaryContainer:
          light ? const Color(0xFF331400) : base.onSecondaryContainer,
      tertiary: brandBlue,
      onTertiary: light ? const Color(0xFF00263F) : base.onTertiary,
      tertiaryContainer:
          light ? const Color(0xFFD3E9FF) : base.tertiaryContainer,
      onTertiaryContainer:
          light ? const Color(0xFF00263F) : base.onTertiaryContainer,
      outlineVariant:
          light ? const Color(0xFFE3E3E3) : base.outlineVariant,
    );
  }

  static ThemeData light() => _build(_scheme(Brightness.light));

  static ThemeData dark() => _build(_scheme(Brightness.dark));

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
    );
    final hairline = scheme.outlineVariant.withValues(alpha: 0.7);
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      // Hairline dividers everywhere.
      dividerTheme: DividerThemeData(
        color: hairline,
        thickness: 0.5,
        space: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: hairline),
        ),
      ),
      // Compact tab strip: thin RITMA-green underline, strong selected text.
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: base.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: base.textTheme.titleSmall,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        overlayColor: WidgetStatePropertyAll(
          scheme.primary.withValues(alpha: 0.06),
        ),
      ),
      // Primary CTA = RITMA green (was orange).
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: base.textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        textColor: scheme.onSurface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primary.withValues(alpha: 0.15),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStatePropertyAll(
          base.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
