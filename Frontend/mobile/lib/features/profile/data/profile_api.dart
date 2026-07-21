import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/progress_summary.dart';

class ProfileEndpoints {
  const ProfileEndpoints._();

  static String summary(String profileId) =>
      'progress/kid-profiles/${Uri.encodeComponent(profileId)}/summary/';
}

abstract interface class ProfileApi {
  Future<ProfileProgressSummary> fetchSummary({
    required String accessToken,
    required String profileId,
    required int timezoneOffsetMinutes,
  });
}

class HttpProfileApi implements ProfileApi {
  HttpProfileApi({
    http.Client? client,
    this.baseUrl = AppConfig.apiBaseUrl,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration requestTimeout;

  @override
  Future<ProfileProgressSummary> fetchSummary({
    required String accessToken,
    required String profileId,
    required int timezoneOffsetMinutes,
  }) async {
    final normalizedProfileId = profileId.trim();
    if (normalizedProfileId.isEmpty) {
      throw const AppException(
        'Choose a kid profile to see their progress.',
        code: 'active_kid_required',
      );
    }
    final offset = timezoneOffsetMinutes.clamp(-840, 840);
    try {
      final response = await _client
          .get(
            _uri(ProfileEndpoints.summary(normalizedProfileId), {
              'timezone_offset_minutes': '$offset',
            }),
            headers: {
              'Accept': 'application/json',
              if (accessToken.isNotEmpty)
                'Authorization': 'Bearer $accessToken',
            },
          )
          .timeout(requestTimeout);
      final payload = _decode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final details = _map(payload);
        throw AppException(
          _firstMessage(payload) ??
              (response.statusCode == 404
                  ? 'That kid profile is no longer available.'
                  : 'We could not load this progress yet.'),
          statusCode: response.statusCode,
          code: details['code']?.toString(),
          details: details,
        );
      }
      final summary = _map(payload);
      if (summary.isEmpty || _map(summary['profile']).isEmpty) {
        throw const AppException(
          'The profile service sent an incomplete response.',
          code: 'invalid_profile_summary',
        );
      }
      return ProfileProgressSummary.fromJson(summary);
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to load this profile. Please try again.',
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

  Uri _uri(String path, Map<String, String> query) {
    return AppConfig.resolveApiUri(
      path,
      baseUrl: baseUrl,
      queryParameters: query,
    );
  }

  Object? _decode(String body) {
    if (body.trim().isEmpty) return const {};
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const AppException(
        'The profile service sent an unexpected response.',
        code: 'invalid_profile_response',
      );
    }
  }
}

String? _firstMessage(Object? value) {
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? null : text;
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
