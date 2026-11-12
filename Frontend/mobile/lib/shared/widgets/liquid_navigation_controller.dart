import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/router.dart';
import '../../core/network/feature_view_state_cache.dart';
import '../../features/auth/domain/kid_profile.dart';

/// State belonging to the app, rather than any of the replaceable tab routes.
class LiquidNavigationController extends ChangeNotifier {
  LiquidNavigationController({
    required this.navigatorKey,
    required this.onAcceptedSelection,
    required Future<KidProfile?> Function() loadProfile,
    this.prepareTab,
  }) : _loadProfile = loadProfile;

  static const mainRoutes = [
    AppRoutes.home,
    AppRoutes.stories,
    AppRoutes.games,
  ];
  static const visibleRoutes = [...mainRoutes, AppRoutes.profile];

  final GlobalKey<NavigatorState> navigatorKey;
  final VoidCallback onAcceptedSelection;
  final Future<KidProfile?> Function() _loadProfile;
  final Future<FeaturePagePreparation> Function(String route)? prepareTab;
  String _selectedRoute = AppRoutes.home;
  KidProfile? _profile;
  bool _visible = false;
  bool _requestPending = false;
  bool _notificationQueued = false;
  bool _disposed = false;
  int _routeGeneration = 0;
  int _profileGeneration = 0;
  int _selectionRequest = 0;
  Animation<double>? _routeAnimation;

  String get selectedRoute => _selectedRoute;
  KidProfile? get activeProfile => _profile;
  bool get visible => _visible;

  /// Every input path uses the same acceptance rule. Navigation itself is silent.
  bool select(String route) {
    final navigator = navigatorKey.currentState;
    if (_disposed ||
        !_visible ||
        _requestPending ||
        route == _selectedRoute ||
        !visibleRoutes.contains(route) ||
        navigator == null) {
      return false;
    }
    _requestPending = true;
    final selectionRequest = ++_selectionRequest;
    final generation = _routeGeneration;
    try {
      Future<void> navigate() async {
        final preparation = await prepareTab?.call(route);
        if (_disposed ||
            !_visible ||
            generation != _routeGeneration ||
            (preparation != null && !preparation.isCurrent)) {
          if (selectionRequest == _selectionRequest) _requestPending = false;
          return;
        }
        unawaited(
          navigator.pushReplacementNamed<void, void>(
            route,
            arguments: TabRouteTransition(
              fromRoute: _selectedRoute,
              preparation: preparation,
            ),
          ),
        );
      }

      if (prepareTab == null) {
        unawaited(
          navigator.pushReplacementNamed<void, void>(
            route,
            arguments: TabRouteTransition(fromRoute: _selectedRoute),
          ),
        );
      } else {
        unawaited(
          navigate().catchError((Object _) {
            if (selectionRequest == _selectionRequest) _requestPending = false;
          }),
        );
      }
      onAcceptedSelection();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        // The observer reconciles the authoritative route. Keep input guarded
        // while pages glide; release immediately for a reduced-motion snap.
        if (selectionRequest == _selectionRequest &&
            _routeGeneration > generation &&
            (_routeAnimation == null ||
                _routeAnimation!.status == AnimationStatus.completed)) {
          _requestPending = false;
        }
      });
      return true;
    } catch (_) {
      if (selectionRequest == _selectionRequest) _requestPending = false;
      rethrow;
    }
  }

  void didChangeTopRoute(Route<dynamic>? route) {
    if (_disposed) return;
    _routeGeneration++;
    _routeAnimation?.removeStatusListener(_transitionStatusChanged);
    _routeAnimation = route is TransitionRoute ? route.animation : null;
    _routeAnimation?.addStatusListener(_transitionStatusChanged);
    final name = route?.settings.name;
    _visible = route is PageRoute && visibleRoutes.contains(name);
    _requestPending =
        _visible &&
        _routeAnimation != null &&
        _routeAnimation!.status != AnimationStatus.completed;
    if (_visible) {
      _selectedRoute = name!;
      unawaited(_refreshProfile());
    } else {
      _profileGeneration++;
      if (name == AppRoutes.splash ||
          name == AppRoutes.onboarding ||
          (name?.startsWith('/auth') ?? false)) {
        _profile = null;
      }
    }
    _scheduleNotification();
  }

  void _transitionStatusChanged(AnimationStatus status) {
    if (!_visible) return;
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      _requestPending = true;
    } else if (status == AnimationStatus.completed) {
      final animation = _routeAnimation;
      // Hero measurement temporarily makes ModalRoute's animation proxy look
      // completed, then restores it to forward in the same frame. Only release
      // input when completion remains authoritative at the end of that frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed &&
            identical(animation, _routeAnimation) &&
            animation?.status == AnimationStatus.completed) {
          _requestPending = false;
        }
      });
    }
  }

  Future<void> _refreshProfile() async {
    final request = ++_profileGeneration;
    try {
      final profile = await _loadProfile();
      if (_disposed || request != _profileGeneration || !_visible) return;
      _profile = profile;
      _scheduleNotification();
    } catch (_) {
      // Existing screens still own session-expiry navigation and error UI.
      // A navigation badge must never create a second authentication flow.
    }
  }

  /// Current screens already load their selected child. Reuse that result;
  /// outgoing routes and stale asynchronous reads may not replace its identity.
  void publishProfile(String route, KidProfile? profile) {
    if (profile == null || _disposed) return;
    final generation = _routeGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed ||
          generation != _routeGeneration ||
          !_visible ||
          route != _selectedRoute ||
          _sameProfile(_profile, profile)) {
        return;
      }
      _profileGeneration++;
      _profile = profile;
      _scheduleNotification();
    });
  }

  void _scheduleNotification() {
    if (_disposed) return;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      // User input can hide the dock in the very first dialog/detail frame.
      notifyListeners();
      return;
    }
    if (_notificationQueued) return;
    _notificationQueued = true;
    // Navigator observers can run during the Navigator's build; notify the
    // persistent ancestor only after that frame, never during a descendant build.
    binding.addPostFrameCallback((_) {
      if (_disposed) return;
      _notificationQueued = false;
      notifyListeners();
    });
    binding.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _selectionRequest++;
    _routeAnimation?.removeStatusListener(_transitionStatusChanged);
    _profileGeneration++;
    super.dispose();
  }
}

bool _sameProfile(KidProfile? a, KidProfile b) =>
    a?.id == b.id &&
    a?.parentId == b.parentId &&
    a?.avatarKey == b.avatarKey &&
    a?.displayName == b.displayName &&
    a?.updatedAt == b.updatedAt;

class LiquidNavigationObserver extends NavigatorObserver {
  LiquidNavigationObserver(this.controller);

  final LiquidNavigationController controller;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    // Navigator owns the real top route, including replacement transitions and
    // popups. Do not reconstruct it from an independently maintained history.
    controller.didChangeTopRoute(topRoute);
  }
}

class LiquidNavigationScope extends InheritedWidget {
  const LiquidNavigationScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final LiquidNavigationController controller;

  static LiquidNavigationController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LiquidNavigationScope>()
      ?.controller;

  @override
  bool updateShouldNotify(LiquidNavigationScope oldWidget) =>
      oldWidget.controller != controller;
}
