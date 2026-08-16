/// App theme (spec §60 core/theme).
library;

import 'package:flutter/material.dart';

/// Noana brand identity (from noana.com.br, verified 2026-08-16):
/// - primary purple  #713795 — logo wordmark + headers (dominant brand color)
/// - accent orange   #F47421 — CTA buttons / highlights
/// - accent blue     #2EA3F2 — informational accents
/// - lavender tints  #8D7BB8 / #D2CFFC — soft purple surfaces
abstract final class AppTheme {
  static const Color brandPurple = Color(0xFF713795);
  static const Color brandOrange = Color(0xFFF47421);
  static const Color brandBlue = Color(0xFF2EA3F2);
  static const Color brandLavender = Color(0xFFD2CFFC);

  static ColorScheme _scheme(Brightness brightness) {
    // Purple seed generates the full tonal M3 scheme (surfaces/containers come
    // out lavender-toned, matching the site's #8D7BB8/#D2CFFC tints), then the
    // brand orange/blue are pinned explicitly so they survive tone derivation.
    final base = ColorScheme.fromSeed(
      seedColor: brandPurple,
      brightness: brightness,
    );
    final light = brightness == Brightness.light;
    return base.copyWith(
      secondary: brandOrange,
      onSecondary: const Color(0xFF331400), // dark text on orange (AA)
      secondaryContainer:
          light ? const Color(0xFFFFE1CC) : const Color(0xFF5A2B00),
      onSecondaryContainer:
          light ? const Color(0xFF331400) : const Color(0xFFFFDCC1),
      tertiary: brandBlue,
      onTertiary: const Color(0xFF00263F),
      tertiaryContainer:
          light ? const Color(0xFFD3E9FF) : const Color(0xFF003A5C),
      onTertiaryContainer:
          light ? const Color(0xFF00263F) : const Color(0xFFCFE8FF),
    );
  }

  static ThemeData light() => _build(_scheme(Brightness.light));

  static ThemeData dark() => _build(_scheme(Brightness.dark));

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
    );
    return base.copyWith(
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.primary, // brand purple title/back arrow
        elevation: 0,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      // Brand-colored icons everywhere (site iconography is purple-dominant).
      iconTheme: IconThemeData(color: scheme.primary),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        color: scheme.surfaceContainerLow,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 0.5,
        space: 1,
      ),
      // Compact WHOOP-like tab bar: thin purple underline, muted unselected.
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: base.textTheme.labelLarge,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        overlayColor: WidgetStatePropertyAll(
          scheme.primary.withValues(alpha: 0.08),
        ),
      ),
      // Primary CTA = brand orange, like the site's buy/assine buttons.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.secondary,
          foregroundColor: scheme.onSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
