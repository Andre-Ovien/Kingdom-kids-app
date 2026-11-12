import 'package:flutter/foundation.dart';

import 'release_endpoint_policy.dart';

class AppConfig {
  const AppConfig._();

  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000/api',
  );

  /// Extra application-owned hosts that may serve child-facing images/audio.
  ///
  /// The configured API host is trusted automatically. Keep this value to
  /// comma-separated hostnames (without schemes, paths, or wildcards).
  static const contentMediaHosts = String.fromEnvironment(
    'CONTENT_MEDIA_HOSTS',
    defaultValue: '',
  );

  static const contentMediaPolicy = ContentMediaPolicy(
    apiBaseUrl: apiBaseUrl,
    configuredHosts: contentMediaHosts,
    requireHttps: kReleaseMode,
  );

  static Uri validateApiBaseUri({
    String baseUrl = apiBaseUrl,
    bool requireHttps = kReleaseMode,
  }) {
    final value = baseUrl.trim();
    if (value.isEmpty) {
      throw const AppConfigurationException('API_BASE_URL is missing.');
    }

    late final Uri uri;
    try {
      uri = Uri.parse(value);
    } on FormatException {
      throw const AppConfigurationException('API_BASE_URL is invalid.');
    }
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw const AppConfigurationException(
        'API_BASE_URL must be an absolute HTTP or HTTPS URL.',
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const AppConfigurationException(
        'API_BASE_URL must use HTTP or HTTPS.',
      );
    }
    if (requireHttps && uri.scheme != 'https') {
      throw const AppConfigurationException(
        'Release builds require an HTTPS API_BASE_URL.',
      );
    }
    if (requireHttps && isUnsafeReleaseEndpointHost(uri.host)) {
      throw const AppConfigurationException(
        'Release builds require a publicly routable API_BASE_URL host.',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasFragment || uri.hasQuery) {
      throw const AppConfigurationException(
        'API_BASE_URL cannot contain credentials, a query, or a fragment.',
      );
    }
    return uri;
  }

  /// Builds an API endpoint from either the backend root or an explicit API
  /// base. This keeps local launches resilient when `API_BASE_URL` is supplied
  /// as `http://host:8000` instead of `http://host:8000/api`.
  static Uri resolveApiUri(
    String path, {
    String baseUrl = apiBaseUrl,
    Map<String, String> queryParameters = const {},
  }) {
    final configuredBase = validateApiBaseUri(baseUrl: baseUrl);
    final configuredPath = configuredBase.path;
    final basePath = configuredPath.isEmpty || configuredPath == '/'
        ? '/api/'
        : '${configuredPath.replaceFirst(RegExp(r'/+$'), '')}/';
    final relativePath = path.trim().replaceFirst(RegExp(r'^/+'), '');
    final endpoint = configuredBase
        .replace(path: basePath, query: '', fragment: '')
        .resolve(relativePath);

    return queryParameters.isEmpty
        ? endpoint
        : endpoint.replace(queryParameters: queryParameters);
  }
}

/// Validates remote child-facing media without initiating a network request.
///
/// URLs fail closed unless their host is either the configured API host or an
/// exact entry in `CONTENT_MEDIA_HOSTS`. Signed CDN query strings are retained,
/// while credentials, fragments, and unexpected ports are rejected.
class ContentMediaPolicy {
  const ContentMediaPolicy({
    required this.apiBaseUrl,
    this.configuredHosts = '',
    this.requireHttps = true,
  });

  final String apiBaseUrl;
  final String configuredHosts;
  final bool requireHttps;

  String? sanitize(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;

    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return null;
    }

    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final localhost = _isLocalhost(host);
    final apiUri = _validatedApiUri();
    final matchesApiOrigin =
        apiUri != null &&
        apiUri.scheme.toLowerCase() == scheme &&
        apiUri.host.toLowerCase() == host &&
        apiUri.port == uri.port;
    if (requireHttps && isUnsafeReleaseEndpointHost(host)) return null;
    if (scheme == 'http') {
      if (requireHttps || (!localhost && !matchesApiOrigin)) return null;
    } else if (scheme != 'https') {
      return null;
    }
    if (requireHttps && localhost) return null;

    if (uri.hasPort) {
      final isDefaultPort =
          (scheme == 'https' && uri.port == 443) ||
          (scheme == 'http' && uri.port == 80);
      final matchesExplicitApiPort =
          apiUri != null &&
          apiUri.hasPort &&
          apiUri.scheme.toLowerCase() == scheme &&
          apiUri.host.toLowerCase() == host &&
          apiUri.port == uri.port;
      if (!isDefaultPort && !matchesExplicitApiPort) return null;
    }

    if (!_trustedHosts(apiUri).contains(host)) return null;
    return raw;
  }

  Uri? _validatedApiUri() {
    try {
      return AppConfig.validateApiBaseUri(
        baseUrl: apiBaseUrl,
        requireHttps: requireHttps,
      );
    } on AppConfigurationException {
      return null;
    }
  }

  Set<String> _trustedHosts(Uri? apiUri) {
    final hosts = configuredHosts
        .split(',')
        .map((host) => host.trim().toLowerCase())
        .where(_isBareHostname)
        .toSet();

    if (apiUri != null) {
      hosts.add(apiUri.host.toLowerCase());
    }
    return hosts;
  }
}

bool _isLocalhost(String host) {
  return host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == '127.0.0.1' ||
      host == '::1';
}

bool _isBareHostname(String value) {
  return isValidConfiguredMediaHost(value);
}

class AppConfigurationException implements Exception {
  const AppConfigurationException(this.message);

  final String message;

  @override
  String toString() => 'AppConfigurationException: $message';
}
