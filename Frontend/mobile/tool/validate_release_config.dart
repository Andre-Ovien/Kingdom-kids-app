import 'dart:io';

import 'package:mobile/core/config/release_endpoint_policy.dart';

class ReleaseConfigurationException implements Exception {
  const ReleaseConfigurationException(this.message);

  final String message;
}

Never _fail(String message) {
  stderr.writeln('Release configuration error: $message');
  exit(64);
}

void main(List<String> arguments) {
  try {
    validateReleaseConfiguration(arguments);
  } on ReleaseConfigurationException catch (error) {
    _fail(error.message);
  }
  stdout.writeln('Release configuration is valid.');
}

void validateReleaseConfiguration(List<String> arguments) {
  if (arguments.length != 2) {
    throw const ReleaseConfigurationException(
      'expected API_BASE_URL and CONTENT_MEDIA_HOSTS as two arguments.',
    );
  }

  final rawApiUrl = arguments[0].trim();
  final apiUri = Uri.tryParse(rawApiUrl);
  if (apiUri == null ||
      apiUri.scheme != 'https' ||
      !apiUri.hasAuthority ||
      apiUri.host.isEmpty ||
      apiUri.userInfo.isNotEmpty ||
      apiUri.query.isNotEmpty ||
      apiUri.fragment.isNotEmpty) {
    throw const ReleaseConfigurationException(
      'API_BASE_URL must be an absolute HTTPS URL without credentials, '
      'a query, or a fragment.',
    );
  }
  if (isUnsafeReleaseEndpointHost(apiUri.host)) {
    throw const ReleaseConfigurationException(
      'API_BASE_URL must use a publicly routable production host.',
    );
  }
  final normalizedPath = apiUri.path.replaceAll(RegExp(r'/+$'), '');
  if (!normalizedPath.endsWith('/api')) {
    throw const ReleaseConfigurationException(
      'API_BASE_URL must end in /api (an optional trailing slash is fine).',
    );
  }

  final mediaHosts = arguments[1]
      .split(',')
      .map((host) => host.trim().toLowerCase())
      .where((host) => host.isNotEmpty)
      .toSet();
  for (final host in mediaHosts) {
    if (!isValidConfiguredMediaHost(host)) {
      throw ReleaseConfigurationException(
        'CONTENT_MEDIA_HOSTS contains an invalid hostname: $host',
      );
    }
    if (isUnsafeReleaseEndpointHost(host)) {
      throw ReleaseConfigurationException(
        'CONTENT_MEDIA_HOSTS must use publicly routable production hosts: $host',
      );
    }
  }
}
