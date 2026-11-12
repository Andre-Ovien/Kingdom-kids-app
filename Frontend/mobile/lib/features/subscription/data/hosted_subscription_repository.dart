import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../../core/errors/app_exception.dart';
import '../../../core/network/paid_content_access_state.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/hosted_subscription.dart';
import '../domain/subscription_plan.dart';
import 'sandbox_checkout.dart';

abstract interface class HostedSubscriptionRepository {
  Future<HostedQuote> quote(SubscriptionBillingPeriod period);
  Future<HostedAuthorization> authorize(
    HostedQuote quote,
    String operationId,
    String password,
  );
  Future<HostedAttempt> prepare(HostedAuthorization authorization);
  Future<HostedAttempt> reconcile(
    String attemptId,
    String operationId,
    SubscriptionBillingPeriod period, {
    String? expectedParentId,
    Object? expectedScope,
  });
  Future<HostedAttempt> cancel(
    String attemptId,
    String operationId,
    SubscriptionBillingPeriod period,
    String password, {
    String? expectedParentId,
    Object? expectedScope,
  });
  Future<({SandboxContentAccess access, Map<String, dynamic>? recovery})>
  access();
}

class HttpHostedSubscriptionRepository implements HostedSubscriptionRepository {
  HttpHostedSubscriptionRepository({
    required this.configuration,
    AuthRepository? authRepository,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _auth = authRepository ?? AuthRepository(),
       _client = client ?? http.Client();
  final SandboxCheckoutConfiguration configuration;
  final AuthRepository _auth;
  final http.Client _client;
  final Duration timeout;
  static const prefix = 'billing/square/hosted-checkout/';

  Future<({Map<String, dynamic> json, String parent, Object scope})> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    String? expectedParentId,
    Object? expectedScope,
  }) async {
    if (!configuration.isHostedProductionEnabled) {
      throw const AppException('Checkout is unavailable.');
    }
    final origin = await _auth.captureParentAccessOwner();
    if (origin == null) {
      throw const AppException(
        'Please sign in as a parent.',
        code: 'authentication_required',
      );
    }
    if ((expectedParentId != null && expectedParentId != origin.parentId) ||
        (expectedScope != null && expectedScope != origin.scope)) {
      throw const AppException('The signed-in parent changed.');
    }
    final uri = Uri.parse(
      '${configuration.productionApiBaseUrl}/$path',
    ).replace(queryParameters: query);
    final json = await _auth.withAccessToken((token) async {
      final current = await _auth.captureParentAccessOwner();
      if (current?.scope != origin.scope ||
          current?.parentId != origin.parentId) {
        throw const AppException('The signed-in parent changed.');
      }
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
          'Cache-Control': 'no-store',
        });
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(timeout);
      if (response.body.length > 65536) {
        throw const FormatException('Invalid checkout response.');
      }
      final decoded = jsonDecode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded is Map ? decoded['code']?.toString() : null;
        throw AppException(
          code == 'invalid_parent_password'
              ? 'That password did not match. Please try again.'
              : 'We could not complete that request. Try again.',
          statusCode: response.statusCode,
          code: code,
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid checkout response.');
      }
      return decoded;
    });
    final current = await _auth.captureParentAccessOwner();
    if (origin.scope != current?.scope ||
        origin.parentId != current?.parentId) {
      throw const AppException('The signed-in parent changed.');
    }
    validateHostedIdentity(json, origin.parentId);
    return (json: json, parent: origin.parentId, scope: origin.scope);
  }

  @override
  Future<HostedQuote> quote(SubscriptionBillingPeriod period) async {
    final result = await _request(
      'GET',
      '${prefix}quote/',
      query: {'billing_period': period.name},
    );
    return HostedQuote.fromJson(
      result.json,
      result.parent,
      period,
      ownerScope: result.scope,
    );
  }

  @override
  Future<HostedAuthorization> authorize(
    HostedQuote quote,
    String operationId,
    String password,
  ) async {
    final result = await _request(
      'POST',
      '${prefix}authorize/',
      expectedParentId: quote.parentId,
      expectedScope: quote.ownerScope,
      body: {
        'operation_id': hostedUuid(operationId),
        'billing_period': quote.period.name,
        'password': password,
        'accepted': true,
        'disclosure_version': quote.disclosureVersion,
        'disclosure_sha256': quote.disclosureHash,
      },
    );
    if (result.parent != quote.parentId) {
      throw const AppException('The signed-in parent changed.');
    }
    return HostedAuthorization.fromJson(
      result.json,
      result.parent,
      operationId,
      quote.period,
      ownerScope: result.scope,
    );
  }

  @override
  Future<HostedAttempt> prepare(HostedAuthorization authorization) async {
    final result = await _request(
      'POST',
      '${prefix}prepare/',
      expectedParentId: authorization.parentId,
      expectedScope: authorization.ownerScope,
      body: {
        'operation_id': authorization.operationId,
        'billing_period': authorization.period.name,
        'authorization_token': authorization.token,
      },
    );
    return HostedAttempt.fromJson(
      result.json,
      result.parent,
      operationId: authorization.operationId,
      period: authorization.period,
      expectedAttemptId: authorization.attemptId,
    );
  }

  @override
  Future<HostedAttempt> reconcile(
    String attemptId,
    String operationId,
    SubscriptionBillingPeriod period, {
    String? expectedParentId,
    Object? expectedScope,
  }) async {
    final result = await _request(
      'POST',
      '${prefix}attempts/${hostedUuid(attemptId)}/reconcile/',
      expectedParentId: expectedParentId,
      expectedScope: expectedScope,
      body: const {},
    );
    return HostedAttempt.fromJson(
      result.json,
      result.parent,
      operationId: operationId,
      period: period,
      expectedAttemptId: attemptId,
    );
  }

  @override
  Future<HostedAttempt> cancel(
    String attemptId,
    String operationId,
    SubscriptionBillingPeriod period,
    String password, {
    String? expectedParentId,
    Object? expectedScope,
  }) async {
    final result = await _request(
      'POST',
      '${prefix}attempts/${hostedUuid(attemptId)}/cancel/',
      expectedParentId: expectedParentId,
      expectedScope: expectedScope,
      body: {'password': password},
    );
    return HostedAttempt.fromJson(
      result.json,
      result.parent,
      operationId: operationId,
      period: period,
      expectedAttemptId: attemptId,
    );
  }

  @override
  Future<({SandboxContentAccess access, Map<String, dynamic>? recovery})>
  access() async {
    final revision = paidContentAccessState.denialRevision;
    final result = await _request('GET', 'billing/content-access/');
    final access = SandboxContentAccess.fromJson(
      result.json,
      expectedParentId: result.parent,
      expectedEnvironment: 'production',
      allowHostedProduction: true,
    );
    final recovery = result.json['hosted_checkout_recovery'];
    final owner = await _auth.captureParentAccessOwner();
    if (owner?.scope != result.scope || owner?.parentId != result.parent) {
      throw const AppException('The signed-in parent changed.');
    }
    final scope = result.scope;
    if (access.state == SandboxAccessState.paid &&
        revision != paidContentAccessState.denialRevision) {
      throw const AppException('Access status changed. Check again.');
    }
    if (access.enforcementEnabled && access.routingEnabled) {
      if (access.state == SandboxAccessState.unpaid) {
        paidContentAccessState.deny(scope);
      } else if (access.state == SandboxAccessState.paid) {
        paidContentAccessState.allow(scope, expectedDenialRevision: revision);
      }
    }
    return (
      access: access,
      recovery: recovery is Map<String, dynamic> ? recovery : null,
    );
  }

  void dispose() => _client.close();
}
