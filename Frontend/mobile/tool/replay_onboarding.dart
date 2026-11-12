// Device-review entry point. Normal builds continue to use lib/main.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile/app/app.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/main.dart' as production;
import 'package:mobile/shared/widgets/app_error_fallback.dart';

void main() {
  // This explicit development-review target always previews real splash
  // followed by onboarding, without reading or changing a family's data.
  // Normal lib/main.dart builds and every release use real startup state.
  if (kReleaseMode) {
    production.main();
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (_) => const AppErrorFallback();
  try {
    AppConfig.validateApiBaseUri();
    runApp(
      const KingdomKidsApp(
        splashDestinationResolver: _OnboardingReviewDestinationResolver(),
      ),
    );
  } on AppConfigurationException {
    runApp(const MaterialApp(home: AppErrorFallback()));
  }
}

class _OnboardingReviewDestinationResolver implements SplashDestinationResolver {
  const _OnboardingReviewDestinationResolver();

  @override
  Future<StartupDestination> resolve() async =>
      const StartupDestination(AppRoutes.onboarding);
}
