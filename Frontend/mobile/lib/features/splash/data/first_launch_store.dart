import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage/secure_storage.dart';

/// Stores whether this installation has already shown its one-time welcome.
///
/// This is deliberately separate from authentication. Signing out should not
/// make a returning family repeat onboarding, while clearing the app's local
/// data should make the installation new again.
abstract interface class FirstLaunchStore {
  Future<bool> hasLaunchedBefore();

  Future<void> markLaunched();
}

class SecureFirstLaunchStore implements FirstLaunchStore {
  SecureFirstLaunchStore({FlutterSecureStorage? storage})
    : _storage = storage ?? kingdomKidsSecureStorage;

  static const _launchedKey = 'kingdom_kids.has_launched';
  static const _launchedValue = '1';

  final FlutterSecureStorage _storage;

  @override
  Future<bool> hasLaunchedBefore() async {
    return await _storage.read(key: _launchedKey) == _launchedValue;
  }

  @override
  Future<void> markLaunched() {
    return _storage.write(key: _launchedKey, value: _launchedValue);
  }
}

class MemoryFirstLaunchStore implements FirstLaunchStore {
  MemoryFirstLaunchStore({this.launched = false});

  bool launched;

  @override
  Future<bool> hasLaunchedBefore() async => launched;

  @override
  Future<void> markLaunched() async {
    launched = true;
  }
}
