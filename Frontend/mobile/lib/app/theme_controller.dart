import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class ThemePreferenceStore {
  Future<ThemeMode?> readThemeMode();

  Future<void> writeThemeMode(ThemeMode mode);
}

class SecureThemePreferenceStore implements ThemePreferenceStore {
  SecureThemePreferenceStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _themeModeKey = 'kingdom_kids.theme_mode';
  final FlutterSecureStorage _storage;

  @override
  Future<ThemeMode?> readThemeMode() async {
    final value = await _storage.read(key: _themeModeKey);
    return switch (value) {
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    };
  }

  @override
  Future<void> writeThemeMode(ThemeMode mode) {
    return _storage.write(key: _themeModeKey, value: mode.name);
  }
}

class MemoryThemePreferenceStore implements ThemePreferenceStore {
  ThemeMode? value;

  @override
  Future<ThemeMode?> readThemeMode() async => value;

  @override
  Future<void> writeThemeMode(ThemeMode mode) async {
    value = mode;
  }
}

class AppThemeController {
  const AppThemeController._();

  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);
  static ThemePreferenceStore _store = SecureThemePreferenceStore();
  static Future<void> _writeTail = Future.value();
  static int _writeRevision = 0;
  static int _storeGeneration = 0;
  static ThemeMode _persistedMode = ThemeMode.system;

  static bool get darkModeEnabled => mode.value == ThemeMode.dark;

  static Future<void> initialize({ThemePreferenceStore? store}) async {
    if (store != null) {
      _store = store;
      _writeTail = Future.value();
      _writeRevision = 0;
      _storeGeneration++;
    }
    final generation = _storeGeneration;
    try {
      final savedMode = await _store.readThemeMode();
      if (generation != _storeGeneration) return;
      _persistedMode = savedMode ?? mode.value;
      if (savedMode != null) mode.value = savedMode;
    } catch (_) {
      // Appearance is non-critical. The operating-system theme remains a safe
      // fallback if device storage is temporarily unavailable.
    }
  }

  static Future<void> setMode(ThemeMode selectedMode) {
    final revision = ++_writeRevision;
    final generation = _storeGeneration;
    final store = _store;
    final result = Completer<void>();
    mode.value = selectedMode;

    _writeTail = _writeTail.then((_) async {
      try {
        await store.writeThemeMode(selectedMode);
        if (_storeGeneration == generation) {
          _persistedMode = selectedMode;
        }
        result.complete();
      } catch (error, stackTrace) {
        if (_storeGeneration == generation && _writeRevision == revision) {
          mode.value = _persistedMode;
        }
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  static void setDarkMode(bool enabled) {
    unawaited(
      setMode(
        enabled ? ThemeMode.dark : ThemeMode.light,
      ).catchError((Object _) {}),
    );
  }
}
