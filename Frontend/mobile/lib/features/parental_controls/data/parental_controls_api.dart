import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/parent_settings.dart';

class ParentalControlsEndpoints {
  const ParentalControlsEndpoints._();

  static String preferences(String profileId) =>
      'accounts/kid-profiles/${Uri.encodeComponent(profileId)}/preferences/';
}

abstract interface class ParentalControlsApi {
  Future<ParentSettings> fetchSettings({
    required String accessToken,
    required String profileId,
  });

  Future<ParentSettings> updateSettings({
    required String accessToken,
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  });
}

class HttpParentalControlsApi implements ParentalControlsApi {
  HttpParentalControlsApi({
    http.Client? client,
    this.baseUrl = AppConfig.apiBaseUrl,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration requestTimeout;

  @override
  Future<ParentSettings> fetchSettings({
    required String accessToken,
    required String profileId,
  }) {
    return _request(
      accessToken: accessToken,
      profileId: profileId,
      operation: _PreferencesOperation.fetch,
    );
  }

  @override
  Future<ParentSettings> updateSettings({
    required String accessToken,
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  }) async {
    if (storyTextScale == null && narrationEnabled == null) {
      throw const AppException(
        'Choose at least one reading preference to update.',
        code: 'empty_preferences_update',
      );
    }
    return _request(
      accessToken: accessToken,
      profileId: profileId,
      operation: _PreferencesOperation.update,
      body: {
        if (storyTextScale != null)
          'story_text_scale': storyTextScale.wireValue,
        'narration_enabled': ?narrationEnabled,
      },
    );
  }

  Future<ParentSettings> _request({
    required String accessToken,
    required String profileId,
    required _PreferencesOperation operation,
    Map<String, dynamic>? body,
  }) async {
    final normalizedProfileId = profileId.trim();
    if (normalizedProfileId.isEmpty) {
      throw const AppException(
        'Choose a kid profile to manage their reading preferences.',
        code: 'active_kid_required',
      );
    }

    try {
      final uri = _uri(
        ParentalControlsEndpoints.preferences(normalizedProfileId),
      );
      final response = operation == _PreferencesOperation.fetch
          ? await _client
                .get(uri, headers: _headers(accessToken))
                .timeout(requestTimeout)
          : await _client
                .patch(
                  uri,
                  headers: _headers(accessToken, sendsJson: true),
                  body: jsonEncode(body),
                )
                .timeout(requestTimeout);
      final payload = _decode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final details = _map(payload);
        throw AppException(
          _firstMessage(payload) ??
              (response.statusCode == 404
                  ? 'That kid profile is no longer available.'
                  : operation == _PreferencesOperation.fetch
                  ? 'We could not load these reading preferences.'
                  : 'We could not save these reading preferences.'),
          statusCode: response.statusCode,
          code: details['code']?.toString(),
          details: details,
        );
      }

      final responseJson = _map(payload);
      try {
        final settings = ParentSettings.fromJson(responseJson);
        if (settings.profileId != normalizedProfileId) {
          throw const FormatException('Preferences belonged to another child.');
        }
        return settings;
      } on FormatException {
        throw const AppException(
          'The preferences service sent an incomplete response.',
          code: 'invalid_preferences_response',
        );
      }
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to load these preferences. Please try again.',
        code: 'request_timeout',
      );
    } on SocketException {
      throw const AppException(
        'We could not reach Kingdom Kids. Check your connection and try again.',
        code: 'network_error',
      );
    } on http.ClientException {
      throw const AppException(
        'We could not reach Kingdom Kids. Check your connection and try again.',
        code: 'network_error',
      );
    }
  }

  Uri _uri(String path) {
    return AppConfig.resolveApiUri(path, baseUrl: baseUrl);
  }

  Map<String, String> _headers(String accessToken, {bool sendsJson = false}) =>
      {
        'Accept': 'application/json',
        if (sendsJson) 'Content-Type': 'application/json',
        if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
      };

  Object? _decode(String body) {
    if (body.trim().isEmpty) return const {};
    try {
      return jsonDecode(body);
    } on FormatException {
      return body.trim();
    }
  }
}

enum _PreferencesOperation { fetch, update }

String? _firstMessage(Object? value) {
  if (value is String) {
    final message = value.trim();
    return message.isEmpty ? null : message;
  }
  if (value is List) {
    for (final item in value) {
      final message = _firstMessage(item);
      if (message != null) return message;
    }
  }
  if (value is Map) {
    for (final key in const ['detail', 'message', 'error']) {
      if (value.containsKey(key)) {
        final message = _firstMessage(value[key]);
        if (message != null) return message;
      }
    }
    for (final item in value.values) {
      final message = _firstMessage(item);
      if (message != null) return message;
    }
  }
  return null;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, nested) => MapEntry(key.toString(), nested));
  }
  return const {};
}
