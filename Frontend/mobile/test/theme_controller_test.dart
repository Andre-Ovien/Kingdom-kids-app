import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme_controller.dart';

void main() {
  test(
    'initializes from the saved device theme and persists changes',
    () async {
      final store = MemoryThemePreferenceStore()..value = ThemeMode.dark;

      await AppThemeController.initialize(store: store);

      expect(AppThemeController.mode.value, ThemeMode.dark);
      await AppThemeController.setMode(ThemeMode.light);
      expect(AppThemeController.mode.value, ThemeMode.light);
      expect(store.value, ThemeMode.light);
    },
  );

  test('rolls the visible theme back when device persistence fails', () async {
    final store = _FailingThemePreferenceStore(saved: ThemeMode.dark);
    await AppThemeController.initialize(store: store);
    expect(AppThemeController.mode.value, ThemeMode.dark);

    await expectLater(
      AppThemeController.setMode(ThemeMode.light),
      throwsA(isA<StateError>()),
    );

    expect(AppThemeController.mode.value, ThemeMode.dark);
    expect(store.writeAttempts, [ThemeMode.light]);
  });

  test('serializes rapid theme changes in selection order', () async {
    final store = _ControlledThemePreferenceStore(saved: ThemeMode.system);
    await AppThemeController.initialize(store: store);

    final darkWrite = AppThemeController.setMode(ThemeMode.dark);
    final lightWrite = AppThemeController.setMode(ThemeMode.light);

    await store.waitForWriteCount(1);
    expect(store.writeAttempts, [ThemeMode.dark]);
    expect(store.activeWrites, 1);
    expect(AppThemeController.mode.value, ThemeMode.light);

    store.succeedWrite(0);
    await darkWrite;
    await store.waitForWriteCount(2);

    expect(store.writeAttempts, [ThemeMode.dark, ThemeMode.light]);
    expect(store.maxActiveWrites, 1);

    store.succeedWrite(1);
    await lightWrite;

    expect(AppThemeController.mode.value, ThemeMode.light);
  });

  test('rapid failed changes roll back to the last persisted theme', () async {
    final store = _ControlledThemePreferenceStore(saved: ThemeMode.dark);
    await AppThemeController.initialize(store: store);

    final lightWrite = AppThemeController.setMode(ThemeMode.light);
    final systemWrite = AppThemeController.setMode(ThemeMode.system);
    final lightFailure = expectLater(lightWrite, throwsA(isA<StateError>()));
    final systemFailure = expectLater(systemWrite, throwsA(isA<StateError>()));

    await store.waitForWriteCount(1);
    store.failWrite(0);
    await lightFailure;
    await store.waitForWriteCount(2);

    store.failWrite(1);
    await systemFailure;

    expect(store.writeAttempts, [ThemeMode.light, ThemeMode.system]);
    expect(store.maxActiveWrites, 1);
    expect(AppThemeController.mode.value, ThemeMode.dark);
  });
}

final class _FailingThemePreferenceStore implements ThemePreferenceStore {
  _FailingThemePreferenceStore({required this.saved});

  final ThemeMode saved;
  final List<ThemeMode> writeAttempts = [];

  @override
  Future<ThemeMode?> readThemeMode() async => saved;

  @override
  Future<void> writeThemeMode(ThemeMode mode) async {
    writeAttempts.add(mode);
    throw StateError('Device storage is unavailable.');
  }
}

final class _ControlledThemePreferenceStore implements ThemePreferenceStore {
  _ControlledThemePreferenceStore({required this.saved});

  final ThemeMode saved;
  final List<ThemeMode> writeAttempts = [];
  final List<Completer<void>> _writes = [];
  int activeWrites = 0;
  int maxActiveWrites = 0;

  @override
  Future<ThemeMode?> readThemeMode() async => saved;

  @override
  Future<void> writeThemeMode(ThemeMode mode) {
    writeAttempts.add(mode);
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;

    final write = Completer<void>();
    _writes.add(write);
    return write.future.whenComplete(() => activeWrites--);
  }

  Future<void> waitForWriteCount(int count) async {
    for (var attempt = 0; attempt < 20 && _writes.length < count; attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(_writes.length, count);
  }

  void succeedWrite(int index) => _writes[index].complete();

  void failWrite(int index) {
    _writes[index].completeError(StateError('Device storage is unavailable.'));
  }
}
