import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/constants/app_constants.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_api.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/data/parent_settings_store.dart';
import 'package:mobile/features/parental_controls/domain/parent_settings.dart';
import 'package:mobile/features/parental_controls/presentation/parental_controls_screen.dart';
import 'package:mobile/features/streak/data/streak_reminder_service.dart';

void main() {
  testWidgets('renders live parent, profile, and backend preferences', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-live-hero')), findsOneWidget);
    expect(find.text('Backend Maya'), findsWidgets);
    expect(find.text('parent@example.com'), findsOneWidget);
    expect(find.text('Comfortable'), findsOneWidget);
    expect(find.text('Read-aloud voices are available'), findsOneWidget);
    expect(find.text('1 profile in this family'), findsOneWidget);

    expect(find.text('Ethan'), findsNothing);
    expect(find.text('Bedtime glow'), findsNothing);
    expect(find.text('Auto-play videos'), findsNothing);
    expect(find.text('Parent gate'), findsNothing);
    expect(find.text('Notifications'), findsNothing);
    expect(find.text('Offline stories'), findsNothing);

    final getRequests = harness.requests
        .where((request) => request.method == 'GET')
        .toList(growable: false);
    expect(getRequests.map((request) => request.url.path), [
      '/api/accounts/me/',
      '/api/accounts/kid-profiles/',
      '/api/accounts/kid-profiles/kid-1/preferences/',
    ]);
    expect(
      getRequests.every(
        (request) => request.headers['authorization'] == 'Bearer access-token',
      ),
      isTrue,
    );
  });

  testWidgets('keeps cached settings usable and retries a GET failure', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create(meFailuresRemaining: 1);

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings-account-sync-error')),
      findsOneWidget,
    );
    expect(
      find.text(
        'Kingdom Kids is having trouble right now. Please try again soon.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-live-hero')), findsOneWidget);
    expect(find.text('cached@example.com'), findsOneWidget);
    expect(find.byKey(const Key('settings-theme')), findsNothing);
    expect(find.text('App appearance'), findsNothing);
    expect(find.byKey(const Key('settings-sign-out')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-account-retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-account-sync-error')), findsNothing);
    expect(find.byKey(const Key('settings-live-hero')), findsOneWidget);
    expect(find.text('Backend Maya'), findsWidgets);
    expect(harness.meCalls, 2);
  });

  testWidgets('PATCHes narration off and the selected story text scale', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('settings-scroll')),
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-narration')));
    await tester.pumpAndSettle();

    var patches = harness.requests
        .where((request) => request.method == 'PATCH')
        .toList(growable: false);
    expect(patches, hasLength(1));
    expect(
      patches.single.url.path,
      '/api/accounts/kid-profiles/kid-1/preferences/',
    );
    expect(patches.single.headers['authorization'], 'Bearer access-token');
    expect(jsonDecode(patches.single.body), {'narration_enabled': false});
    expect(find.text('Read-aloud voices are turned off'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-text-size')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-choice-Extra large')));
    await tester.pumpAndSettle();

    patches = harness.requests
        .where((request) => request.method == 'PATCH')
        .toList(growable: false);
    expect(patches, hasLength(2));
    expect(jsonDecode(patches.last.body), {'story_text_scale': 'extra_large'});
    expect(find.text('Extra large'), findsOneWidget);
  });

  testWidgets('enables the 5 PM missed-open reminder from parent settings', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('Off — no daily streak reminders'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('settings-streak-reminders')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-streak-reminders')));
    await tester.pumpAndSettle();

    expect(harness.streakReminderService.enableCalls, 1);
    expect(harness.streakReminderService.lastProfile?.id, 'kid-1');
    expect(
      find.text('At 5:00 PM only when today’s app visit is still missing'),
      findsOneWidget,
    );
    expect(
      find.textContaining('only when today’s app visit is still missing'),
      findsWidgets,
    );

    await tester.ensureVisible(
      find.byKey(const Key('settings-streak-reminders')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-streak-reminders')));
    await tester.pumpAndSettle();

    expect(harness.streakReminderService.disableCalls, 1);
    expect(find.text('Off — no daily streak reminders'), findsOneWidget);
  });

  testWidgets('signs out through the authenticated API and clears the device', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('settings-scroll')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await tester.pumpAndSettle();

    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-confirm-sign-out')));
    await tester.pumpAndSettle();

    final logout = harness.requests.singleWhere(
      (request) =>
          request.method == 'POST' &&
          request.url.path == '/api/accounts/logout/',
    );
    expect(logout.headers['authorization'], 'Bearer access-token');
    expect(jsonDecode(logout.body), {'refresh': 'refresh-token'});
    expect(await harness.store.readSession(), isNull);
    expect(await harness.store.readSelectedKidId(), isNull);
    expect(harness.routedNames.last, '/auth/login');
    expect(find.text('Route: /auth/login'), findsOneWidget);
  });

  testWidgets('opens the public privacy policy from parent settings', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('settings-privacy-policy')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-privacy-policy')));
    await tester.pumpAndSettle();

    expect(harness.launchedUris, [Uri.parse(AppConstants.privacyPolicyUrl)]);
  });

  testWidgets(
    'permanent deletion reauthenticates, purges local data, and removes history',
    (tester) async {
      final harness = await _SettingsHarness.create();
      harness.streakReminderService.enabled = true;

      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      expect(
        await harness.parentSettingsStore.readSettings(profileId: 'kid-1'),
        isNotNull,
      );

      await tester.ensureVisible(
        find.byKey(const Key('settings-delete-account')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-delete-account')));
      await tester.pumpAndSettle();

      expect(find.text('Permanently delete family account?'), findsOneWidget);
      expect(find.textContaining('This cannot be undone.'), findsOneWidget);
      expect(find.text('Current password'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('settings-delete-password')),
        'correct current password',
      );
      await tester.tap(
        find.byKey(const Key('settings-confirm-delete-account')),
      );
      await tester.pumpAndSettle();

      final deletion = harness.requests.singleWhere(
        (request) =>
            request.method == 'DELETE' &&
            request.url.path == '/api/accounts/me/',
      );
      expect(deletion.headers['authorization'], 'Bearer access-token');
      expect(jsonDecode(deletion.body), {
        'password': 'correct current password',
      });
      expect(await harness.store.readSession(), isNull);
      expect(await harness.store.readSelectedKidId(), isNull);
      expect(
        await harness.parentSettingsStore.readSettings(profileId: 'kid-1'),
        isNull,
      );
      expect(harness.streakReminderService.disableCalls, 1);
      expect(harness.streakReminderService.enabled, isFalse);
      expect(harness.routedNames.last, '/auth/login');
      expect(find.text('Route: /auth/login'), findsOneWidget);
    },
  );

  testWidgets('failed permanent deletion preserves the signed-in device', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create(deleteFailureStatus: 400);

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('settings-delete-account')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-account')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-delete-password')),
      'wrong password',
    );
    await tester.tap(find.byKey(const Key('settings-confirm-delete-account')));
    await tester.pumpAndSettle();

    expect(find.text('The password is incorrect.'), findsOneWidget);
    expect(await harness.store.readSession(), isNotNull);
    expect(await harness.store.readSelectedKidId(), 'kid-1');
    expect(
      await harness.parentSettingsStore.readSettings(profileId: 'kid-1'),
      isNotNull,
    );
    expect(harness.streakReminderService.disableCalls, 0);
    expect(harness.routedNames, isEmpty);
    expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
  });

  testWidgets('expired deletion session clears auth and returns to login', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create(expireDeleteSession: true);

    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('settings-delete-account')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-account')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-delete-password')),
      'current password',
    );
    await tester.tap(find.byKey(const Key('settings-confirm-delete-account')));
    await tester.pumpAndSettle();

    expect(
      harness.requests.where(
        (request) =>
            request.method == 'DELETE' &&
            request.url.path == '/api/accounts/me/',
      ),
      hasLength(1),
    );
    expect(
      harness.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.url.path == '/api/accounts/token/refresh/',
      ),
      hasLength(1),
    );
    expect(await harness.store.readSession(), isNull);
    expect(await harness.store.readSelectedKidId(), isNull);
    expect(
      await harness.parentSettingsStore.readSettings(profileId: 'kid-1'),
      isNotNull,
    );
    expect(harness.streakReminderService.disableCalls, 0);
    expect(harness.routedNames.last, '/auth/login');
    expect(find.text('Route: /auth/login'), findsOneWidget);
  });

  testWidgets('remains usable at compact width with large system text', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(320, 568));
    final harness = await _SettingsHarness.create();

    await tester.pumpWidget(harness.app(textScaleFactor: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Parent settings'), findsOneWidget);
    expect(find.text('Backend Maya'), findsWidgets);
    expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
  });
}

