import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The viewer renders bundled native models; Flutter owns taps, movement,
/// timer, pause and completion. It never accepts a renderer-submitted score.
abstract interface class ArkGardenViewer {
  Widget get view;
  Future<void> load({
    required Uri uri,
    required bool Function(String) allowsNavigation,
    required void Function(String) onMessage,
    required void Function() onFailure,
  });
  Future<void> configure(Map<String, dynamic> config);
  Future<void> state(Map<String, dynamic> state);
  Future<void> close();
}

class ArkGardenWebView implements ArkGardenViewer {
  ArkGardenWebView()
    : _controller = WebViewController(
        onPermissionRequest: (request) => request.deny(),
      );
  final WebViewController _controller;
  bool _closed = false;

  @override
  Widget get view => WebViewWidget(controller: _controller);

  @override
  Future<void> load({
    required Uri uri,
    required bool Function(String) allowsNavigation,
    required void Function(String) onMessage,
    required void Function() onFailure,
  }) async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setBackgroundColor(const Color(0xFFB5DBA5));
    await _controller.addJavaScriptChannel(
      'KingdomArkBridge',
      onMessageReceived: (message) {
        if (!_closed) onMessage(message.message);
      },
    );
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) => allowsNavigation(request.url)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onWebResourceError: (error) {
          if (!_closed && error.isForMainFrame != false) onFailure();
        },
      ),
    );
    await _controller.loadRequest(uri);
  }

  @override
  Future<void> configure(Map<String, dynamic> config) =>
      _controller.runJavaScript(
        'window.KingdomArkGarden.configure({config:${jsonEncode(config)}});',
      );

  @override
  Future<void> state(Map<String, dynamic> state) => _controller.runJavaScript(
    'window.KingdomArkGarden.state(${jsonEncode(state)});',
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _controller.runJavaScript('window.KingdomArkGarden?.dispose();');
      await _controller.removeJavaScriptChannel('KingdomArkBridge');
    } on Object {
      // The platform can already have disposed its WebView during route exit.
    }
  }
}
