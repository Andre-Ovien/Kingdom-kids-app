import '../../../core/config/release_endpoint_policy.dart';
import '../domain/subscription_plan.dart';

/// Payment destinations come only from explicit compile configuration. Legacy
/// Sandbox remains fixed; production also requires its expected environment.
/// Neither the API nor a provider response can supply a browser destination.
class SandboxCheckoutConfiguration {
  const SandboxCheckoutConfiguration({
    this.enabled = const bool.fromEnvironment(
      'SQUARE_SANDBOX_CHECKOUT_ENABLED',
    ),
    this.apiBaseUrl = const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://localhost:8000/api',
    ),
    this.productionEnabled = const bool.fromEnvironment(
      'PRODUCTION_PAYMENT_FLOW_ENABLED',
    ),
    this.paymentEnvironment = const String.fromEnvironment(
      'PAYMENT_ENVIRONMENT',
    ),
    this.productionApiBaseUrl = const String.fromEnvironment(
      'PAYMENT_API_BASE_URL',
    ),
    this.productionCheckoutUrl = const String.fromEnvironment(
      'PAYMENT_CHECKOUT_URL',
    ),
  });

  static const approvedApiBaseUrl =
      'https://kingdom-kids-checkout-staging.onrender.com/api';
  static const checkoutUrl =
      'https://kingdom-kids-checkout-staging.onrender.com/parent/checkout/';

  static Uri checkoutUri(SubscriptionBillingPeriod billingPeriod) =>
      Uri.parse(checkoutUrl).replace(
        queryParameters: {
          'plan': switch (billingPeriod) {
            SubscriptionBillingPeriod.monthly => 'monthly',
            SubscriptionBillingPeriod.yearly => 'yearly',
          },
        },
      );

  final bool enabled;
  final String apiBaseUrl;
  final bool productionEnabled;
  final String paymentEnvironment;
  final String productionApiBaseUrl;
  final String productionCheckoutUrl;

  bool get isProductionEnabled =>
      productionEnabled &&
      paymentEnvironment == 'production' &&
      apiBaseUrl == productionApiBaseUrl &&
      _approvedUrl(productionApiBaseUrl, '/api') &&
      _approvedUrl(productionCheckoutUrl, '/parent/checkout/') &&
      Uri.parse(productionApiBaseUrl).origin ==
          Uri.parse(productionCheckoutUrl).origin;

  bool get isEnabled =>
      isProductionEnabled ||
      (!productionEnabled &&
          (paymentEnvironment.isEmpty || paymentEnvironment == 'sandbox') &&
          enabled &&
          apiBaseUrl == approvedApiBaseUrl);

  String get environment => isProductionEnabled ? 'production' : 'sandbox';
  Uri get accessUri => Uri.parse(
    '${isProductionEnabled ? productionApiBaseUrl : approvedApiBaseUrl}/billing/content-access/',
  );
  Uri get handoffUri => Uri.parse(
    '${isProductionEnabled ? productionApiBaseUrl : approvedApiBaseUrl}/billing/checkout-handoffs/',
  );
  Uri browserUri({SubscriptionBillingPeriod? period, bool manage = false}) =>
      Uri.parse(
        isProductionEnabled ? productionCheckoutUrl : checkoutUrl,
      ).replace(
        queryParameters: manage
            ? {'purpose': 'manage'}
            : {
                'plan': period == SubscriptionBillingPeriod.yearly
                    ? 'yearly'
                    : 'monthly',
              },
      );

  static bool _approvedUrl(String raw, String path) {
    final uri = Uri.tryParse(raw);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        isValidConfiguredMediaHost(uri.host.toLowerCase()) &&
        !isUnsafeReleaseEndpointHost(uri.host) &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (!uri.hasPort || uri.port == 443) &&
        uri.path == path &&
        raw == uri.toString() &&
        !raw.contains('%');
  }
}
