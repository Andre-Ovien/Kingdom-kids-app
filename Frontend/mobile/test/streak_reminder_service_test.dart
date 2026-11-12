import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/streak/data/streak_reminder_service.dart';

void main() {
  const profile = KidProfile(
    id: 'kid-1',
    parentId: 'parent-1',
    displayName: 'Maya',
    avatarKey: 'dove',
  );

  test('enabling schedules one reminder for 5 PM tomorrow', () async {
    final store = MemoryStreakReminderPreferenceStore();
    final gateway = _FakeStreakNotificationGateway(permissionGranted: true);
    final service = DeviceStreakReminderService(
      preferenceStore: store,
      notificationGateway: gateway,
      now: () => DateTime(2026, 7, 25, 9, 30),
    );

    expect(await service.enable(profile: profile), isTrue);

    expect(store.enabled, isTrue);
    expect(gateway.permissionRequests, 1);
    expect(gateway.cancelCalls, 1);
    expect(gateway.scheduledAt, [DateTime(2026, 7, 26, 17)]);
    expect(gateway.titles.single, 'Keep the streak glowing 🔥');
    expect(
      gateway.bodies.single,
      'Open Kingdom Kids today to keep the adventure going.',
    );
  });

  test('denied permission leaves reminders disabled', () async {
    final store = MemoryStreakReminderPreferenceStore(enabled: true);
    final gateway = _FakeStreakNotificationGateway(permissionGranted: false);
    final service = DeviceStreakReminderService(
      preferenceStore: store,
      notificationGateway: gateway,
    );

    expect(await service.enable(profile: profile), isFalse);

    expect(store.enabled, isFalse);
    expect(gateway.cancelCalls, 0);
    expect(gateway.scheduledAt, isEmpty);
  });

  test(
    'opening the app cancels today and moves the reminder forward',
    () async {
      final store = MemoryStreakReminderPreferenceStore(enabled: true);
      final gateway = _FakeStreakNotificationGateway(permissionGranted: true);
      final service = DeviceStreakReminderService(
        preferenceStore: store,
        notificationGateway: gateway,
        now: () => DateTime(2026, 7, 26, 16, 59),
      );

      await service.refreshAfterAppOpen(profile: profile);

      expect(gateway.cancelCalls, 1);
      expect(gateway.scheduledAt, [DateTime(2026, 7, 27, 17)]);
    },
  );

  test('opening the app does nothing when reminders are off', () async {
    final gateway = _FakeStreakNotificationGateway(permissionGranted: true);
    final service = DeviceStreakReminderService(
      preferenceStore: MemoryStreakReminderPreferenceStore(),
      notificationGateway: gateway,
    );

    await service.refreshAfterAppOpen(profile: profile);

    expect(gateway.cancelCalls, 0);
    expect(gateway.scheduledAt, isEmpty);
  });

  test('disabling cancels the pending reminder', () async {
    final store = MemoryStreakReminderPreferenceStore(enabled: true);
    final gateway = _FakeStreakNotificationGateway(permissionGranted: true);
    final service = DeviceStreakReminderService(
      preferenceStore: store,
      notificationGateway: gateway,
    );

    await service.disable();

    expect(store.enabled, isFalse);
    expect(gateway.cancelCalls, 1);
  });
}

final class _FakeStreakNotificationGateway
    implements StreakNotificationGateway {
  _FakeStreakNotificationGateway({required this.permissionGranted});

  final bool permissionGranted;
  int permissionRequests = 0;
  int cancelCalls = 0;
  final List<DateTime> scheduledAt = [];
  final List<String> titles = [];
  final List<String> bodies = [];

  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    return permissionGranted;
  }

  @override
  Future<void> cancelReminder() async {
    cancelCalls += 1;
  }

  @override
  Future<void> scheduleReminder({
    required DateTime scheduledAt,
    required String title,
    required String body,
  }) async {
    this.scheduledAt.add(scheduledAt);
    titles.add(title);
    bodies.add(body);
  }
}
