import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage/secure_storage.dart';

abstract interface class LevelMilestoneStore {
  Future<int> highestPresentedLevel(String profileId);

  Future<void> markPresented(String profileId, int level);
}

/// A separate, monotonic watermark for each child. Existing levels are not
/// celebrations: only a server-confirmed increase can open the milestone page.
class SecureLevelMilestoneStore implements LevelMilestoneStore {
  SecureLevelMilestoneStore({FlutterSecureStorage? storage})
    : _storage = storage ?? kingdomKidsSecureStorage;

  final FlutterSecureStorage _storage;
  static final Map<String, int> _sessionLevels = {};
  static final Map<String, Future<void>> _writes = {};

  String _key(String profileId) => 'kingdom_kids.level_milestone.$profileId';

  @override
  Future<int> highestPresentedLevel(String profileId) async {
    var highest = _sessionLevels[profileId] ?? 0;
    try {
      final saved = int.tryParse(
        await _storage.read(key: _key(profileId)) ?? '',
      );
      highest = math.max(highest, saved ?? 0);
    } catch (_) {
      // A celebration must not turn a saved quest into a save failure.
    }
    highest = math.max(highest, _sessionLevels[profileId] ?? 0);
    _sessionLevels[profileId] = highest;
    return highest;
  }

  @override
  Future<void> markPresented(String profileId, int level) {
    _sessionLevels[profileId] = math.max(_sessionLevels[profileId] ?? 0, level);
    final previous = _writes[profileId] ?? Future<void>.value();
    final next = previous.then((_) async {
      final highest = math.max(await highestPresentedLevel(profileId), level);
      _sessionLevels[profileId] = highest;
      try {
        await _storage.write(key: _key(profileId), value: '$highest');
      } catch (_) {
        // The process-local watermark still prevents repeated celebrations.
      }
    });
    _writes[profileId] = next;
    return next;
  }
}

class MemoryLevelMilestoneStore implements LevelMilestoneStore {
  MemoryLevelMilestoneStore({Map<String, int>? levels})
    : _levels = Map.of(levels ?? const {});

  final Map<String, int> _levels;

  @override
  Future<int> highestPresentedLevel(String profileId) async =>
      _levels[profileId] ?? 0;

  @override
  Future<void> markPresented(String profileId, int level) async {
    _levels[profileId] = math.max(_levels[profileId] ?? 0, level);
  }
}
