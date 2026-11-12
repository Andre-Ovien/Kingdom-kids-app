import 'dart:async';

import 'package:flutter/material.dart';

import '../core/constants/app_constants.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/splash/data/startup_destination_resolver.dart';
import '../features/splash/presentation/splash_screen.dart';
import '../features/subscription/data/parent_content_access_monitor.dart';
import '../shared/audio/app_audio_controller.dart';
import '../shared/audio/app_audio_route_observer.dart';
import '../shared/audio/app_audio_scope.dart';
import '../shared/widgets/liquid_navigation_controller.dart';
import '../shared/widgets/persistent_liquid_navigation_host.dart';
import '../shared/widgets/scoped_feature_page.dart';
import 'app_route_observer.dart';
import 'router.dart';
import 'theme.dart';

class KingdomKidsApp extends StatefulWidget {
  const KingdomKidsApp({
    super.key,
    this.initialRoute = AppRoutes.splash,
    this.splashDestinationResolver,
    this.splashVideoControllerFactory,
    this.audioController,
  });

  final String initialRoute;
  final SplashDestinationResolver? splashDestinationResolver;
  final SplashVideoControllerFactory? splashVideoControllerFactory;
  final AppAudioController? audioController;

  @override
  State<KingdomKidsApp> createState() => _KingdomKidsAppState();
}

class _KingdomKidsAppState extends State<KingdomKidsApp>
    with WidgetsBindingObserver {
  late final AppAudioController _audio;
  late final AppAudioRouteObserver _audioRoutes;
  late final bool _ownsAudio;
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final LiquidNavigationController _navigation;
  late final LiquidNavigationObserver _navigationRoutes;
  late final ParentContentAccessMonitor _contentAccess;

  @override
  void initState() {
    super.initState();
    _contentAccess = ParentContentAccessMonitor();
    unawaited(_contentAccess.refresh());
    _ownsAudio = widget.audioController == null;
    _audio = widget.audioController ?? AppAudioController();
    _audioRoutes = AppAudioRouteObserver(_audio);
    _navigation = LiquidNavigationController(
      navigatorKey: _navigatorKey,
      onAcceptedSelection: () {},
      loadProfile: AuthRepository().currentKid,
      prepareTab: ScopedFeaturePage.prepare,
    );
    _navigationRoutes = LiquidNavigationObserver(_navigation);
    WidgetsBinding.instance.addObserver(this);
    _audio.setForeground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    unawaited(_audio.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _audio.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) unawaited(_contentAccess.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _contentAccess.dispose();
    _navigation.dispose();
    _audio.setForeground(false);
    if (_ownsAudio) _audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Route<dynamic> routeFactory(RouteSettings settings) {
      return AppRouter.onGenerateRoute(
        settings,
        splashDestinationResolver: widget.splashDestinationResolver,
        splashVideoControllerFactory: widget.splashVideoControllerFactory,
      );
    }

    return AppAudioScope(
      controller: _audio,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: buildKingdomKidsTheme(),
        themeMode: ThemeMode.light,
        initialRoute: widget.initialRoute,
        onGenerateInitialRoutes: (routeName) => [
          routeFactory(RouteSettings(name: routeName)),
        ],
        onGenerateRoute: routeFactory,
        navigatorObservers: [appRouteObserver, _audioRoutes, _navigationRoutes],
        builder: (context, child) => PersistentLiquidNavigationHost(
          controller: _navigation,
          child: child!,
        ),
      ),
    );
  }
}
