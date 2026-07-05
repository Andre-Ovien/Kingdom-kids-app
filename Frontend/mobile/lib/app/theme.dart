import 'package:flutter/material.dart';

ThemeData buildKingdomKidsTheme({Brightness brightness = Brightness.light}) {
  const seedColor = Color(0xFF2D7D6F);
  final isDark = brightness == Brightness.dark;
  final surfaceColor = isDark
      ? const Color(0xFF101414)
      : const Color(0xFFFFFCF6);
  final textColor = isDark ? const Color(0xFFF8F3EF) : const Color(0xFF1F2933);
  final cardColor = isDark ? const Color(0xFF171D1C) : Colors.white;

  final colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    surface: surfaceColor,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Avenir Next',
    fontFamilyFallback: const ['SF Pro Display', 'Helvetica Neue'],
    colorScheme: colorScheme,
    scaffoldBackgroundColor: surfaceColor,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: surfaceColor,
      foregroundColor: textColor,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      clipBehavior: Clip.antiAlias,
      color: cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textTheme: TextTheme(
      headlineSmall: TextStyle(color: textColor, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(color: textColor, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(color: textColor, fontWeight: FontWeight.w500),
      bodyMedium: TextStyle(color: textColor),
    ),
  );
}
