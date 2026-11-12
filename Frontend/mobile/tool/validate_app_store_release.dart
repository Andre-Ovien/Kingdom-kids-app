import 'dart:convert';
import 'dart:io';

import 'package:mobile/features/subscription/data/parent_checkout_configuration.dart';

import 'validate_release_config.dart';

/// Validate the SAME public JSON passed to --dart-define-from-file. This is a
/// build-input check, not proof of App Store territory or legal approval.
void validateAppStoreRelease(
  Map<String, dynamic> defines, {
  required String approvedApiBaseUrl,
  required String approvedCheckoutUrl,
}) {
  String value(String key) => defines[key]?.toString() ?? '';
  if (value('SQUARE_SANDBOX_CHECKOUT_ENABLED') != 'false' &&
      value('SQUARE_SANDBOX_CHECKOUT_ENABLED').isNotEmpty) {
    throw const ReleaseConfigurationException(
      'Sandbox checkout must be disabled for App Store submission.',
    );
  }
  if (value('SUBSCRIPTION_REVIEW_ID').isNotEmpty) {
    throw const ReleaseConfigurationException(
      'Remove the local subscription review override.',
    );
  }
  validateReleaseConfiguration([
    value('API_BASE_URL'),
    value('CONTENT_MEDIA_HOSTS'),
  ]);
  final configuration = SandboxCheckoutConfiguration(
    apiBaseUrl: value('API_BASE_URL'),
    productionEnabled: value('PRODUCTION_PAYMENT_FLOW_ENABLED') == 'true',
    paymentEnvironment: value('PAYMENT_ENVIRONMENT'),
    productionApiBaseUrl: value('PAYMENT_API_BASE_URL'),
    productionCheckoutUrl: value('PAYMENT_CHECKOUT_URL'),
  );
  if (!configuration.isProductionEnabled ||
      configuration.productionApiBaseUrl != approvedApiBaseUrl ||
      configuration.productionCheckoutUrl != approvedCheckoutUrl ||
      configuration.productionApiBaseUrl ==
          SandboxCheckoutConfiguration.approvedApiBaseUrl ||
      configuration.productionCheckoutUrl ==
          SandboxCheckoutConfiguration.checkoutUrl) {
    throw const ReleaseConfigurationException(
      'Use the explicitly approved production API and checkout configuration.',
    );
  }
}

void main(List<String> arguments) {
  try {
    if (arguments.length != 3) {
      throw const ReleaseConfigurationException(
        'Expected public build-defines JSON, approved API URL, and approved checkout URL.',
      );
    }
    final decoded = jsonDecode(File(arguments[0]).readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw const ReleaseConfigurationException(
        'Build definitions must be a JSON object.',
      );
    }
    validateAppStoreRelease(
      decoded,
      approvedApiBaseUrl: arguments[1],
      approvedCheckoutUrl: arguments[2],
    );
    stdout.writeln(
      'App Store build inputs validated. Territory, privacy, billing operations, and App Review qualification remain required.',
    );
  } on ReleaseConfigurationException catch (error) {
    stderr.writeln('App Store configuration error: ${error.message}');
    exitCode = 64;
  } on FormatException {
    stderr.writeln(
      'App Store configuration error: invalid build-defines JSON.',
    );
    exitCode = 64;
  } on FileSystemException {
    stderr.writeln(
      'App Store configuration error: build-defines JSON could not be read.',
    );
    exitCode = 64;
  }
}
