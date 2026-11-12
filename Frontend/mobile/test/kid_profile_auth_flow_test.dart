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
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/spotlight_character.dart';
import 'package:mobile/features/auth/presentation/kid_profile_setup_screen.dart';
import 'package:mobile/features/auth/presentation/profile_picker_screen.dart';

const _session = AuthSession(
  parent: ParentAccount(id: '42', email: 'parent@example.com'),
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
);

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue();
  });
  testWidgets(
    'profile setup stays usable on a compact screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            );
          },
          home: const KidProfileSetupScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await _chooseBuddy(tester);
      final createButton = find.byKey(const Key('create-kid-profile-button'));
      await tester.ensureVisible(createButton);
      await tester.pumpAndSettle();
      expect(createButton, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows the three-character cast and submits the selected buddy', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);
    Map<String, dynamic>? requestBody;
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          requestBody = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          return http.Response(
            jsonEncode({
              'id': 'kid-1',
              'display_name': 'Ada',
              'avatar_key': requestBody!['avatar_key'],
            }),
            201,
          );
        }),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: KidProfileSetupScreen(repository: repository),
        routes: {
          AppRoutes.profilePicker: (_) => const Scaffold(
            body: Center(child: Text('Profile picker reached')),
          ),
        },
      ),
    );

    expect(find.byKey(const Key('story-buddy-previous')), findsNothing);
    expect(find.byKey(const Key('story-buddy-next')), findsNothing);
    expect(find.byKey(const Key('story-buddy-page-indicator')), findsOneWidget);
    for (var page = 0; page < 3; page++) {
      expect(find.byKey(ValueKey('story-buddy-page-$page')), findsOneWidget);
    }
    expect(find.byKey(const Key('kid-avatar-choice-lion')), findsNothing);
    expect(find.byKey(const Key('kid-avatar-choice-dove')), findsNothing);
    expect(find.byKey(const Key('kid-avatar-choice-rainbow')), findsNothing);
    expect(find.byType(SpotlightCharacter), findsWidgets);
    expect(find.byKey(const Key('kid-profile-name-field')), findsNothing);
    expect(find.text('LAST STEP  •  MAKE IT THEIRS'), findsNothing);

    final niaChoice = find.byKey(const ValueKey('story-buddy-page-1'));
    await tester.ensureVisible(niaChoice);
    await tester.pump();
    await tester.tap(niaChoice);
    await tester.pumpAndSettle();
    expect(find.text('Meet Nia'), findsOneWidget);
    expect(find.bySemanticsLabel('Nia, story buddy'), findsOneWidget);

    await _chooseBuddy(tester);
    await tester.enterText(
      find.byKey(const Key('kid-profile-name-field')),
      'Ada',
    );
    final createButton = find.byKey(const Key('create-kid-profile-button'));
    await tester.ensureVisible(createButton);
    await tester.pump();
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(requestBody?['avatar_key'], 'dove');
    expect(find.text('Profile picker reached'), findsOneWidget);
  });

  testWidgets('ignores a second keyboard submission while creating a profile', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);
    var creationCount = 0;
    final response = Completer<http.Response>();
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((_) {
          creationCount += 1;
          return response.future;
        }),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(home: KidProfileSetupScreen(repository: repository)),
    );
    await _chooseBuddy(tester);
    await tester.enterText(
      find.byKey(const Key('kid-profile-name-field')),
      'Sam',
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.testTextInput.receiveAction(TextInputAction.done);

    expect(creationCount, 1);
    response.complete(
      http.Response(jsonEncode({'detail': 'Please retry.'}), 503),
    );
    await tester.pump();
  });

  testWidgets('reuses the operation ID after an ambiguous create failure', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);
    final requestBodies = <Map<String, dynamic>>[];
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          requestBodies.add(
            (jsonDecode(request.body) as Map).cast<String, dynamic>(),
          );
          if (requestBodies.length == 1) {
            throw TimeoutException('the create response was lost');
          }
          return http.Response(jsonEncode({'detail': 'Please retry.'}), 503);
        }),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(home: KidProfileSetupScreen(repository: repository)),
    );
    await _chooseBuddy(tester);
    await tester.enterText(
      find.byKey(const Key('kid-profile-name-field')),
      'Sam',
    );
    await tester.pump();
    final createButton = find.byKey(const Key('create-kid-profile-button'));
    await tester.ensureVisible(createButton);
    await tester.pump();
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    await tester.ensureVisible(createButton);
    await tester.pump();
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(requestBodies, hasLength(2));
    final firstOperationId = requestBodies.first['operation_id'] as String;
    expect(requestBodies.last['operation_id'], firstOperationId);
    expect(
      firstOperationId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(
      find.text(
        'Kingdom Kids is having trouble right now. Please try again soon.',
      ),
      findsOneWidget,
    );
    expect(find.text('Please retry.'), findsNothing);
  });

  testWidgets('returns to sign-in after the refresh token is rejected', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'detail': 'Token is invalid or expired.'}),
            401,
          ),
        ),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: KidProfileSetupScreen(repository: repository),
        routes: {
          AppRoutes.login: (_) => const Scaffold(
            body: Center(child: Text('Parent sign-in reached')),
          ),
        },
      ),
    );
    await _chooseBuddy(tester);
    await tester.enterText(
      find.byKey(const Key('kid-profile-name-field')),
      'Sam',
    );
    await tester.pump();
    final createButton = find.byKey(const Key('create-kid-profile-button'));
    await tester.ensureVisible(createButton);
    await tester.pump();
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(find.text('Parent sign-in reached'), findsOneWidget);
    expect(await store.readSession(), isNull);
  });

  testWidgets('a missing local session goes straight to parent sign-in', (
    tester,
  ) async {
    final repository = AuthRepository(sessionStore: MemoryAuthSessionStore());

    await tester.pumpWidget(
      MaterialApp(
        home: ProfilePickerScreen(repository: repository),
        routes: {
          AppRoutes.login: (_) => const Scaffold(
            body: Center(child: Text('Parent sign-in reached')),
          ),
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Parent sign-in reached'), findsOneWidget);
    expect(find.byKey(const Key('profile-picker-load-error')), findsNothing);
  });

  testWidgets(
    'profile load failure stays distinct from a family with no profiles',
    (tester) async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      var requests = 0;
      final repository = AuthRepository(
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((_) async {
            requests += 1;
            if (requests == 1) {
              return http.Response(
                jsonEncode({'detail': 'upstream service unavailable'}),
                503,
              );
            }
            return http.Response(
              jsonEncode([
                {
                  'id': 'kid-1',
                  'parent_id': '42',
                  'display_name': 'Ada',
                  'avatar_key': 'dove',
                },
              ]),
              200,
            );
          }),
        ),
        sessionStore: store,
      );

      await tester.pumpWidget(
        MaterialApp(home: ProfilePickerScreen(repository: repository)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('profile-picker-load-error')),
        findsOneWidget,
      );
      expect(find.text('Profiles couldn\'t load'), findsOneWidget);
      expect(find.text('No child profiles yet'), findsNothing);
      expect(find.text('Let\'s make a profile'), findsNothing);
      expect(find.textContaining('upstream'), findsNothing);

      final retry = find.byKey(const Key('profile-picker-retry-button'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(find.text('Ada'), findsOneWidget);
      expect(find.byKey(const Key('profile-picker-load-error')), findsNothing);
      expect(requests, 2);
    },
  );

  testWidgets('profile loading also returns to sign-in after session expiry', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'detail': 'Token is invalid or expired.'}),
            401,
          ),
        ),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ProfilePickerScreen(repository: repository),
        routes: {
          AppRoutes.login: (_) => const Scaffold(
            body: Center(child: Text('Parent sign-in reached')),
          ),
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Parent sign-in reached'), findsOneWidget);
    expect(await store.readSession(), isNull);
  });
}

Future<void> _chooseBuddy(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('select-story-buddy')));
  await tester.pumpAndSettle();
}
