import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/storage/secure_storage.dart';
import '../domain/hosted_subscription.dart';
import '../domain/subscription_plan.dart';

class HostedPendingCheckout {
  const HostedPendingCheckout({
    required this.parentId,
    required this.operationId,
    required this.period,
    this.attemptId,
    this.returnState,
  });
  final String parentId, operationId;
  final SubscriptionBillingPeriod period;
  final String? attemptId, returnState;
  Map<String, dynamic> toJson() => {
    'parent_id': parentId,
    'operation_id': operationId,
    'billing_period': period.name,
    'attempt_id': attemptId,
    'return_state': returnState,
  };
  static HostedPendingCheckout? fromJson(Map<String, dynamic> json) {
    try {
      final parent = json['parent_id'];
      if (parent is! String || parent.isEmpty) return null;
      return HostedPendingCheckout(
        parentId: parent,
        operationId: hostedUuid(json['operation_id']),
        period: hostedPeriod(json['billing_period']),
        attemptId: json['attempt_id'] == null
            ? null
            : hostedUuid(json['attempt_id']),
        returnState: json['return_state'] == null
            ? null
            : hostedUuid(json['return_state']),
      );
    } catch (_) {
      return null;
    }
  }
}

abstract interface class HostedCheckoutPendingStore {
  Future<HostedPendingCheckout?> read(String parentId);
  Future<void> write(HostedPendingCheckout pending);
  Future<void> clear(String parentId);
}

class SecureHostedCheckoutPendingStore implements HostedCheckoutPendingStore {
  SecureHostedCheckoutPendingStore(
    String apiBaseUrl, {
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? kingdomKidsSecureStorage,
       _key =
           'kingdom_kids.hosted_checkout.pending.v1.${base64Url.encode(utf8.encode(apiBaseUrl))}';
  final FlutterSecureStorage _storage;
  final String _key;
  String _parentKey(String parentId) =>
      '$_key.${base64Url.encode(utf8.encode(parentId))}';
  @override
  Future<HostedPendingCheckout?> read(String parentId) async {
    final raw = await _storage.read(key: _parentKey(parentId));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic>
          ? HostedPendingCheckout.fromJson(json)
          : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(HostedPendingCheckout pending) => _storage.write(
    key: _parentKey(pending.parentId),
    value: jsonEncode(pending.toJson()),
  );
  @override
  Future<void> clear(String parentId) =>
      _storage.delete(key: _parentKey(parentId));
}
