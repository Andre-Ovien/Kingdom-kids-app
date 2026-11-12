import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';

/// Deliberately fixed to the isolated test deployment. Neither the API nor a
/// provider response can supply a browser destination or carry a login token.
class SandboxCheckoutConfiguration {
  const SandboxCheckoutConfiguration({
    this.enabled = const bool.fromEnvironment(
      'SQUARE_SANDBOX_CHECKOUT_ENABLED',
    ),
    this.apiBaseUrl = AppConfig.apiBaseUrl,
  });

  static const approvedApiBaseUrl =
      'https://kingdom-kids-checkout-staging.onrender.com/api';
  static const checkoutUrl =
      'https://kingdom-kids-checkout-staging.onrender.com/parent/checkout/';

  final bool enabled;
  final String apiBaseUrl;

  bool get isEnabled => enabled && apiBaseUrl == approvedApiBaseUrl;
}

enum SandboxAccessState { paid, unpaid, unknown }

/// Access and checkout capability are independent server decisions. No local
/// browser result, card SDK callback, or stored boolean grants paid access.
class SandboxContentAccess {
  const SandboxContentAccess({
    required this.parentId,
    required this.state,
    required this.checkoutAvailable,
    this.accessUntil,
  });

  final String parentId;
  final SandboxAccessState state;
  final bool checkoutAvailable;
  final DateTime? accessUntil;

  factory SandboxContentAccess.fromJson(
    Map<String, dynamic> json, {
    required String expectedParentId,
  }) {
    if (json['schema_version'] != 1 ||
        json['parent_id'] != expectedParentId ||
        expectedParentId.isEmpty ||
        json['environment'] != 'sandbox') {
      throw const FormatException('Invalid sandbox access identity or schema.');
    }
    final state = switch (json['access_state']) {
      'paid' => SandboxAccessState.paid,
      'unpaid' => SandboxAccessState.unpaid,
      'unknown' => SandboxAccessState.unknown,
      _ => throw const FormatException('Invalid access state.'),
    };
    final evaluatedAt = _timestamp(json['evaluated_at']);
    final accessUntil = json['access_until'] == null
        ? null
        : _timestamp(json['access_until']);
    if (state == SandboxAccessState.paid &&
        (accessUntil == null || !accessUntil.isAfter(evaluatedAt))) {
      throw const FormatException(
        'Paid access requires an active server term.',
      );
    }
    final checkout = json['checkout'];
    final available =
        json['parent_plan_routing_enabled'] == true &&
        checkout is Map &&
        checkout['state'] == 'available' &&
        checkout['reason_code'] == 'sandbox_only';
    return SandboxContentAccess(
      parentId: expectedParentId,
      state: state,
      checkoutAvailable: available,
      accessUntil: accessUntil,
    );
  }
}

