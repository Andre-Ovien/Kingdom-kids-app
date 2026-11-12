import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/profile_picker_screen.dart';
import 'package:mobile/features/splash/data/first_launch_store.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';

const _profiles = [
  KidProfile(
    id: 'child-a',
    parentId: 'parent-1',
    displayName: 'Ada',
    avatarKey: 'lion',
  ),
  KidProfile(
    id: 'child-b',
    parentId: 'parent-1',
    displayName: 'Ben',
    avatarKey: 'lion',
  ),
  KidProfile(
    id: 'child-c',
    parentId: 'parent-1',
    displayName: 'Chika',
    avatarKey: 'dove',
  ),
  KidProfile(
    id: 'child-d',
    parentId: 'parent-1',
    displayName: 'Dara',
    avatarKey: 'rainbow',
  ),
  KidProfile(
    id: 'child-e',
    parentId: 'parent-1',
    displayName: 'Eva',
    avatarKey: 'dove',
  ),
];

const _session = AuthSession(
  parent: ParentAccount(id: 'parent-1', email: 'parent@example.test'),
  accessToken: 'test-access',
  refreshToken: 'test-refresh',
  profiles: _profiles,
);

void main() {
  testWidgets(
    'same-character children retain their names and select the exact child only after persistence',
    (tester) async {
      _usePhone(tester);
      final store = _DelayedSelectionStore();
      addTearDown(store.allowSelection);
      await store.writeSession(_session);
      var networkRequests = 0;
      final repository = AuthRepository(
        sessionStore: store,
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((_) async {
            networkRequests++;
            throw StateError('Selecting a saved child must remain local.');
          }),
        ),
      );
      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      _expectLabels(tester, _profiles[0], 'Kai');
      await tester.drag(
        find.byKey(const Key('profile-picker-carousel')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      _expectLabels(tester, _profiles[1], 'Kai');

      final continueButton = find.byKey(
        const Key('profile-picker-select-child-b'),
      );
      expect(continueButton.hitTestable(), findsOneWidget);
      await tester.tap(continueButton);
      await tester.pump(const Duration(milliseconds: 50));

      expect(store.attemptedIds, ['child-b']);
      expect(await store.readSelectedKidId(), isNull);
      expect(find.text('Home reached'), findsNothing);

      store.allowSelection();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Home reached'), findsOneWidget);
      expect(await store.readSelectedKidId(), 'child-b');
      expect((await repository.currentKid())?.displayName, 'Ben');
      expect(networkRequests, 0);
      final returning = AuthRepository(sessionStore: store);
      final destination = await StartupDestinationResolver(
        authRepository: returning,
        firstLaunchStore: MemoryFirstLaunchStore(launched: true),
      ).resolve();
      expect(destination.route, AppRoutes.home);
      expect((await returning.currentKid())?.id, 'child-b');
    },
  );

  testWidgets(
    'all five children remain reachable despite only three characters',
    (tester) async {
      _usePhone(tester);
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      final repository = AuthRepository(sessionStore: store);
      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      for (final profile in _profiles) {
        expect(
          find.byKey(Key('profile-picker-dot-${profile.id}')).hitTestable(),
          findsOneWidget,
        );
      }
      await tester.tap(find.byKey(const Key('profile-picker-dot-child-e')));
      await tester.pumpAndSettle();
      _expectLabels(tester, _profiles.last, 'Nia');
      await tester.tap(find.byKey(const Key('profile-picker-select-child-e')));
      await tester.pumpAndSettle();

      expect(await store.readSelectedKidId(), 'child-e');
      expect((await repository.currentKid())?.displayName, 'Eva');
      expect(find.text('Home reached'), findsOneWidget);
    },
  );

  testWidgets(
    'plus keeps the parent check and passes the actual children to setup',
    (tester) async {
      _usePhone(tester);
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      await store.writeSelectedKidId(_profiles[1].id);
      var parentChecks = 0;
      Object? setupArguments;
      final repository = AuthRepository(
        sessionStore: store,
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            expect(request.url.path, '/api/accounts/login/');
            parentChecks++;
            return http.Response(
              jsonEncode({
                'parent': {'id': 'parent-1', 'email': 'parent@example.test'},
                'access': 'reauth-access',
                'refresh': 'reauth-refresh',
                'profiles': <Object>[],
              }),
              200,
            );
          }),
        ),
      );
      await tester.pumpWidget(
        _app(repository, onSetup: (arguments) => setupArguments = arguments),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-picker-add-child')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adult-gate-dialog')), findsOneWidget);
      expect(find.text('Child setup reached'), findsNothing);
      expect(parentChecks, 0);
      await tester.enterText(
        find.byKey(const Key('adult-gate-password')),
        'Local-parent-test-password',
      );
      await tester.tap(find.byKey(const Key('adult-gate-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Child setup reached'), findsOneWidget);
      expect(parentChecks, 1);
      final passedProfiles = setupArguments! as List<KidProfile>;
      expect(
        passedProfiles.map((profile) => profile.id),
        _profiles.map((profile) => profile.id),
      );
      expect(
        passedProfiles.map((profile) => profile.displayName),
        _profiles.map((profile) => profile.displayName),
      );
      expect(await store.readSelectedKidId(), 'child-b');
      expect((await store.readSession())?.profiles, _profiles);
    },
  );
}

void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _expectLabels(WidgetTester tester, KidProfile profile, String character) {
  final childName = find.byKey(
    Key('profile-picker-display-name-${profile.id}'),
  );
  final characterName = find.byKey(
    Key('profile-picker-character-name-${profile.id}'),
  );
  expect(childName.hitTestable(), findsOneWidget);
  expect(tester.widget<Text>(childName).data, profile.displayName);
  expect(tester.widget<Text>(characterName).data, character);
}

Widget _app(AuthRepository repository, {ValueChanged<Object?>? onSetup}) =>
    MaterialApp(
      initialRoute: '/profile-picker-under-test',
      onGenerateInitialRoutes: (_) => [
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/profile-picker-under-test'),
          builder: (_) => ProfilePickerScreen(
            initialProfiles: _profiles,
            repository: repository,
          ),
        ),
      ],
      onGenerateRoute: (settings) {
        if (settings.name == AppRoutes.kidProfileSetup) {
          onSetup?.call(settings.arguments);
        }
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(
            body: Text(
              settings.name == AppRoutes.home
                  ? 'Home reached'
                  : 'Child setup reached',
            ),
          ),
        );
      },
    );

class _DelayedSelectionStore extends MemoryAuthSessionStore {
  final attemptedIds = <String>[];
  final _release = Completer<void>();

  @override
  Future<void> writeSelectedKidId(String kidId) async {
    attemptedIds.add(kidId);
    await _release.future;
    await super.writeSelectedKidId(kidId);
  }

  void allowSelection() {
    if (!_release.isCompleted) _release.complete();
  }
}
