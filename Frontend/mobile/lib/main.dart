import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppThemeController.initialize();
  runApp(const KingdomKidsApp());
}
