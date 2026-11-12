import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'shared/widgets/app_error_fallback.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (_) => const AppErrorFallback();
  try {
    AppConfig.validateApiBaseUri();
    runApp(const KingdomKidsApp());
  } on AppConfigurationException {
    // A release build with a missing/cleartext API endpoint must fail closed
    // without showing technical details or attempting an insecure request.
    runApp(const MaterialApp(home: AppErrorFallback()));
  }
}