DateTime _timestamp(Object? value) {
  // Reject local timestamps: the server must state an unambiguous instant.
  if (value is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw const FormatException('Invalid access timestamp.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('Invalid access timestamp.');
  return parsed.toUtc();
}

abstract interface class SandboxContentAccessRepository {
  Future<SandboxContentAccess> fetch();
}

class AuthenticatedSandboxContentAccessRepository
    implements SandboxContentAccessRepository {
  AuthenticatedSandboxContentAccessRepository({
    required this.configuration,
    AuthRepository? authRepository,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _auth = authRepository ?? AuthRepository(),
       _client = client ?? http.Client();

  final SandboxCheckoutConfiguration configuration;
  final AuthRepository _auth;
  final http.Client _client;
  final Duration requestTimeout;

  @override
  Future<SandboxContentAccess> fetch() async {
    if (!configuration.isEnabled) {
      throw const AppException('Sandbox checkout is unavailable.');
    }
    final origin = await _auth.restoreSession();
    if (origin == null || origin.parent.id.isEmpty) {
      throw const AppException('Parent sign in is required.');
    }
    final result = await _auth.withAccessToken((token) async {
      final request =
          http.Request(
              'GET',
              Uri.parse(
                '${SandboxCheckoutConfiguration.approvedApiBaseUrl}/billing/content-access/',
              ),
            )
            ..followRedirects = false
            ..headers.addAll({
              'Accept': 'application/json',
              'Cache-Control': 'no-store',
              'Authorization': 'Bearer $token',
            });
      final response = await (() async {
        final stream = await _client.send(request);
        return http.Response.fromStream(stream);
      })().timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw AppException(
          'We could not check sandbox access. Try again.',
          statusCode: response.statusCode,
        );
      }
      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Invalid access response.');
      }
      return SandboxContentAccess.fromJson(
        payload,
        expectedParentId: origin.parent.id,
      );
    });
    // withAccessToken protects request/retry ownership. A successful response
    // also needs a post-flight check before it can be shown to this family.
    final current = await _auth.restoreSession();
    if (current == null || current.parent.id != origin.parent.id) {
      throw const AppException('The signed-in parent changed.');
    }
    return result;
  }

  void dispose() => _client.close();
}

typedef SandboxBrowserLauncher = Future<bool> Function(Uri uri);

Future<bool> _openSystemBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Lives outside AdultGate, whose protected child is disposed on background.
/// Every return from the browser invalidates and rechecks the server snapshot.
class SandboxCheckoutController extends ChangeNotifier {
  SandboxCheckoutController({
    this.configuration = const SandboxCheckoutConfiguration(),
    required SandboxContentAccessRepository repository,
    SandboxBrowserLauncher? launcher,
  }) : _repository = repository,
       _launcher = launcher ?? _openSystemBrowser;

  final SandboxCheckoutConfiguration configuration;
  final SandboxContentAccessRepository _repository;
  final SandboxBrowserLauncher _launcher;
  SandboxContentAccess? _access;
  bool _checking = false;
  bool _opening = false;
  bool _foreground = true;
  bool _disposed = false;
  int _revision = 0;
  String? _error;

  SandboxContentAccess? get access => _access;
  bool get checking => _checking;
  bool get busy => _checking || _opening;
  String? get error => _error;
  bool get canOpen =>
      !_disposed &&
      configuration.isEnabled &&
      _foreground &&
      !busy &&
      _access?.checkoutAvailable == true;

  void background() {
    _foreground = false;
    _revision++;
    _access = null;
    _checking = false;
    _error = null;
    _notify();
  }

  Future<bool> resume() {
    _foreground = true;
    return refresh();
  }

  Future<bool> refresh() async {
    if (_disposed || !_foreground || !configuration.isEnabled) return false;
    final revision = ++_revision;
    _checking = true;
    _access = null;
    _error = null;
    _notify();
    try {
      final access = await _repository.fetch();
      if (_disposed || revision != _revision || !_foreground) return false;
      _access = access;
      return true;
    } catch (_) {
      if (_disposed || revision != _revision || !_foreground) return false;
      _error = 'Access status unknown. Check again.';
      return false;
    } finally {
      if (!_disposed && revision == _revision) {
        _checking = false;
        _notify();
      }
    }
  }

  Future<void> openCheckout() async {
    if (!canOpen) return;
    _opening = true;
    _notify();
    // Recheck capability and session ownership immediately before the handoff.
    final preflightRevision = _revision + 1;
    final refreshed = await refresh();
    if (!refreshed ||
        _revision != preflightRevision ||
        _disposed ||
        !_foreground ||
        _access?.checkoutAvailable != true) {
      _opening = false;
      _notify();
      return;
    }
    try {
      final launched = await _launcher(
        Uri.parse(SandboxCheckoutConfiguration.checkoutUrl),
      );
      if (!_disposed && _foreground && !launched) {
        _error = 'The browser could not open. Try again.';
      }
    } catch (_) {
      if (!_disposed && _foreground) {
        _error = 'The browser could not open. Try again.';
      }
    } finally {
      if (!_disposed) {
        _opening = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}
