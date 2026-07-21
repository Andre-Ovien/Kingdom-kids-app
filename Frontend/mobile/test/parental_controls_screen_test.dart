import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/theme_controller.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_api.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/domain/parent_settings.dart';
import 'package:mobile/features/parental_controls/presentation/parental_controls_screen.dart';

void main() {
  setUp(() async {
    final themeStore = MemoryThemePreferenceStore();
    await AppThemeController.initialize(store: themeStore);
    await AppThemeController.setMode(ThemeMode.system);
  });

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
    expect(find.text('Parent service is resting.'), findsOneWidget);
    expect(find.byKey(const Key('settings-live-hero')), findsOneWidget);
    expect(find.text('cached@example.com'), findsOneWidget);
    expect(find.byKey(const Key('settings-theme')), findsOneWidget);
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
  _SettingsHarness._({required this.meFailuresRemaining}) {
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
    );
  }

  static Future<_SettingsHarness> create({int meFailuresRemaining = 0}) async {
    final harness = _SettingsHarness._(
      meFailuresRemaining: meFailuresRemaining,
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
  final List<http.Request> requests = [];
  final List<String?> routedNames = [];
  late final http.Client client;
  late final AuthRepository authRepository;
  late final ParentalControlsRepository settingsRepository;
  int meFailuresRemaining;
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
