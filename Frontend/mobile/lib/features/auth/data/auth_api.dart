import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/auth_requests.dart';
import '../domain/auth_session.dart';
import '../domain/email_verification.dart';
import '../domain/kid_profile.dart';
import '../domain/parent_account.dart';

/// HTTP contract for the parent account and child-profile API.
///
/// Keeping these endpoints together makes it straightforward to align the
/// mobile app with the Django URLs as the backend is completed.
class AuthEndpoints {
  const AuthEndpoints._();

  static const register = 'accounts/register/';
  static const login = 'accounts/login/';
  static const verifyEmail = 'accounts/email-verification/confirm/';
  static const resendVerification = 'accounts/email-verification/resend/';
  static const refresh = 'accounts/token/refresh/';
  static const currentParent = 'accounts/me/';
  static const kidProfiles = 'accounts/kid-profiles/';
  static const logout = 'accounts/logout/';

  static String kidProfileDetail(String id) =>
      'accounts/kid-profiles/${Uri.encodeComponent(id)}/';
}

abstract interface class AuthApi {
  Future<PendingEmailVerification> register(RegisterParentRequest request);

  Future<AuthSession> login(LoginRequest request);

  Future<AuthSession> verifyEmail(VerifyEmailRequest request);

  Future<PendingEmailVerification> resendEmailVerification(String challengeId);

  Future<AuthSession> refresh(AuthSession session);

  Future<ParentAccount> currentParent(String accessToken);

  Future<List<KidProfile>> fetchKidProfiles(String accessToken);

  Future<KidProfile> createKidProfile(
    CreateKidProfileRequest request,
    String accessToken,
  );

  Future<KidProfile> retrieveKidProfile(String profileId, String accessToken);

  Future<KidProfile> updateKidProfile({
    required String profileId,
    required String displayName,
    required String avatarKey,
    required String accessToken,
  });

  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  });
}

/// A small REST adapter for the Django API. It owns no UI state and can be
/// replaced with a fake [AuthApi] in tests.
class HttpAuthApi implements AuthApi {
  HttpAuthApi({http.Client? client, this.baseUrl = AppConfig.apiBaseUrl})
    : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  static const _requestTimeout = Duration(seconds: 15);

  @override
  Future<PendingEmailVerification> register(
    RegisterParentRequest request,
  ) async {
    final response = await _post(
      AuthEndpoints.register,
      body: request.toJson(),
    );
    return _pendingVerificationFrom(response);
  }

  @override
  Future<AuthSession> login(LoginRequest request) async {
    final response = await _post(AuthEndpoints.login, body: request.toJson());
    return _sessionFrom(response);
  }

  @override
  Future<AuthSession> verifyEmail(VerifyEmailRequest request) async {
    final response = await _post(
      AuthEndpoints.verifyEmail,
      body: request.toJson(),
    );
    return _sessionFrom(response);
  }

  @override
  Future<PendingEmailVerification> resendEmailVerification(
    String challengeId,
  ) async {
    final response = await _post(
      AuthEndpoints.resendVerification,
      body: {'challenge_id': challengeId},
    );
    return _pendingVerificationFrom(response);
  }

