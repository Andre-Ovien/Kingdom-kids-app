import 'package:flutter/material.dart';

import '../core/constants/app_constants.dart';
import 'router.dart';
import 'theme.dart';
import 'theme_controller.dart';

class KingdomKidsApp extends StatelessWidget {
  const KingdomKidsApp({super.key, this.initialRoute = AppRoutes.onboarding});

  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppThemeController.mode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          theme: buildKingdomKidsTheme(),
          darkTheme: buildKingdomKidsTheme(brightness: Brightness.dark),
          themeMode: themeMode,
          initialRoute: initialRoute,
          onGenerateRoute: AppRouter.onGenerateRoute,
        );
      },
    );
  }
}
