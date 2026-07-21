class AppConfig {
  const AppConfig._();

  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000/api',
  );

  /// Builds an API endpoint from either the backend root or an explicit API
  /// base. This keeps local launches resilient when `API_BASE_URL` is supplied
  /// as `http://host:8000` instead of `http://host:8000/api`.
  static Uri resolveApiUri(
    String path, {
    String baseUrl = apiBaseUrl,
    Map<String, String> queryParameters = const {},
  }) {
    final configuredBase = Uri.parse(baseUrl.trim());
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
