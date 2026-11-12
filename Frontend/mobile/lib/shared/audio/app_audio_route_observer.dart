import 'package:flutter/widgets.dart';

import 'app_audio_controller.dart';

/// Tracks dialogs and directly pushed screens as well as named app routes.
class AppAudioRouteObserver extends NavigatorObserver {
  AppAudioRouteObserver(this.controller);

  final AppAudioController controller;
  final List<Route<dynamic>> _routes = [];

  void _refresh() =>
      controller.setRoute(_routes.isEmpty ? null : _routes.last.settings.name);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _refresh();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _refresh();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _refresh();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _refresh();
  }
}
