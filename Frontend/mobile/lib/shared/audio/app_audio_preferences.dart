import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/storage/secure_storage.dart';

abstract interface class AppAudioPreferenceStore {
  Future<bool?> readMusicEnabled();
  Future<bool?> readEffectsEnabled();
  Future<void> writeMusicEnabled(bool enabled);
  Future<void> writeEffectsEnabled(bool enabled);
}

/// Independent of profiles and authentication; these keys contain no identity.
class SecureAppAudioPreferenceStore implements AppAudioPreferenceStore {
  SecureAppAudioPreferenceStore({FlutterSecureStorage? storage})
    : _storage = storage ?? kingdomKidsSecureStorage;

  static const musicKey = 'kingdom_kids.app_music_enabled';
  static const effectsKey = 'kingdom_kids.app_effects_enabled';
  final FlutterSecureStorage _storage;

  Future<bool?> _read(String key) async =>
      switch (await _storage.read(key: key)) {
        'true' => true,
        'false' => false,
        _ => null,
      };

  @override
  Future<bool?> readMusicEnabled() => _read(musicKey);
  @override
  Future<bool?> readEffectsEnabled() => _read(effectsKey);
  @override
  Future<void> writeMusicEnabled(bool enabled) =>
      _storage.write(key: musicKey, value: enabled.toString());
  @override
  Future<void> writeEffectsEnabled(bool enabled) =>
      _storage.write(key: effectsKey, value: enabled.toString());
}