  @override
  Future<AuthSession> refresh(AuthSession session) async {
    final refreshToken = session.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const AppException('Please sign in again to continue securely.');
    }
    final response = await _post(
      AuthEndpoints.refresh,
      body: {'refresh': refreshToken},
    );
    final accessToken = (response['access'] ?? response['access_token'] ?? '')
        .toString();
    if (accessToken.isEmpty) {
      throw const AppException('We could not refresh your secure session.');
    }
    return session.copyWith(
      accessToken: accessToken,
      refreshToken: (response['refresh'] ?? session.refreshToken)?.toString(),
    );
  }

  @override
  Future<ParentAccount> currentParent(String accessToken) async {
    final response = _mapFrom(
      await _get(AuthEndpoints.currentParent, accessToken),
    );
    final parent = _mapFrom(response['parent'] ?? response['user'] ?? response);
    return ParentAccount.fromJson(parent);
  }

  @override
  Future<List<KidProfile>> fetchKidProfiles(String accessToken) async {
    final response = await _get(AuthEndpoints.kidProfiles, accessToken);
    final rawProfiles = response is List
        ? response
        : _mapFrom(response)['profiles'] ??
              _mapFrom(response)['kid_profiles'] ??
              _mapFrom(response)['results'] ??
              const [];
    if (rawProfiles is! List) {
      throw const AppException('We could not read the child profiles yet.');
    }

    return rawProfiles
        .whereType<Map>()
        .map((profile) => KidProfile.fromJson(_mapFrom(profile)))
        .toList(growable: false);
  }

  @override
  Future<KidProfile> createKidProfile(
    CreateKidProfileRequest request,
    String accessToken,
  ) async {
    final response = await _post(
      AuthEndpoints.kidProfiles,
      body: request.toJson(),
      accessToken: accessToken,
    );
    return KidProfile.fromJson(_mapFrom(response['profile'] ?? response));
  }

  @override
  Future<KidProfile> retrieveKidProfile(
    String profileId,
    String accessToken,
  ) async {
    final response = await _get(
      AuthEndpoints.kidProfileDetail(profileId),
      accessToken,
    );
    return _kidProfileFrom(response, expectedId: profileId);
  }

  @override
  Future<KidProfile> updateKidProfile({
    required String profileId,
    required String displayName,
    required String avatarKey,
    required String accessToken,
  }) async {
    final response = await _patch(
      AuthEndpoints.kidProfileDetail(profileId),
      body: {
        'display_name': displayName.trim().split(RegExp(r'\s+')).join(' '),
        'avatar_key': avatarKey.trim(),
      },
      accessToken: accessToken,
    );
    return _kidProfileFrom(response, expectedId: profileId);
  }

  @override
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _post(
      AuthEndpoints.logout,
      body: {'refresh': refreshToken},
      accessToken: accessToken,
      allowEmptyResponse: true,
    );
  }

  Future<Object?> _get(String path, String accessToken) async {
    try {
      final response = await _client
          .get(_uri(path), headers: _headers(accessToken: accessToken))
          .timeout(_requestTimeout);
      return _decodeResponse(response);
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to respond. Please try again.',
        code: 'request_timeout',
      );
    } on http.ClientException {
      throw const AppException(
        'We could not reach Kingdom Kids. Check your connection and try again.',
      );
    }
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    required Map<String, dynamic> body,
    String? accessToken,
    bool allowEmptyResponse = false,
  }) async {
    try {
      final response = await _client
          .post(
            _uri(path),
            headers: _headers(accessToken: accessToken),
            body: jsonEncode(body),
          )
          .timeout(_requestTimeout);
      return _postResponse(
        _decodeResponse(response),
        allowEmptyResponse: allowEmptyResponse,
      );
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to respond. Please try again.',
        code: 'request_timeout',
      );
    } on http.ClientException {
      throw const AppException(
        'We could not reach Kingdom Kids. Check your connection and try again.',
      );
    }
  }

  Future<Map<String, dynamic>> _patch(
    String path, {
    required Map<String, dynamic> body,
    required String accessToken,
  }) async {
    try {
      final response = await _client
          .patch(
            _uri(path),
            headers: _headers(accessToken: accessToken),
            body: jsonEncode(body),
          )
          .timeout(_requestTimeout);
      return _postResponse(
        _decodeResponse(response),
        unexpectedResponseMessage:
            'Your profile was updated, but we could not read it back.',
      );
    } on TimeoutException {
      throw const AppException(
        'Kingdom Kids took too long to respond. Please try again.',
        code: 'request_timeout',
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

  Map<String, String> _headers({String? accessToken}) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (accessToken != null && accessToken.isNotEmpty)
      'Authorization': 'Bearer $accessToken',
  };

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
        'The service sent an unexpected response. Please try again.',
      );
    }
  }

  Map<String, dynamic> _postResponse(
    Object? value, {
    String? unexpectedResponseMessage,
    bool allowEmptyResponse = false,
  }) {
    final response = _mapFrom(value);
    if (response.isEmpty && !allowEmptyResponse) {
      throw AppException(
        unexpectedResponseMessage ??
            'The service sent an unexpected response. Please try again.',
      );
    }
    return response;
  }

  String _messageFromError(Map<String, dynamic> payload, int statusCode) {
    final detail = payload['detail'] ?? payload['message'] ?? payload['error'];
    if (detail is String && detail.trim().isNotEmpty) {
      return detail;
    }
    if (statusCode == 401) {
      return 'That email or password did not match our records.';
    }
    if (statusCode == 409) {
      return 'An account already exists with that email address.';
    }
    if (payload.isNotEmpty) {
      final firstValue = payload.values.first;
      if (firstValue is List && firstValue.isNotEmpty) {
        return firstValue.first.toString();
      }
      if (firstValue is String) {
        return firstValue;
      }
    }
    return 'Something went wrong. Please try again.';
  }

  AuthSession _sessionFrom(Map<String, dynamic> response) {
    final session = AuthSession.fromJson(response);
    if (session.accessToken.isEmpty || session.parent.id.isEmpty) {
      throw const AppException(
        'We accepted your account, but could not start a secure session.',
      );
    }
    return session;
  }

  PendingEmailVerification _pendingVerificationFrom(
    Map<String, dynamic> response,
  ) {
    final pending = PendingEmailVerification.fromJson(response);
    if (pending.challengeId.isEmpty || pending.email.isEmpty) {
      throw const AppException(
        'Your account was created, but the verification details were missing.',
      );
    }
    return pending;
  }

  KidProfile _kidProfileFrom(Object? value, {required String expectedId}) {
    final response = _mapFrom(value);
    final profile = KidProfile.fromJson(
      _mapFrom(response['profile'] ?? response),
    );
    if (profile.id.isEmpty || profile.id != expectedId) {
      throw const AppException(
        'The service returned the wrong child profile. Please try again.',
      );
    }
    return profile;
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
