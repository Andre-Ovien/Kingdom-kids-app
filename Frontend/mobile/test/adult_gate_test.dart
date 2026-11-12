import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/adult_gate.dart';
import 'package:mobile/features/auth/presentation/profile_picker_screen.dart';
import 'package:mobile/features/parental_controls/presentation/parental_controls_screen.dart';

const _kid = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Maya',
  avatarKey: 'dove',
);

const _session = AuthSession(
  parent: ParentAccount(
    id: 'parent-1',
    email: 'private-parent@example.com',
    firstName: 'Private Parent',
  ),
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
  profiles: [_kid],
);

void main() {
  group('AuthRepository adult authorization', () {
    test(
      'reauthenticates with the cached email and atomically rotates tokens',
      () async {
        late http.Request loginRequest;
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session);
        await store.writeSelectedKidId(_kid.id);
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((request) async {
              loginRequest = request;
              return http.Response(
                jsonEncode({
                  'user': {
                    'id': 'parent-1',
                    'email': 'private-parent@example.com',
                    'first_name': 'Server copy',
                    'kid_profiles': <Object>[],
                  },
                  'access': 'fresh-access',
                  'refresh': 'fresh-refresh',
                }),
                200,
              );
            }),
          ),
          sessionStore: store,
        );

        await repository.reauthenticate('exact password');

        expect(loginRequest.url.path, '/api/accounts/login/');
        expect(jsonDecode(loginRequest.body), {
          'email': 'private-parent@example.com',
          'password': 'exact password',
        });
        final current = await store.readSession();
        expect(current?.accessToken, 'fresh-access');
        expect(current?.refreshToken, 'fresh-refresh');
        expect(current?.parent.firstName, 'Private Parent');
        expect(current?.profiles, [_kid]);
        expect(await store.readSelectedKidId(), _kid.id);
      },
    );

    test(
      'wrong password fails closed and preserves the active session',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session);
        await store.writeSelectedKidId(_kid.id);
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({'detail': 'Invalid credentials.'}),
                401,
              ),
            ),
          ),
          sessionStore: store,
        );

        await expectLater(
          repository.reauthenticate('wrong'),
          throwsA(
            isA<AppException>()
                .having(
                  (error) => error.code,
                  'code',
                  'invalid_parent_password',
                )
                .having(
                  (error) => error.userMessage,
                  'userMessage',
                  'That password did not match. Please try again.',
                ),
          ),
        );

        expect(await store.readSession(), same(_session));
        expect(await store.readSelectedKidId(), _kid.id);
      },
    );

    test(
      'a mismatched login identity fails closed without replacing the session',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session);
        await store.writeSelectedKidId(_kid.id);
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'user': {'id': 'other-parent', 'email': 'other@example.com'},
                  'access': 'other-access',
                  'refresh': 'other-refresh',
                }),
                200,
              ),
            ),
          ),
          sessionStore: store,
        );

        await expectLater(
          repository.reauthenticate('correct-for-another-account'),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'session_account_changed',
            ),
          ),
        );

        expect(await store.readSession(), same(_session));
        expect(await store.readSelectedKidId(), _kid.id);
      },
    );

    test('currentParent rejects a changed backend parent identity', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      final repository = AuthRepository(
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({'id': 'other-parent', 'email': 'other@example.com'}),
              200,
            ),
          ),
        ),
        sessionStore: store,
      );

      await expectLater(
        repository.currentParent(),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'session_account_changed',
          ),
        ),
      );
      expect(await store.readSession(), same(_session));
    });

    test('selectKid accepts only a profile in the current session', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      await store.writeSelectedKidId(_kid.id);
      final repository = AuthRepository(sessionStore: store);
      const outsider = KidProfile(
        id: 'other-kid',
        parentId: 'other-parent',
        displayName: 'Outsider',
        avatarKey: 'lion',
      );

      await expectLater(
        repository.selectKid(outsider),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'profile_not_in_session',
          ),
        ),
      );
      expect(await store.readSelectedKidId(), _kid.id);

      await repository.selectKid(_kid);
      expect(await store.readSelectedKidId(), _kid.id);
    });
  });

  testWidgets(
    'protected content is not built until the correct password succeeds',
    (tester) async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      final repository = _passwordRepository(store);
      var protectedBuilds = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: AdultGate(
            repository: repository,
            title: 'Parent settings',
            protectedBuilder: (_) {
              protectedBuilds += 1;
              return const Scaffold(
                body: Column(
                  children: [
                    Text('private-parent@example.com'),
                    Text('Privacy policy'),
                    Text('Delete account'),
                  ],
                ),
              );
            },
          ),
        ),
      );

      expect(protectedBuilds, 0);
      expect(find.text('private-parent@example.com'), findsNothing);
      expect(find.text('Privacy policy'), findsNothing);
      expect(find.text('Delete account'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('adult-gate-password')),
        'wrong',
      );
      await tester.tap(find.byKey(const Key('adult-gate-submit')));
      await tester.pumpAndSettle();

      expect(
        find.text('That password did not match. Please try again.'),
        findsOneWidget,
      );
      expect(protectedBuilds, 0);
      expect(find.text('private-parent@example.com'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('adult-gate-password')),
        'correct-password',
      );
      await tester.tap(find.byKey(const Key('adult-gate-submit')));
      await tester.pumpAndSettle();

      expect(protectedBuilds, greaterThan(0));
      expect(find.text('private-parent@example.com'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);
      expect(find.text('Delete account'), findsOneWidget);
    },
  );

  testWidgets(
    'an unlocked route locks again after backgrounding and resuming',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);

      await tester.pumpWidget(
        MaterialApp(
          home: AdultGate(
            repository: _passwordRepository(store),
            protectedBuilder: (_) =>
                const Scaffold(body: Text('Unlocked parent settings')),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('adult-gate-password')),
        'correct-password',
      );
      await tester.tap(find.byKey(const Key('adult-gate-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Unlocked parent settings'), findsOneWidget);
      expect(find.byKey(const Key('adult-gate-screen')), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Unlocked parent settings'), findsNothing);
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      expect(find.byKey(const Key('adult-gate-password')), findsOneWidget);
    },
  );

  testWidgets('an unlocked route expires after a short authorization window', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);

    await tester.pumpWidget(
      MaterialApp(
        home: AdultGate(
          repository: _passwordRepository(store),
          authorizationDuration: const Duration(seconds: 30),
          protectedBuilder: (_) =>
              const Scaffold(body: Text('Unlocked parent settings')),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('adult-gate-password')),
      'correct-password',
    );
    await tester.tap(find.byKey(const Key('adult-gate-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Unlocked parent settings'), findsOneWidget);

    await tester.pump(const Duration(seconds: 29));
    expect(find.text('Unlocked parent settings'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Unlocked parent settings'), findsNothing);
    expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
  });

  testWidgets('the parental controls route is wrapped by the adult gate', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: Text('Home')),
        onGenerateRoute: AppRouter.onGenerateRoute,
      ),
    );

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pushNamed(AppRoutes.parentalControls);
    await tester.pumpAndSettle();

    expect(find.byType(AdultGate), findsOneWidget);
    expect(find.byType(ParentalControlsScreen), findsNothing);
    expect(find.byKey(const Key('settings-delete-account')), findsNothing);
  });

  testWidgets('adding another child remains gated while switching does not', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);
    final repository = _passwordRepository(store);

    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: ProfilePickerScreen(
          repository: repository,
          initialProfiles: const [_kid],
        ),
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('Route: ${settings.name}')),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('profile-picker-add-child')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adult-gate-dialog')), findsOneWidget);
    expect(find.text('Route: ${AppRoutes.kidProfileSetup}'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('adult-gate-password')),
      'wrong',
    );
    await tester.tap(find.byKey(const Key('adult-gate-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adult-gate-dialog')), findsOneWidget);
    expect(find.text('Route: ${AppRoutes.kidProfileSetup}'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('adult-gate-password')),
      'correct-password',
    );
    await tester.tap(find.byKey(const Key('adult-gate-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Route: ${AppRoutes.kidProfileSetup}'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: ProfilePickerScreen(
          repository: repository,
          initialProfiles: const [_kid],
        ),
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('Route: ${settings.name}')),
        ),
      ),
    );
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('adult-gate-dialog')), findsNothing);
    expect(await store.readSelectedKidId(), _kid.id);
  });

  testWidgets('first child creation can continue without another gate', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(
      const AuthSession(
        parent: ParentAccount(
          id: 'parent-1',
          email: 'private-parent@example.com',
        ),
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      ),
    );
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((_) async => http.Response('[]', 200)),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ProfilePickerScreen(repository: repository),
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text('Route: ${settings.name}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('profile-picker-create-first-child')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('adult-gate-dialog')), findsNothing);
    expect(find.text('Route: ${AppRoutes.kidProfileSetup}'), findsOneWidget);
  });
}

AuthRepository _passwordRepository(MemoryAuthSessionStore store) {
  return AuthRepository(
    api: HttpAuthApi(
      baseUrl: 'https://kingdom-kids.test/api',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['password'] != 'correct-password') {
          return http.Response(
            jsonEncode({'detail': 'Invalid credentials.'}),
            401,
          );
        }
        return http.Response(
          jsonEncode({
            'user': {
              'id': 'parent-1',
              'email': 'private-parent@example.com',
              'kid_profiles': [_kid.toJson()],
            },
            'access': 'fresh-access',
            'refresh': 'fresh-refresh',
          }),
          200,
        );
      }),
    ),
    sessionStore: store,
  );
}
