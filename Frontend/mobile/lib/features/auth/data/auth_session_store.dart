import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  SecureAuthSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _sessionKey = 'kingdom_kids.auth_session';
  static const _selectedKidKey = 'kingdom_kids.selected_kid_id';

  final FlutterSecureStorage _storage;

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
