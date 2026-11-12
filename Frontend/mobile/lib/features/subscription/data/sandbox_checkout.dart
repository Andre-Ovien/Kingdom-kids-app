import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/network/paid_content_access_state.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/subscription_plan.dart';
import 'parent_checkout_configuration.dart';
import 'app_store_storefront.dart';

export 'parent_checkout_configuration.dart';

enum SandboxAccessState { paid, unpaid, unknown }

/// Access and checkout capability are independent server decisions. No local
/// browser result, card SDK callback, or stored boolean grants paid access.
class SandboxContentAccess {
  const SandboxContentAccess({
    required this.parentId,
    required this.state,
    required this.checkoutAvailable,
    this.accessUntil,
    this.managementAvailable = false,
    this.handoffAvailable = false,
    this.managementHandoffAvailable = false,
    this.enforcementEnabled = false,
    this.routingEnabled = false,
  });

  final String parentId;
  final SandboxAccessState state;
  final bool checkoutAvailable;
  final DateTime? accessUntil;
  final bool managementAvailable;
  final bool handoffAvailable;
  final bool managementHandoffAvailable;
  final bool enforcementEnabled;
  final bool routingEnabled;

  factory SandboxContentAccess.fromJson(
    Map<String, dynamic> json, {
    required String expectedParentId,
    String expectedEnvironment = 'sandbox',
  }) {
    if (json['schema_version'] != 1 ||
        json['parent_id'] != expectedParentId ||
        expectedParentId.isEmpty ||
        !const {'sandbox', 'production'}.contains(expectedEnvironment) ||
        json['environment'] != expectedEnvironment) {
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
    if (expectedEnvironment == 'production' &&
        (json['content_enforcement_enabled'] is! bool ||
            json['parent_plan_routing_enabled'] is! bool)) {
      throw const FormatException('Invalid production access policy.');
    }
    final enforcement = json['content_enforcement_enabled'] == true;
    final routing = json['parent_plan_routing_enabled'] == true;
    final available =
        routing &&
        (expectedEnvironment != 'production' || enforcement) &&
        checkout is Map &&
        checkout['state'] == 'available' &&
        checkout['reason_code'] ==
            (expectedEnvironment == 'production'
                ? 'production_qualified'
                : 'sandbox_only');
    return SandboxContentAccess(
      parentId: expectedParentId,
      state: state,
      checkoutAvailable: available,
      accessUntil: accessUntil,
      managementAvailable:
          checkout is Map &&
          checkout['management_state'] == 'available' &&
          checkout['management_reason_code'] == 'owned_purchase',
      handoffAvailable:
          checkout is Map && checkout['handoff_available'] == true,
      managementHandoffAvailable:
          checkout is Map && checkout['management_handoff_available'] == true,
      enforcementEnabled: enforcement,
      routingEnabled: routing,
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

abstract interface class ParentCheckoutHandoffRepository {
  Future<Uri> createHandoff({
    SubscriptionBillingPeriod? billingPeriod,
    bool manage = false,
  });
  Future<bool> canLaunchHandoff();
}

class AuthenticatedSandboxContentAccessRepository
    implements SandboxContentAccessRepository, ParentCheckoutHandoffRepository {
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
  Object? _handoffScope;

  @override
  Future<SandboxContentAccess> fetch() async {
    if (!configuration.isEnabled) {
      throw const AppException('Checkout is unavailable.');
    }
    final origin = await _auth.restoreSession();
    final originScope = await _auth.parentAccessScope();
    final denialRevision = paidContentAccessState.denialRevision;
    if (origin == null || origin.parent.id.isEmpty) {
      throw const AppException('Parent sign in is required.');
    }
    final result = await _auth.withAccessToken((token) async {
      final request = http.Request('GET', configuration.accessUri)
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
          'We could not check your access. Try again.',
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
        expectedEnvironment: configuration.environment,
      );
    });
    // withAccessToken protects request/retry ownership. A successful response
    // also needs a post-flight check before it can be shown to this family.
    final current = await _auth.restoreSession();
    if (current == null ||
        current.parent.id != origin.parent.id ||
        originScope == null ||
        originScope != await _auth.parentAccessScope()) {
      throw const AppException('The signed-in parent changed.');
    }
    if (result.state == SandboxAccessState.paid &&
        denialRevision != paidContentAccessState.denialRevision) {
      throw const AppException('Access status changed. Check again.');
    }
    if (configuration.isProductionEnabled && !result.enforcementEnabled) {
      paidContentAccessState.allow(
        originScope,
        expectedDenialRevision: denialRevision,
      );
    } else if (configuration.isProductionEnabled &&
        result.enforcementEnabled &&
        result.routingEnabled) {
      if (result.state == SandboxAccessState.unpaid) {
        paidContentAccessState.deny(originScope);
      } else if (result.state == SandboxAccessState.paid) {
        if (result.accessUntil!.isAfter(DateTime.now().toUtc())) {
          paidContentAccessState.allow(
            originScope,
            expectedDenialRevision: denialRevision,
          );
        } else {
          paidContentAccessState.deny(originScope);
        }
      }
    } else if (!configuration.isProductionEnabled &&
        result.state == SandboxAccessState.paid) {
      paidContentAccessState.allow(
        originScope,
        expectedDenialRevision: denialRevision,
      );
    }
    return result;
  }

  @override
  Future<Uri> createHandoff({
    SubscriptionBillingPeriod? billingPeriod,
    bool manage = false,
  }) async {
    _handoffScope = null;
    if (!configuration.isEnabled || (!manage && billingPeriod == null)) {
      throw const AppException('Checkout is unavailable.');
    }
    final origin = await _auth.restoreSession();
    final scope = await _auth.parentAccessScope();
    if (origin == null || scope == null) {
      throw const AppException('Parent sign in is required.');
    }
    final purpose = manage ? 'manage' : 'purchase';
    final period = manage ? null : billingPeriod!.name;
    final payload = await _auth.withAccessToken((token) async {
      final request = http.Request('POST', configuration.handoffUri)
        ..followRedirects = false
        ..headers.addAll({
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Cache-Control': 'no-store',
          'Authorization': 'Bearer $token',
        })
        ..body = jsonEncode({
          'purpose': purpose,
          if (!manage) 'billing_period': period,
        });
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(requestTimeout);
      if (response.statusCode != 201 && response.statusCode != 200) {
        throw const AppException('Checkout could not open. Try again.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid checkout handoff.');
      }
      return decoded;
    });
    final expiry = _timestamp(payload['expires_at']);
    final seconds = payload['expires_in'];
    final code = payload['code'];
    final now = DateTime.now().toUtc();
    if (payload['schema_version'] != 1 ||
        payload['parent_id'] != origin.parent.id ||
        payload['environment'] != configuration.environment ||
        payload['purpose'] != purpose ||
        payload['billing_period'] != period ||
        payload.containsKey('url') ||
        seconds is! int ||
        seconds <= 0 ||
        seconds > 90 ||
        code is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code) ||
        !expiry.isAfter(now) ||
        expiry.isAfter(now.add(Duration(seconds: seconds + 5))) ||
        scope != await _auth.parentAccessScope()) {
      throw const FormatException('Invalid checkout handoff.');
    }
    _handoffScope = scope;
    return configuration
        .browserUri(period: billingPeriod, manage: manage)
        .replace(fragment: 'handoff=$code');
  }

  @override
  Future<bool> canLaunchHandoff() async =>
      _handoffScope != null && _handoffScope == await _auth.parentAccessScope();

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
    StorefrontCountryProvider? storefrontCountryProvider,
  }) : _repository = repository,
       _launcher = launcher ?? _openSystemBrowser,
       _storefrontCountryProvider =
           storefrontCountryProvider ?? AppStoreStorefront.currentCountryCode;

