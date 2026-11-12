import 'subscription_plan.dart';
import 'hosted_checkout_return.dart';

DateTime hostedTimestamp(Object? value) {
  if (value is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw const FormatException('Invalid payment time.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('Invalid payment time.');
  return parsed.toUtc();
}

void validateHostedIdentity(Map<String, dynamic> json, String parentId) {
  if (json['schema_version'] != 1 ||
      parentId.isEmpty ||
      json['parent_id'] != parentId ||
      json['environment'] != 'production') {
    throw const FormatException('Invalid payment identity.');
  }
}

SubscriptionBillingPeriod hostedPeriod(Object? value) => switch (value) {
  'monthly' => SubscriptionBillingPeriod.monthly,
  'yearly' => SubscriptionBillingPeriod.yearly,
  _ => throw const FormatException('Invalid payment period.'),
};

String hostedUuid(Object? value) {
  if (value is! String || !HostedCheckoutReturn.uuid.hasMatch(value)) {
    throw const FormatException('Invalid payment reference.');
  }
  return value.toLowerCase();
}

Uri? hostedProviderUri(Object? value) {
  if (value == null) return null;
  if (value is! String || value.length > 2048) {
    throw const FormatException('Invalid payment destination.');
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.hasPort ||
      value.contains('%') ||
      uri.toString() != value) {
    throw const FormatException('Invalid payment destination.');
  }
  final short =
      uri.host == 'square.link' &&
      RegExp(r'^/u/[A-Za-z0-9_-]+$').hasMatch(uri.path);
  final checkout =
      uri.host == 'checkout.square.site' &&
      RegExp(
        r'^/merchant/[A-Za-z0-9_-]+/order/[A-Za-z0-9_-]+$',
      ).hasMatch(uri.path);
  if (!short && !checkout) {
    throw const FormatException('Invalid payment destination.');
  }
  return uri;
}

class HostedQuote {
  HostedQuote.fromJson(
    Map<String, dynamic> json,
    this.parentId,
    this.period, {
    this.ownerScope,
  }) {
    validateHostedIdentity(json, parentId);
    if (hostedPeriod(json['billing_period']) != period ||
        json['automatic_renewal'] != true ||
        json['billing_controller'] != 'square_hosted_subscriptions' ||
        json['cadence'] !=
            (period == SubscriptionBillingPeriod.monthly
                ? 'THIRTY_DAYS'
                : 'ANNUAL') ||
        json['amount_minor'] != period.amountMinor ||
        json['currency'] != 'USD' ||
        json['policy_id'] is! String ||
        (json['policy_id'] as String).isEmpty ||
        json['disclosure_version'] is! String ||
        json['disclosure_sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['disclosure_sha256']) ||
        json['disclosure'] is! String ||
        (json['disclosure'] as String).isEmpty ||
        (json['disclosure'] as String).length > 12000) {
      throw const FormatException('Invalid subscription quote.');
    }
    disclosure = json['disclosure'];
    disclosureVersion = json['disclosure_version'];
    disclosureHash = json['disclosure_sha256'];
  }
  final String parentId;
  final Object? ownerScope;
  final SubscriptionBillingPeriod period;
  late final String disclosure, disclosureVersion, disclosureHash;
}

class HostedAuthorization {
  HostedAuthorization.fromJson(
    Map<String, dynamic> json,
    this.parentId,
    this.operationId,
    this.period, {
    this.ownerScope,
  }) {
    validateHostedIdentity(json, parentId);
    if (hostedUuid(json['operation_id']) != operationId ||
        hostedPeriod(json['billing_period']) != period ||
        json['amount_minor'] != period.amountMinor ||
        json['currency'] != 'USD' ||
        json['authorization_token'] is! String ||
        !RegExp(
          r'^kkhost\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(json['authorization_token'])) {
      throw const FormatException('Invalid parent authorization.');
    }
    attemptId = hostedUuid(json['attempt_id']);
    token = json['authorization_token'];
    expiresAt = hostedTimestamp(json['authorization_expires_at']);
    if (!expiresAt.isAfter(DateTime.now().toUtc()) ||
        expiresAt.isAfter(
          DateTime.now().toUtc().add(const Duration(minutes: 10, seconds: 5)),
        )) {
      throw const FormatException('Invalid authorization expiry.');
    }
  }
  final String operationId;
  final String parentId;
  final Object? ownerScope;
  final SubscriptionBillingPeriod period;
  late final String attemptId, token;
  late final DateTime expiresAt;
}

class HostedAttempt {
  HostedAttempt.fromJson(
    Map<String, dynamic> json,
    String parentId, {
    required this.operationId,
    required this.period,
    String? expectedAttemptId,
  }) {
    validateHostedIdentity(json, parentId);
    attemptId = hostedUuid(json['attempt_id']);
    if ((expectedAttemptId != null && attemptId != expectedAttemptId) ||
        hostedUuid(json['operation_id']) != operationId ||
        hostedPeriod(json['billing_period']) != period ||
        json['amount_minor'] != period.amountMinor ||
        json['currency'] != 'USD' ||
        !const {
          'reserved',
          'creating',
          'ready',
          'pending',
          'paid',
          'failed',
          'canceled',
          'review_required',
        }.contains(json['state']) ||
        !const {'paid', 'unpaid', 'unknown'}.contains(json['access_state'])) {
      throw const FormatException('Invalid subscription status.');
    }
    state = json['state'];
    accessState = json['access_state'];
    paymentConfirmed = json['payment_confirmed'] == true;
    renewalsEnabled = json['renewals_enabled'] == true;
    accessUntil = json['access_until'] == null
        ? null
        : hostedTimestamp(json['access_until']);
    returnState = json['return_state'] == null
        ? null
        : hostedUuid(json['return_state']);
    checkoutUri = hostedProviderUri(json['checkout_url']);
    if (checkoutUri != null && state != 'ready') {
      throw const FormatException('Unexpected payment link.');
    }
    if (state == 'ready' && (checkoutUri == null || returnState == null)) {
      throw const FormatException('Incomplete payment link.');
    }
    if (paymentConfirmed &&
        (accessState != 'paid' ||
            accessUntil == null ||
            (state != 'paid' && state != 'canceled'))) {
      throw const FormatException('Unverified payment status.');
    }
  }
  final String operationId;
  final SubscriptionBillingPeriod period;
  late final String attemptId, state, accessState;
  late final String? returnState;
  late final bool paymentConfirmed, renewalsEnabled;
  late final DateTime? accessUntil;
  late final Uri? checkoutUri;
  bool get isVerifiedPaid =>
      paymentConfirmed &&
      accessState == 'paid' &&
      accessUntil != null &&
      accessUntil!.isAfter(DateTime.now().toUtc());
  bool get isFailed =>
      !isVerifiedPaid && (state == 'failed' || state == 'canceled');
}