class _SettingsHarness {
  _SettingsHarness._({
    required this.meFailuresRemaining,
    this.deleteFailureStatus,
    this.expireDeleteSession = false,
  }) {
    client = MockClient(_respond);
    authRepository = AuthRepository(
      api: HttpAuthApi(
        client: client,
        baseUrl: 'https://kingdom-kids.test/api',
      ),
      sessionStore: store,
    );
    settingsRepository = RemoteParentalControlsRepository(
      authRepository: authRepository,
      api: HttpParentalControlsApi(
        client: client,
        baseUrl: 'https://kingdom-kids.test/api',
      ),
      settingsStore: parentSettingsStore,
    );
  }

  static Future<_SettingsHarness> create({
    int meFailuresRemaining = 0,
    int? deleteFailureStatus,
    bool expireDeleteSession = false,
  }) async {
    final harness = _SettingsHarness._(
      meFailuresRemaining: meFailuresRemaining,
      deleteFailureStatus: deleteFailureStatus,
      expireDeleteSession: expireDeleteSession,
    );
    await harness.store.writeSession(
      const AuthSession(
        parent: ParentAccount(id: 'parent-1', email: 'cached@example.com'),
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        profiles: [_profile],
      ),
    );
    await harness.store.writeSelectedKidId('kid-1');
    return harness;
  }

