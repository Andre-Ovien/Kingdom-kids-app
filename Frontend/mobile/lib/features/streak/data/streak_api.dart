import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../milestones/domain/level_milestone.dart';
import '../domain/streak_claim_receipt.dart';
import '../domain/streak_presentation.dart';

class StreakEndpoints {
  const StreakEndpoints._();

  static String claimPresentation(String profileId) =>
      'progress/kid-profiles/${Uri.encodeComponent(profileId)}/'
      'streak-presentations/claim/';
}

abstract interface class StreakApi {
  Future<StreakClaimReceipt> claimPresentation({
    required String accessToken,
    required String profileId,
    required int timezoneOffsetMinutes,
  });
}

class HttpStreakApi implements StreakApi {
  HttpStreakApi({
    http.Client? client,
    this.baseUrl = AppConfig.apiBaseUrl,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration requestTimeout;

  @override
  Future<StreakClaimReceipt> claimPresentation({
    required String accessToken,
    required String profileId,
    required int timezoneOffsetMinutes,
  }) async {
    final normalizedProfileId = profileId.trim();
    if (normalizedProfileId.isEmpty) {
      throw const AppException(
        'Choose a kid profile to see their streak.',
        code: 'active_kid_required',
      );
    }

    try {
      final response = await _client
          .post(
            AppConfig.resolveApiUri(
              StreakEndpoints.claimPresentation(normalizedProfileId),
              baseUrl: baseUrl,
            ),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              if (accessToken.isNotEmpty)
                'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode({
              'timezone_offset_minutes': timezoneOffsetMinutes.clamp(-840, 840),
            }),
          )
          .timeout(requestTimeout);
      final payload = _decode(response.body);
      if (response.statusCode != 200) {
        final details = _map(payload);
        throw AppException(
          _firstMessage(payload) ??
              (response.statusCode == 404
                  ? 'That kid profile is no longer available.'
                  : 'We could not check this streak yet.'),
          statusCode: response.statusCode,
          code: details['code']?.toString(),
          details: details,
        );
      }

      final responseBody = _map(payload);
      final shouldShow = responseBody['show'];
      if (shouldShow is! bool) {
        throw const AppException(
          'The streak service sent an incomplete response.',
          code: 'invalid_streak_response',
        );
      }
      final hasRewards =
          responseBody.containsKey('xp_awarded') ||
          responseBody.containsKey('level_milestone');
      if (hasRewards && responseBody['profile_id'] != normalizedProfileId) {
        throw const AppException(
          'The streak service returned rewards for the wrong child profile.',
          code: 'streak_response_mismatch',
        );
      }
      final rawXp = responseBody['xp_awarded'];
      if (rawXp != null && (rawXp is! int || rawXp < 0)) {
        throw const AppException(
          'The streak service sent an invalid reward.',
          code: 'invalid_streak_response',
        );
      }
      final xp = rawXp as int? ?? 0;
      final milestone = LevelMilestone.tryParse(
        responseBody['level_milestone'],
      );
      if (!shouldShow) {
        return StreakClaimReceipt(xpAwarded: xp, levelMilestone: milestone);
      }
      final presentation = _map(responseBody['presentation']);
      if (presentation.isEmpty) {
        throw const AppException(
          'The streak service sent an incomplete response.',
          code: 'invalid_streak_response',
        );
      }
      try {
        final parsed = StreakPresentation.fromJson(presentation);
        if (parsed.profile.id != normalizedProfileId) {
          throw const AppException(
            'The streak service returned progress for the wrong child profile.',
            code: 'streak_response_mismatch',
          );
        }
        return StreakClaimReceipt(
          presentation: parsed,
          xpAwarded: xp,
          levelMilestone: milestone,
        );
      } on FormatException {
        throw const AppException(
          'The streak service sent an incomplete response.',
          code: 'invalid_streak_response',
        );
      }
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to check this streak.',
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
        'The streak service sent an unexpected response.',
        code: 'invalid_streak_response',
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
