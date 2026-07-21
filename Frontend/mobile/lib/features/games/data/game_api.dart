import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/mini_game.dart';

class GameEndpoints {
  const GameEndpoints._();

  static const catalogue = 'games/';

  static String detail(String slug) => 'games/${Uri.encodeComponent(slug)}/';

  static String submit(String slug) =>
      'games/${Uri.encodeComponent(slug)}/submit/';
}

abstract interface class GameApi {
  Future<List<MiniGame>> fetchGames(
    String accessToken, {
    required String profileId,
  });

  Future<MiniGame> fetchGame(
    String slug,
    String accessToken, {
    required String profileId,
  });

  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
    required String accessToken,
  });
}

class HttpGameApi implements GameApi {
  HttpGameApi({
    http.Client? client,
    this.baseUrl = AppConfig.apiBaseUrl,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration requestTimeout;

  @override
  Future<List<MiniGame>> fetchGames(
    String accessToken, {
    required String profileId,
  }) async {
    _requireProfileId(profileId);
    final payload = await _request(
      'GET',
      GameEndpoints.catalogue,
      accessToken,
      queryParameters: {'profile_id': profileId.trim()},
    );
    final rawGames = payload is List ? payload : _asMap(payload)['results'];
    if (rawGames is! List) {
      throw const AppException(
        'We could not read the game library yet.',
        code: 'invalid_game_catalogue',
      );
    }

    try {
      return rawGames
          .whereType<Map>()
          .map((game) => MiniGame.fromJson(_asMap(game)))
          .toList(growable: false);
    } on FormatException {
      throw const AppException(
        'The game library sent content this app cannot play yet.',
        code: 'invalid_game_catalogue',
      );
    }
  }

  @override
  Future<MiniGame> fetchGame(
    String slug,
    String accessToken, {
    required String profileId,
  }) async {
    final normalizedSlug = _requireSlug(slug);
    _requireProfileId(profileId);
    final payload = await _request(
      'GET',
      GameEndpoints.detail(normalizedSlug),
      accessToken,
      queryParameters: {'profile_id': profileId.trim()},
    );
    final rawGame = _asMap(payload);
    if (rawGame.isEmpty) {
      throw const AppException(
        'We could not prepare that game yet.',
        code: 'invalid_game_detail',
      );
    }

    try {
      return MiniGame.fromJson(rawGame);
    } on FormatException {
      throw const AppException(
        'This game contains a level this app cannot play yet.',
        code: 'invalid_game_detail',
      );
    }
  }

  @override
  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
    required String accessToken,
  }) async {
    final normalizedSlug = _requireSlug(slug);
    _requireProfileId(profileId);
    if (levelNumber < 1) {
      throw const AppException(
        'We could not identify that game level.',
        code: 'invalid_game_level',
      );
    }
    if (operationId.trim().isEmpty) {
      throw const AppException(
        'We could not safely save that game attempt.',
        code: 'invalid_operation_id',
      );
    }

    final payload = await _request(
      'POST',
      GameEndpoints.submit(normalizedSlug),
      accessToken,
      body: {
        'profile_id': profileId.trim(),
        'level_number': levelNumber,
        'operation_id': operationId.trim(),
        'result': result,
      },
    );
    final rawSubmission = _asMap(payload);
    if (rawSubmission.isEmpty) {
      throw const AppException(
        'Your result was saved, but we could not read the reward.',
        code: 'invalid_game_submission',
      );
    }
    return GameSubmission.fromJson(rawSubmission);
  }

  Future<Object?> _request(
    String method,
    String path,
    String accessToken, {
    Map<String, String> queryParameters = const {},
    Map<String, dynamic>? body,
  }) async {
    try {
      final uri = _uri(path, queryParameters);
      final headers = {
        'Accept': 'application/json',
        if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
        if (body != null) 'Content-Type': 'application/json',
      };
      final future = switch (method) {
        'POST' => _client.post(uri, headers: headers, body: jsonEncode(body)),
        _ => _client.get(uri, headers: headers),
      };
      final response = await future.timeout(requestTimeout);
      return _decodeResponse(response, isGameAction: method == 'POST');
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to respond. Please try again.',
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

  Uri _uri(String path, Map<String, String> queryParameters) {
    return AppConfig.resolveApiUri(
      path,
      baseUrl: baseUrl,
      queryParameters: queryParameters,
    );
  }

  Object? _decodeResponse(
    http.Response response, {
    required bool isGameAction,
  }) {
    final payload = _decodePayload(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload;
    }

    final details = _asMap(payload);
    throw AppException(
      _messageFromError(
        payload,
        response.statusCode,
        isGameAction: isGameAction,
      ),
      code: details['code']?.toString(),
      statusCode: response.statusCode,
      details: details,
    );
  }

  Object? _decodePayload(String body) {
    if (body.trim().isEmpty) {
      return const {};
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const AppException(
        'The game service sent an unexpected response. Please try again.',
        code: 'invalid_game_response',
      );
    }
  }

  String _messageFromError(
    Object? payload,
    int statusCode, {
    required bool isGameAction,
  }) {
    final message = _firstErrorMessage(payload);
    if (message != null) return message;
    if (statusCode == 401) {
      return 'Please sign in as a parent to open the game library.';
    }
    if (statusCode == 404) {
      return 'That game or kid profile is not available.';
    }
    if (statusCode == 409) {
      return 'That game result changed while saving. Please start a new round.';
    }
    if (isGameAction) {
      return 'We could not save this try. Please try again.';
    }
    return 'We could not load the games. Please try again.';
  }
}

String? _firstErrorMessage(Object? value) {
  if (value is String) {
    final message = value.trim();
    return message.isEmpty ? null : message;
  }
  if (value is List) {
    for (final item in value) {
      final message = _firstErrorMessage(item);
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
      final message = _firstErrorMessage(value[key]);
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
      final message = _firstErrorMessage(entry.value);
      if (message != null) return message;
    }
  }
  return null;
}

String _requireSlug(String slug) {
  final normalized = slug.trim();
  if (normalized.isEmpty) {
    throw const AppException(
      'We could not identify that game.',
      code: 'invalid_game_slug',
    );
  }
  return normalized;
}

void _requireProfileId(String profileId) {
  if (profileId.trim().isEmpty) {
    throw const AppException(
      'Choose a kid profile before playing.',
      code: 'active_kid_required',
    );
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }
  return const {};
}
