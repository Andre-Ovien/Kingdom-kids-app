import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import '../../../core/storage/secure_storage.dart';
import '../../auth/domain/kid_profile.dart';

const streakReminderHour = 17;

abstract interface class StreakReminderService {
  Future<bool> isEnabled();

  Future<bool> enable({required KidProfile profile});

  Future<void> disable();

  Future<void> refreshAfterAppOpen({required KidProfile profile});
}

abstract interface class StreakReminderPreferenceStore {
  Future<bool> readEnabled();

  Future<void> writeEnabled(bool enabled);
}

class SecureStreakReminderPreferenceStore
    implements StreakReminderPreferenceStore {
  SecureStreakReminderPreferenceStore({FlutterSecureStorage? storage})
    : _storage = storage ?? kingdomKidsSecureStorage;

  static const _enabledKey = 'kingdom_kids.streak_reminders_enabled';
  final FlutterSecureStorage _storage;

  @override
  Future<bool> readEnabled() async {
    return await _storage.read(key: _enabledKey) == 'true';
  }

  @override
  Future<void> writeEnabled(bool enabled) {
    return _storage.write(key: _enabledKey, value: enabled.toString());
  }
}

class MemoryStreakReminderPreferenceStore
    implements StreakReminderPreferenceStore {
  MemoryStreakReminderPreferenceStore({this.enabled = false});

  bool enabled;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool enabled) async {
    this.enabled = enabled;
  }
}

abstract interface class StreakNotificationGateway {
  Future<bool> requestPermission();

  Future<void> cancelReminder();

  Future<void> scheduleReminder({
    required DateTime scheduledAt,
    required String title,
    required String body,
  });
}

class LocalStreakNotificationGateway implements StreakNotificationGateway {
  LocalStreakNotificationGateway({
    FlutterLocalNotificationsPlugin? notifications,
  }) : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const _notificationId = 517;
  static const _channelId = 'kingdom_kids_streak_reminders';
  static const _channelName = 'Streak reminders';
  static const _channelDescription =
      'A gentle reminder when today’s Kingdom Kids streak has not started.';

  final FlutterLocalNotificationsPlugin _notifications;
  Future<void>? _initialization;

  Future<void> _initialize() {
    return _initialization ??= _performInitialization();
  }

  Future<void> _performInitialization() async {
    timezone_data.initializeTimeZones();
    try {
      final deviceTimezone = await FlutterTimezone.getLocalTimezone();
      timezone.setLocalLocation(
        timezone.getLocation(deviceTimezone.identifier),
      );
    } catch (_) {
      // UTC is a safe fallback. The service still schedules exactly one
      // reminder and will retry the device zone on the next process launch.
      timezone.setLocalLocation(timezone.UTC);
    }

    const android = AndroidInitializationSettings('ic_notification');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _notifications.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
    );
  }

  @override
  Future<bool> requestPermission() async {
    await _initialize();
    final androidResult = await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    final iosResult = await _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: false, sound: true);
    return androidResult ?? iosResult ?? true;
  }

  @override
  Future<void> cancelReminder() async {
    await _initialize();
    await _notifications.cancel(id: _notificationId);
  }

  @override
  Future<void> scheduleReminder({
    required DateTime scheduledAt,
    required String title,
    required String body,
  }) async {
    await _initialize();
    final zonedDate = timezone.TZDateTime(
      timezone.local,
      scheduledAt.year,
      scheduledAt.month,
      scheduledAt.day,
      scheduledAt.hour,
      scheduledAt.minute,
    );
    await _notifications.zonedSchedule(
      id: _notificationId,
      title: title,
      body: body,
      scheduledDate: zonedDate,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          icon: 'ic_notification',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          threadIdentifier: 'kingdom_kids_streak',
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'streak-reminder',
    );
  }
}

class DeviceStreakReminderService implements StreakReminderService {
  DeviceStreakReminderService({
    StreakReminderPreferenceStore? preferenceStore,
    StreakNotificationGateway? notificationGateway,
    DateTime Function()? now,
  }) : _preferenceStore =
           preferenceStore ?? SecureStreakReminderPreferenceStore(),
       _notificationGateway =
           notificationGateway ?? LocalStreakNotificationGateway(),
       _now = now ?? DateTime.now;

  static const _title = 'Keep the streak glowing 🔥';
  static const _body = 'Open Kingdom Kids today to keep the adventure going.';

  final StreakReminderPreferenceStore _preferenceStore;
  final StreakNotificationGateway _notificationGateway;
  final DateTime Function() _now;

  @override
  Future<bool> isEnabled() => _preferenceStore.readEnabled();

  @override
  Future<bool> enable({required KidProfile profile}) async {
    final granted = await _notificationGateway.requestPermission();
    if (!granted) {
      await _preferenceStore.writeEnabled(false);
      return false;
    }
    await _preferenceStore.writeEnabled(true);
    await _replaceReminder();
    return true;
  }

  @override
  Future<void> disable() async {
    await _preferenceStore.writeEnabled(false);
    await _notificationGateway.cancelReminder();
  }

  @override
  Future<void> refreshAfterAppOpen({required KidProfile profile}) async {
    if (!await _preferenceStore.readEnabled()) return;
    await _replaceReminder();
  }

  Future<void> _replaceReminder() async {
    await _notificationGateway.cancelReminder();
    await _notificationGateway.scheduleReminder(
      scheduledAt: _nextReminderAfter(_now()),
      title: _title,
      body: _body,
    );
  }
}

DateTime _nextReminderAfter(DateTime now) {
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  return DateTime(
    tomorrow.year,
    tomorrow.month,
    tomorrow.day,
    streakReminderHour,
  );
}
