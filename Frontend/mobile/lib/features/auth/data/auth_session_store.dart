import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/app_config.dart';
import '../../../core/storage/secure_storage.dart';
import '../domain/auth_session.dart';

abstract interface class AuthSessionStore {
  Future<AuthSession?> readSession();

  Future<void> writeSession(AuthSession session);

  Future<String?> readSelectedKidId();

  Future<void> writeSelectedKidId(String kidId);

  Future<void> clearSelectedKidId();

  Future<void> clear();
}

/// Persists tokens and the small amount of profile metadata required to restore
/// the account shell. Tokens are never stored in regular preferences.
class SecureAuthSessionStore implements AuthSessionStore {
  SecureAuthSessionStore({
    FlutterSecureStorage? storage,
    String apiBaseUrl = AppConfig.apiBaseUrl,
  }) : _storage = storage ?? kingdomKidsSecureStorage,
       _scope = _apiStorageScope(apiBaseUrl);

  final FlutterSecureStorage _storage;
  final String _scope;

  // Old, unbound keys are deliberately neither read nor deleted. Their backend
  // cannot be proven, so a new host requires its own parent sign-in. Returning
  // to the older build can still restore those untouched local credentials.
  String get _sessionKey => 'kingdom_kids.auth_session.v2.$_scope';
  String get _selectedKidKey => 'kingdom_kids.selected_kid_id.v2.$_scope';

  @override
  Future<AuthSession?> readSession() async {
    final encoded = await _storage.read(key: _sessionKey);
    if (encoded == null || encoded.isEmpty) {
      return null;
    }

    try {
      final value = jsonDecode(encoded);
      if (value is! Map) {
        return null;
      }
      return AuthSession.fromJson(
        value.map((key, nestedValue) => MapEntry(key.toString(), nestedValue)),
      );
    } on FormatException {
      await clear();
      return null;
    }
  }

  @override
  Future<void> writeSession(AuthSession session) {
    return _storage.write(
      key: _sessionKey,
      value: jsonEncode(session.toJson()),
    );
  }

  @override
  Future<String?> readSelectedKidId() => _storage.read(key: _selectedKidKey);

  @override
  Future<void> writeSelectedKidId(String kidId) {
    return _storage.write(key: _selectedKidKey, value: kidId);
  }

  @override
  Future<void> clearSelectedKidId() {
    return _storage.delete(key: _selectedKidKey);
  }

  @override
  Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _sessionKey),
      _storage.delete(key: _selectedKidKey),
    ]);
  }
}

/// Simple in-memory storage for repository and widget tests.
class MemoryAuthSessionStore implements AuthSessionStore {
  AuthSession? _session;
  String? _selectedKidId;

  @override
  Future<AuthSession?> readSession() async => _session;

  @override
  Future<void> writeSession(AuthSession session) async {
    _session = session;
  }

  @override
  Future<String?> readSelectedKidId() async => _selectedKidId;

  @override
  Future<void> writeSelectedKidId(String kidId) async {
    _selectedKidId = kidId;
  }

  @override
  Future<void> clearSelectedKidId() async {
    _selectedKidId = null;
  }

  @override
  Future<void> clear() async {
    _session = null;
    _selectedKidId = null;
  }
}

// Include the API prefix as well as scheme/host/port: distinct deployments can
// share a hostname. Base64url encodes public configuration, never a token.
String _apiStorageScope(String baseUrl) {
  final api = AppConfig.resolveApiUri('', baseUrl: baseUrl);
  final scheme = api.scheme.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  final canonical = Uri(
    scheme: scheme,
    host: api.host.toLowerCase(),
    port: api.port == defaultPort ? null : api.port,
    path: api.path,
  );
  return base64Url
      .encode(utf8.encode(canonical.toString()))
      .replaceAll('=', '');
}