  final SandboxCheckoutConfiguration configuration;
  final SandboxContentAccessRepository _repository;
  final SandboxBrowserLauncher _launcher;
  final StorefrontCountryProvider _storefrontCountryProvider;
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
      _access?.state == SandboxAccessState.unpaid &&
      _access?.checkoutAvailable == true &&
      (!configuration.isProductionEnabled || _access?.handoffAvailable == true);

  bool get canManage =>
      !_disposed &&
      configuration.isEnabled &&
      _foreground &&
      !busy &&
      _access?.managementAvailable == true &&
      (!configuration.isProductionEnabled ||
          _access?.managementHandoffAvailable == true);

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

  Future<void> openCheckout({
    required SubscriptionBillingPeriod billingPeriod,
  }) => _openAction(billingPeriod: billingPeriod);

  Future<void> openManagement() => _openAction(manage: true);

  Future<void> _openAction({
    SubscriptionBillingPeriod? billingPeriod,
    bool manage = false,
  }) async {
    if (manage ? !canManage : !canOpen) return;
    _opening = true;
    _notify();
    // Recheck capability and session ownership immediately before the handoff.
    final preflightRevision = _revision + 1;
    final refreshed = await refresh();
    if (!refreshed ||
        _revision != preflightRevision ||
        _disposed ||
        !_foreground ||
        (manage
            ? _access?.managementAvailable != true
            : (_access?.state != SandboxAccessState.unpaid ||
                  _access?.checkoutAvailable != true)) ||
        (configuration.isProductionEnabled &&
            (manage
                ? _access?.managementHandoffAvailable != true
                : _access?.handoffAvailable != true))) {
      _opening = false;
      _notify();
      return;
    }
    try {
      if (configuration.isProductionEnabled &&
          await _storefrontCountryProvider() != 'USA') {
        _error = 'Checkout is unavailable for this App Store region.';
        return;
      }
      final repository = _repository;
      final handoff = manage
          ? _access?.managementHandoffAvailable == true
          : _access?.handoffAvailable == true;
      late final Uri uri;
      if (handoff) {
        if (repository is! ParentCheckoutHandoffRepository) {
          throw const FormatException('Handoff unavailable.');
        }
        final handoffRepository = repository as ParentCheckoutHandoffRepository;
        uri = await handoffRepository.createHandoff(
          billingPeriod: billingPeriod,
          manage: manage,
        );
        if (configuration.isProductionEnabled &&
            await _storefrontCountryProvider() != 'USA') {
          _error = 'Checkout is unavailable for this App Store region.';
          return;
        }
        if (!await handoffRepository.canLaunchHandoff()) return;
      } else {
        if (configuration.isProductionEnabled) return;
        uri = configuration.browserUri(period: billingPeriod, manage: manage);
      }
      if (_disposed || !_foreground || _revision != preflightRevision) return;
      final launched = await _launcher(uri);
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
