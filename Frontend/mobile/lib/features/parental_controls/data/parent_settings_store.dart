import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage/secure_storage.dart';
import '../domain/parent_settings.dart';

/// Stores the last server-confirmed reading preferences for each kid profile.
abstract interface class ParentSettingsStore {
  Future<ParentSettings?> readSettings({required String profileId});

  Future<void> writeSettings(ParentSettings settings);

  /// Removes every cached parent preference owned by Kingdom Kids without
  /// touching unrelated values in the platform credential store.
  Future<void> purgeAll();
}

/// Keeps reading preferences in the platform's encrypted credential storage.
class SecureParentSettingsStore implements ParentSettingsStore {
  SecureParentSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? kingdomKidsSecureStorage;

  static const _keyPrefix = 'kingdom_kids.parent_settings.';

  final FlutterSecureStorage _storage;

  @override
  Future<ParentSettings?> readSettings({required String profileId}) async {
    final normalizedProfileId = profileId.trim();
    if (normalizedProfileId.isEmpty) return null;

    final encoded = await _storage.read(key: _key(normalizedProfileId));
    if (encoded == null || encoded.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final settings = ParentSettings.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      return settings.profileId == normalizedProfileId ? settings : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeSettings(ParentSettings settings) {
    return _storage.write(
      key: _key(settings.profileId),
      value: jsonEncode(settings.toJson()),
    );
  }

  @override
  Future<void> purgeAll() async {
    final values = await _storage.readAll();
    final ownedKeys = values.keys
        .where((key) => key.startsWith(_keyPrefix))
        .toList(growable: false);
    await Future.wait(ownedKeys.map((key) => _storage.delete(key: key)));
  }

  String _key(String profileId) {
    final encodedProfileId = base64Url.encode(utf8.encode(profileId));
    return '$_keyPrefix$encodedProfileId';
  }
}

/// Deterministic in-memory storage for repository and widget tests.
class MemoryParentSettingsStore implements ParentSettingsStore {
  MemoryParentSettingsStore({
    Map<String, ParentSettings> initialSettings = const {},
  }) : _settings = Map.of(initialSettings);

  final Map<String, ParentSettings> _settings;

  @override
  Future<ParentSettings?> readSettings({required String profileId}) async {
    return _settings[profileId.trim()];
  }

  @override
  Future<void> writeSettings(ParentSettings settings) async {
    _settings[settings.profileId] = settings;
  }

  @override
  Future<void> purgeAll() async {
    _settings.clear();
  }
}
