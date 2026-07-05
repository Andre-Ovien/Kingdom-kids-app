import 'package:flutter/material.dart';

class AppThemeController {
  const AppThemeController._();

  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.light);

  static bool get darkModeEnabled => mode.value == ThemeMode.dark;

  static void setDarkMode(bool enabled) {
    mode.value = enabled ? ThemeMode.dark : ThemeMode.light;
  }
}