  final MemoryAuthSessionStore store = MemoryAuthSessionStore();
  final MemoryParentSettingsStore parentSettingsStore =
      MemoryParentSettingsStore();
  final List<http.Request> requests = [];
  final List<String?> routedNames = [];
  final List<Uri> launchedUris = [];
  final _FakeStreakReminderService streakReminderService =
      _FakeStreakReminderService();
  late final http.Client client;
  late final AuthRepository authRepository;
  late final ParentalControlsRepository settingsRepository;
  int meFailuresRemaining;
  final int? deleteFailureStatus;
  final bool expireDeleteSession;
  int meCalls = 0;
  StoryTextScale storyTextScale = StoryTextScale.comfortable;
  bool narrationEnabled = true;

  Widget app({double? textScaleFactor}) {
    return MaterialApp(
      builder: textScaleFactor == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScaleFactor)),
              child: child!,
            ),
      home: ParentalControlsScreen(
        authRepository: authRepository,
        settingsRepository: settingsRepository,
        parentSettingsStore: parentSettingsStore,
        streakReminderService: streakReminderService,
        externalUrlLauncher: (uri) async {
          launchedUris.add(uri);
          return true;
        },
      ),
      onGenerateRoute: (settings) {
        routedNames.add(settings.name);
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('Route: ${settings.name}')),
        );
      },
    );
  }

  Future<http.Response> _respond(http.Request request) async {
    requests.add(request);
    switch ((request.method, request.url.path)) {
      case ('GET', '/api/accounts/me/'):
        meCalls++;
        if (meFailuresRemaining > 0) {
          meFailuresRemaining--;
          return http.Response(
            jsonEncode({'detail': 'Parent service is resting.'}),
            503,
          );
        }
        return http.Response(
          jsonEncode({
            'id': 'parent-1',
            'email': 'parent@example.com',
            'email_verified': true,
            'kid_profiles': [_profileJson],
          }),
          200,
        );
      case ('GET', '/api/accounts/kid-profiles/'):
        return http.Response(jsonEncode([_profileJson]), 200);
      case ('GET', '/api/accounts/kid-profiles/kid-1/preferences/'):
        return http.Response(jsonEncode(_settingsJson), 200);
      case ('PATCH', '/api/accounts/kid-profiles/kid-1/preferences/'):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['story_text_scale'] case final String scale) {
          storyTextScale = StoryTextScale.fromWireValue(scale);
        }
        if (body['narration_enabled'] case final bool enabled) {
          narrationEnabled = enabled;
        }
        return http.Response(jsonEncode(_settingsJson), 200);
      case ('POST', '/api/accounts/logout/'):
        return http.Response('', 204);
      case ('DELETE', '/api/accounts/me/'):
        if (expireDeleteSession) {
          return http.Response(
            jsonEncode({'detail': 'Token has expired.'}),
            401,
          );
        }
        if (deleteFailureStatus case final status?) {
          return http.Response(
            jsonEncode({
              'password': ['The password is incorrect.'],
            }),
            status,
          );
        }
        return http.Response('', 204);
      case ('POST', '/api/accounts/token/refresh/'):
        if (expireDeleteSession) {
          return http.Response(
            jsonEncode({
              'code': 'token_not_valid',
              'detail': 'Token is invalid or expired.',
            }),
            401,
          );
        }
        return http.Response(
          jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
          200,
        );
      default:
        return http.Response(
          jsonEncode({'detail': 'Unexpected test request.'}),
          500,
        );
    }
  }

  Map<String, dynamic> get _settingsJson => {
    'profile_id': 'kid-1',
    'story_text_scale': storyTextScale.wireValue,
    'narration_enabled': narrationEnabled,
    'updated_at': '2026-07-15T12:30:00Z',
  };
}

const _profile = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Backend Maya',
  avatarKey: 'dove',
);

const _profileJson = {
  'id': 'kid-1',
  'display_name': 'Backend Maya',
  'avatar_key': 'dove',
  'created_at': '2026-07-14T10:00:00Z',
  'updated_at': '2026-07-15T12:00:00Z',
};

final class _FakeStreakReminderService implements StreakReminderService {
  bool enabled = false;
  int enableCalls = 0;
  int disableCalls = 0;
  KidProfile? lastProfile;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<bool> enable({required KidProfile profile}) async {
    enableCalls += 1;
    lastProfile = profile;
    enabled = true;
    return true;
  }

  @override
  Future<void> disable() async {
    disableCalls += 1;
    enabled = false;
  }

  @override
  Future<void> refreshAfterAppOpen({required KidProfile profile}) async {}
}
