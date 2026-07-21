import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/story_detail.dart';

class StoryEndpoints {
  const StoryEndpoints._();

  static const catalogue = 'stories/';

  static String detail(String slug) => 'stories/${Uri.encodeComponent(slug)}/';
}

abstract interface class StoryApi {
  Future<List<StoryDetail>> fetchStories(
    String accessToken, {
    String? search,
    String? category,
  });

  Future<StoryDetail> fetchStory(String slug, String accessToken);
}

class HttpStoryApi implements StoryApi {
  HttpStoryApi({
    http.Client? client,
    this.baseUrl = AppConfig.apiBaseUrl,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration requestTimeout;

  @override
  Future<List<StoryDetail>> fetchStories(
    String accessToken, {
    String? search,
    String? category,
  }) async {
    final queryParameters = <String, String>{
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      if (category != null && category.trim().isNotEmpty)
        'category': category.trim(),
    };
    final response = await _get(
      StoryEndpoints.catalogue,
      accessToken,
      queryParameters: queryParameters,
    );
    final rawStories = response is List
        ? response
        : _mapFrom(response)['results'];
    if (rawStories is! List) {
      throw const AppException(
        'We could not read the story library yet.',
        code: 'invalid_story_catalogue',
      );
    }

    try {
      return rawStories
          .map((story) {
            final payload = _mapFrom(story);
            if (payload.isEmpty) {
              throw const FormatException('Story records must be objects.');
            }
            return StoryDetail.fromJson(payload);
          })
          .toList(growable: false);
    } on FormatException {
      throw const AppException(
        'The story library sent content this app cannot read yet.',
        code: 'invalid_story_catalogue',
      );
    }
  }

  @override
  Future<StoryDetail> fetchStory(String slug, String accessToken) async {
    final normalizedSlug = slug.trim();
    if (normalizedSlug.isEmpty) {
      throw const AppException(
        'We could not identify that story.',
        code: 'invalid_story_slug',
      );
    }
    final response = await _get(
      StoryEndpoints.detail(normalizedSlug),
      accessToken,
    );
    final story = _mapFrom(response);
    if (story.isEmpty) {
      throw const AppException(
        'We could not read that story yet.',
        code: 'invalid_story_detail',
      );
    }
    try {
      final detail = StoryDetail.fromJson(story);
      if (detail.slug != normalizedSlug) {
        throw const FormatException('Story slug did not match the request.');
      }
      return detail;
    } on FormatException {
      throw const AppException(
        'The story service sent an incomplete story. Please try again.',
        code: 'invalid_story_detail',
      );
    }
  }

  Future<Object?> _get(
    String path,
    String accessToken, {
    Map<String, String> queryParameters = const {},
  }) async {
    try {
      final response = await _client
          .get(
            _uri(path, queryParameters),
            headers: {
              'Accept': 'application/json',
              if (accessToken.isNotEmpty)
                'Authorization': 'Bearer $accessToken',
            },
          )
          .timeout(requestTimeout);
      return _decodeResponse(response);
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

  Object? _decodeResponse(http.Response response) {
    final payload = _decodePayload(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload;
    }

    final details = _mapFrom(payload);
    throw AppException(
      _messageFromError(details, response.statusCode),
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
        'The story service sent an unexpected response. Please try again.',
        code: 'invalid_story_response',
      );
    }
  }

  String _messageFromError(Map<String, dynamic> payload, int statusCode) {
    final detail = payload['detail'] ?? payload['message'] ?? payload['error'];
    if (detail is String && detail.trim().isNotEmpty) {
      return detail;
    }
    if (statusCode == 401) {
      return 'Please sign in as a parent to open the story library.';
    }
    if (statusCode == 404) {
      return 'That story is not available yet.';
    }
    return 'We could not load the stories. Please try again.';
  }
}

Map<String, dynamic> _mapFrom(Object? value) {
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
