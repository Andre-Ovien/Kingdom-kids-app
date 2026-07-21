import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/story_activity_event.dart';

class ProgressEndpoints {
  const ProgressEndpoints._();

  static String activityEvents(String profileId) =>
      'progress/kid-profiles/${Uri.encodeComponent(profileId)}/activity-events/';
}

abstract interface class ProgressApi {
  Future<StoryActivityEvent> recordStoryActivity({
    required String accessToken,
    required String profileId,
    required String storyId,
    required StoryActivityType eventType,
    required String operationId,
  });
}

class HttpProgressApi implements ProgressApi {
  HttpProgressApi({
    http.Client? client,
    this.baseUrl = AppConfig.apiBaseUrl,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration requestTimeout;

  @override
  Future<StoryActivityEvent> recordStoryActivity({
    required String accessToken,
    required String profileId,
    required String storyId,
    required StoryActivityType eventType,
    required String operationId,
  }) async {
    final normalizedProfileId = _requiredValue(
      profileId,
      message: 'Choose a kid profile before reading.',
      code: 'active_kid_required',
    );
    final normalizedStoryId = _requiredValue(
      storyId,
      message: 'We could not identify that story.',
      code: 'invalid_story_id',
    );
    final normalizedOperationId = _requiredValue(
      operationId,
      message: 'We could not safely save this story activity.',
      code: 'invalid_operation_id',
    );

    try {
      final response = await _client
          .post(
            AppConfig.resolveApiUri(
              ProgressEndpoints.activityEvents(normalizedProfileId),
              baseUrl: baseUrl,
            ),
            headers: {
              'Accept': 'application/json',
              if (accessToken.isNotEmpty)
                'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'operation_id': normalizedOperationId,
              'event_type': eventType.wireName,
              'story_id': normalizedStoryId,
            }),
          )
          .timeout(requestTimeout);
      final payload = _decode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final details = _map(payload);
        throw AppException(
          _firstMessage(payload) ?? _fallbackMessage(response.statusCode),
          statusCode: response.statusCode,
          code: details['code']?.toString(),
          details: details,
        );
      }

      final event = _map(payload);
      if (event.isEmpty) {
        throw const AppException(
          'Your story activity was saved, but we could not read the receipt.',
          code: 'invalid_progress_response',
        );
      }
      try {
        return StoryActivityEvent.fromJson(event);
      } on FormatException {
        throw const AppException(
          'Your story activity was saved, but we could not read the receipt.',
          code: 'invalid_progress_response',
        );
      }
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to save this story activity.',
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

  Object? _decode(String body) {
    if (body.trim().isEmpty) return const {};
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const AppException(
        'The progress service sent an unexpected response.',
        code: 'invalid_progress_response',
      );
    }
  }
}

String _requiredValue(
  String value, {
  required String message,
  required String code,
}) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw AppException(message, code: code);
  return normalized;
}

String _fallbackMessage(int statusCode) {
  return switch (statusCode) {
    401 => 'Please sign in as a parent to save story progress.',
    404 => 'That story or kid profile is not available.',
    409 => 'That story activity changed while saving. Please try again.',
    _ => 'We could not save this story activity. Please try again.',
  };
}

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
    return null;
  }
  if (value is Map) {
    for (final key in const [
      'detail',
      'message',
      'error',
      'non_field_errors',
    ]) {
      if (!value.containsKey(key)) continue;
      final message = _firstMessage(value[key]);
      if (message != null) return message;
    }
    for (final entry in value.entries) {
      if (const {
        'detail',
        'message',
        'error',
        'non_field_errors',
        'code',
        'status',
      }.contains(entry.key.toString())) {
        continue;
      }
      final message = _firstMessage(entry.value);
      if (message != null) return message;
    }
  }
  return null;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }
  return const {};
}
