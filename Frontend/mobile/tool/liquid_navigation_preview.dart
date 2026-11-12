// Local iOS Simulator harness. No session, backend, or physical-phone access.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/shared/widgets/floating_liquid_nav.dart';
import 'package:mobile/shared/widgets/liquid_navigation_controller.dart';
import 'package:mobile/shared/widgets/persistent_liquid_navigation_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _PreviewApp());
}

const _profile = KidProfile(
  id: 'local-preview',
  parentId: 'local-preview-parent',
  displayName: 'Explorer',
  avatarKey: 'lion',
);

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  static const _steps = ['/', '/stories', '/games', '/profile', '/games', '/'];
  final _navigator = GlobalKey<NavigatorState>();
  late final LiquidNavigationController _navigation;
  late final LiquidNavigationObserver _observer;
  Timer? _cycle;
  var _index = 0;

  @override
  void initState() {
    super.initState();
    _navigation = LiquidNavigationController(
      navigatorKey: _navigator,
      onAcceptedSelection: () {},
      loadProfile: () async => _profile,
    );
    _observer = LiquidNavigationObserver(_navigation);
    _cycle = Timer.periodic(const Duration(milliseconds: 1450), (_) {
      if (!_navigation.visible) return;
      _index = (_index + 1) % _steps.length;
      _navigation.select(_steps[_index]);
    });
  }

  @override
  void dispose() {
    _cycle?.cancel();
    _navigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigator,
    debugShowCheckedModeBanner: false,
    theme: buildKingdomKidsTheme(),
    navigatorObservers: [_observer],
    initialRoute: AppRoutes.home,
    onGenerateRoute: (settings) {
      // Keep the production transition, while replacing data-backed screens
      // with local fixtures. This harness never restores a session or claims XP.
      if (settings.arguments case final TabRouteTransition transition) {
        return TabGlideRoute(
          settings: settings,
          builder: (_) => _PreviewPage(route: settings.name!),
          fromRoute: transition.fromRoute,
        );
      }
      final template = AppRouter.onGenerateRoute(settings);
      if (template is PageRouteBuilder) {
        return PageRouteBuilder<void>(
          settings: settings,
          transitionDuration: template.transitionDuration,
          reverseTransitionDuration: template.reverseTransitionDuration,
          pageBuilder: (_, _, _) => _PreviewPage(route: settings.name!),
          transitionsBuilder: template.transitionsBuilder,
        );
      }
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => _PreviewPage(route: settings.name!),
      );
    },
    builder: (_, child) =>
        PersistentLiquidNavigationHost(controller: _navigation, child: child!),
  );
}

class _PreviewPage extends StatelessWidget {
  const _PreviewPage({required this.route});

  final String route;

  static const _titles = {
    '/': 'Pick your adventure',
    '/stories': 'A world of stories',
    '/games': 'Ready to play?',
    '/profile': 'Your little explorer',
  };
  static const _colors = {
    '/': Color(0xFFF5C84C),
    '/stories': Color(0xFFB7A5FF),
    '/games': Color(0xFFFF9F83),
    '/profile': Color(0xFFA8C0F0),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _colors[route],
    body: Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.paddingOf(context).top + 30,
              20,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hey, explorer!',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'What will we discover today?',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 32),
                Text(
                  _titles[route]!,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _card(
                        'READ',
                        Icons.auto_stories_rounded,
                        const Color(0xFFB7A5FF),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _card(
                        'PLAY',
                        Icons.sports_esports_rounded,
                        const Color(0xFFFF795F),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(
                  'Faith bigger than fear',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: Image.asset(
                    'assets/images/david_and_goliath.png',
                    height: 530,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 130),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: FloatingLiquidNav(
            selectedRoute: route,
            activeProfile: _profile,
          ),
        ),
      ],
    ),
  );

  Widget _card(String title, IconData icon, Color color) => Container(
    height: 92,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color,
      border: Border.all(color: const Color(0xFF171421), width: 2),
      borderRadius: BorderRadius.circular(23),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Icon(icon),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
      ],
    ),
  );
}
