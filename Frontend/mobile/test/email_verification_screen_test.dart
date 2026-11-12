import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/email_verification.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/presentation/email_verification_screen.dart';
import 'package:mobile/features/auth/presentation/verification_code_input.dart';
import 'package:mobile/features/auth/presentation/verification_page.dart';

const _pending = PendingEmailVerification(
  challengeId: 'challenge-1',
  email: 'parent@example.com',
  destinationHint: 'pa••••@example.com',
  expiresInSeconds: 600,
  resendAfterSeconds: 60,
);

void main() {
  for (final reduceMotion in [false, true]) {
    testWidgets(
      'typed invalid email code gives one red rejection, reduced motion=$reduceMotion',
      (tester) async {
        final haptics = _recordHaptics(tester);
        final fixture = _VerificationHarness(invalid: true);
        await tester.pumpWidget(fixture.app(reduceMotion: reduceMotion));
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pumpAndSettle();
        expect(fixture.checks, 1);
        final input = tester.widget<VerificationCodeInput>(
          find.byType(VerificationCodeInput),
        );
        expect(input.controller.text, isEmpty);
        expect(input.rejected, isTrue);
        expect(input.verified, isFalse);
        _expectBorders(tester, const Color(0xFFAD3451));
        final shake = tester.widget<VerificationCodeRejectionShake>(
          find.byKey(const Key('verification-code-rejection-shake')),
        );
        expect(shake.attempt, 1);
        expect(shake.reduceMotion, reduceMotion);
        expect(haptics, ['HapticFeedbackType.mediumImpact']);
        expect(
          find.text('That verification code is incorrect or has expired.'),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(fixture.checks, 1);
        await tester.enterText(find.byType(TextField), '9');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
              .rejected,
          isFalse,
        );
        expect(haptics, hasLength(1));
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pumpAndSettle();
        expect(fixture.checks, 2);
        expect(haptics, hasLength(2));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'email success shows green before automatic navigation, reduced motion=$reduceMotion',
      (tester) async {
        final haptics = _recordHaptics(tester);
        final response = Completer<void>();
        final fixture = _VerificationHarness(barrier: response.future);
        await tester.pumpWidget(fixture.app(reduceMotion: reduceMotion));
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pump();
        await tester.pump();
        expect(fixture.checks, 1);
        expect(
          tester
              .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
              .verified,
          isFalse,
        );
        response.complete();
        await tester.pump();
        await tester.pump();
        expect(
          tester
              .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
              .verified,
          isTrue,
        );
        _expectBorders(tester, const Color(0xFF25844F));
        expect(
          tester
              .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
              .enabled,
          isFalse,
        );
        expect(fixture.routes, isEmpty);
        await tester.pump(const Duration(milliseconds: 250));
        expect(fixture.routes, isEmpty);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pumpAndSettle();
        expect(find.text('Verified destination'), findsOneWidget);
        expect(fixture.routes.single.name, AppRoutes.kidProfileSetup);
        expect(fixture.checks, 1);
        expect(haptics, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'duplicate paste, Done and button cannot duplicate pending verification',
    (tester) async {
      final barrier = Completer<void>();
      final fixture = _VerificationHarness(
        invalid: true,
        barrier: barrier.future,
      );
      await tester.pumpWidget(fixture.app());
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      final page = tester.widget<VerificationPage>(
        find.byType(VerificationPage),
      );
      await page.onSubmit();
      expect(fixture.checks, 1);
      barrier.complete();
      await tester.pumpAndSettle();
      expect(fixture.checks, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'network failure has no invalid-code color, shake, haptic or automatic retry',
    (tester) async {
      final haptics = _recordHaptics(tester);
      final fixture = _VerificationHarness(offline: true);
      await tester.pumpWidget(fixture.app());
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      final input = tester.widget<VerificationCodeInput>(
        find.byType(VerificationCodeInput),
      );
      expect(input.controller.text, '123456');
      expect(input.verified, isFalse);
      expect(input.rejected, isFalse);
      expect(
        tester
            .widget<VerificationCodeRejectionShake>(
              find.byKey(const Key('verification-code-rejection-shake')),
            )
            .attempt,
        0,
      );
      expect(
        find.text(
          'Kingdom Kids is having trouble right now. Please try again soon.',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.checks, 1);
      expect(fixture.routes, isEmpty);
      expect(haptics, isEmpty);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(fixture.checks, 2);
      expect(haptics, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'covering and reopening route rejects an old verification response',
    (tester) async {
      final barrier = Completer<void>();
      final fixture = _VerificationHarness(barrier: barrier.future);
      await tester.pumpWidget(fixture.app());
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.pump();
      unawaited(
        fixture.navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Another route')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      fixture.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      barrier.complete();
      await tester.pumpAndSettle();
      expect(fixture.routes, isEmpty);
      expect(
        tester
            .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
            .verified,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final green in [false, true]) {
    testWidgets(
      'backgrounding during ${green ? 'green' : 'pending verification'} cancels old advancement',
      (tester) async {
        final haptics = _recordHaptics(tester);
        final barrier = Completer<void>();
        final fixture = _VerificationHarness(
          barrier: green ? null : barrier.future,
        );
        await tester.pumpWidget(fixture.app());
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pump();
        await tester.pump();
        if (green) {
          expect(
            tester
                .widget<VerificationCodeInput>(
                  find.byType(VerificationCodeInput),
                )
                .verified,
            isTrue,
          );
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        if (!green) barrier.complete();
        await tester.pumpAndSettle();
        expect(fixture.routes, isEmpty);
        expect(
          tester
              .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
              .verified,
          isFalse,
        );
        expect(haptics, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'disposing during pending verification cannot navigate or update a removed page',
    (tester) async {
      final barrier = Completer<void>();
      final fixture = _VerificationHarness(barrier: barrier.future);
      await tester.pumpWidget(fixture.app());
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      barrier.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.routes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new challenge ignores old success and accepts only its fresh code',
    (tester) async {
      final barrier = Completer<void>();
      final fixture = _VerificationHarness(barrier: barrier.future);
      await tester.pumpWidget(fixture.app());
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.pump();
      fixture.pending.value = const PendingEmailVerification(
        challengeId: 'challenge-2',
        email: 'parent@example.com',
        destinationHint: 'pa••••@example.com',
        expiresInSeconds: 600,
        resendAfterSeconds: 0,
      );
      await tester.pump();
      barrier.complete();
      await tester.pumpAndSettle();
      expect(fixture.routes, isEmpty);
      expect(
        tester
            .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
            .verified,
        isFalse,
      );
      expect(
        tester
            .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
            .controller
            .text,
        isEmpty,
      );
      await tester.enterText(find.byType(TextField), '654321');
      await tester.pumpAndSettle();
      expect(fixture.checks, 2);
      expect(fixture.confirmedChallenges, ['challenge-1', 'challenge-2']);
      expect(find.text('Verified destination'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'resend cancels queued auto-submit before replacing the challenge',
    (tester) async {
      final fixture = _VerificationHarness();
      await tester.pumpWidget(fixture.app());
      final page = tester.widget<VerificationPage>(
        find.byType(VerificationPage),
      );
      page.controller.text = '123456';
      tester
          .widget<TextButton>(
            find.byKey(const Key('verification-resend-button')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(fixture.checks, 0);
      expect(fixture.resends, 1);
      expect(
        tester
            .widget<VerificationPage>(find.byType(VerificationPage))
            .challengeKey,
        'challenge-2',
        reason: tester
            .widget<VerificationPage>(find.byType(VerificationPage))
            .errorMessage,
      );
      await tester.enterText(find.byType(TextField), '654321');
      await tester.pumpAndSettle();
      expect(fixture.confirmedChallenges, ['challenge-2']);
      expect(find.text('Verified destination'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late verification cannot replace a newer signed-in parent', (
    tester,
  ) async {
    final barrier = Completer<void>();
    final fixture = _VerificationHarness(barrier: barrier.future);
    await tester.pumpWidget(fixture.app());
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.pump();
    await fixture.repository.login(
      const LoginRequest(
        email: 'other@example.test',
        password: 'fixture-password',
      ),
    );
    barrier.complete();
    await tester.pumpAndSettle();
    expect((await fixture.store.readSession())?.parent.id, '84');
    expect(fixture.routes, isEmpty);
    expect(
      tester
          .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
          .verified,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'new sign-in during green clears old verification feedback before navigation',
    (tester) async {
      final fixture = _VerificationHarness();
      await tester.pumpWidget(fixture.app());
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
            .verified,
        isTrue,
      );
      await fixture.repository.login(
        const LoginRequest(
          email: 'other@example.test',
          password: 'fixture-password',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VerificationCodeInput>(find.byType(VerificationCodeInput))
            .verified,
        isFalse,
      );
      expect(fixture.routes, isEmpty);
      expect((await fixture.store.readSession())?.parent.id, '84');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'shows six code slots and automatically checks a pasted code once',
    (tester) async {
      var checks = 0;
      final repository = AuthRepository(
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            checks++;
            return http.Response(
              jsonEncode({'detail': 'That code was not accepted.'}),
              400,
            );
          }),
        ),
        sessionStore: MemoryAuthSessionStore(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EmailVerificationScreen(
            pending: _pending,
            repository: repository,
          ),
        ),
      );

      expect(find.text('Enter your magic code.'), findsOneWidget);
      expect(find.byType(VerificationCodeInput), findsOneWidget);
      expect(find.text('Kingdom Kids'), findsNothing);
      expect(find.textContaining('pa••••@example.com'), findsOneWidget);
      expect(find.text('Complete'), findsOneWidget);

      var completeButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Complete'),
      );
      expect(completeButton.onPressed, isNull);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();

      for (final digit in ['1', '2', '3', '4', '5', '6']) {
        expect(find.text(digit), findsOneWidget);
      }
      completeButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Complete'),
      );
      expect(completeButton.onPressed, isNotNull);
      expect(checks, 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(checks, 1);
    },
  );

  testWidgets('remains scroll-safe on a small screen with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          );
        },
        home: const EmailVerificationScreen(pending: _pending),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Enter your magic code.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful confirmation stores the session and continues', (
    tester,
  ) async {
    final store = MemoryAuthSessionStore();
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          expect(request.url.path, endsWith('email-verification/confirm/'));
          expect(jsonDecode(request.body), {
            'challenge_id': 'challenge-1',
            'code': '123456',
          });
          return http.Response(
            jsonEncode({
              'user': {
                'id': 42,
                'email': 'parent@example.com',
                'kid_profiles': [],
              },
              'access': 'access-token',
              'refresh': 'refresh-token',
            }),
            200,
          );
        }),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EmailVerificationScreen(
          pending: _pending,
          repository: repository,
        ),
        routes: {
          AppRoutes.kidProfileSetup: (_) => const Scaffold(
            body: Center(child: Text('Profile setup reached')),
          ),
        },
      ),
    );

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();

    expect(find.text('Profile setup reached'), findsOneWidget);
    expect((await store.readSession())?.accessToken, 'access-token');
  });
}

List<String> _recordHaptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call.arguments as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

void _expectBorders(WidgetTester tester, Color color) {
  final slots = tester.widgetList<AnimatedContainer>(
    find.descendant(
      of: find.byType(VerificationCodeInput),
      matching: find.byType(AnimatedContainer),
    ),
  );
  expect(slots, hasLength(6));
  for (final slot in slots) {
    final border = (slot.decoration! as BoxDecoration).border! as Border;
    expect(border.top.color, color);
    expect(slot.duration, Duration.zero);
  }
}

class _VerificationHarness {
  _VerificationHarness({
    this.invalid = false,
    this.offline = false,
    this.barrier,
  }) {
    repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(_respond),
      ),
      sessionStore: store,
    );
  }
  final bool invalid, offline;
  final Future<void>? barrier;
  final store = MemoryAuthSessionStore();
  final navigator = GlobalKey<NavigatorState>();
  final pending = ValueNotifier(
    const PendingEmailVerification(
      challengeId: 'challenge-1',
      email: 'parent@example.com',
      destinationHint: 'pa••••@example.com',
      expiresInSeconds: 600,
      resendAfterSeconds: 0,
    ),
  );
  final routes = <RouteSettings>[];
  final confirmedChallenges = <String>[];
  int checks = 0, resends = 0;
  late final AuthRepository repository;

  Widget app({bool reduceMotion = false}) => MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [appRouteObserver],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: ValueListenableBuilder<PendingEmailVerification>(
      valueListenable: pending,
      builder: (_, value, _) =>
          EmailVerificationScreen(pending: value, repository: repository),
    ),
    onGenerateRoute: (settings) {
      routes.add(settings);
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const Scaffold(body: Text('Verified destination')),
      );
    },
  );

  Future<http.Response> _respond(http.Request request) async {
    if (request.url.path.endsWith('email-verification/confirm/')) {
      checks++;
      confirmedChallenges.add(
        (jsonDecode(request.body) as Map)['challenge_id'] as String,
      );
      await barrier;
      if (invalid) {
        return http.Response(
          jsonEncode({
            'code': 'invalid_or_expired_code',
            'detail': 'That verification code is incorrect or has expired.',
          }),
          400,
        );
      }
      if (offline) {
        return http.Response(
          jsonEncode({'detail': 'Please try again later.'}),
          503,
        );
      }
      return _sessionResponse('42', 'parent@example.com');
    }
    if (request.url.path.endsWith('email-verification/resend/')) {
      resends++;
      return http.Response(
        jsonEncode({
          'verification': {
            'challenge_id': 'challenge-2',
            'destination_hint': 'pa••••@example.com',
            'expires_in': 600,
            'resend_after': 0,
          },
        }),
        202,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.url.path.endsWith('/login/')) {
      return _sessionResponse('84', 'other@example.test');
    }
    throw StateError('Unexpected fixture request ${request.url.path}');
  }
}

http.Response _sessionResponse(String id, String email) => http.Response(
  jsonEncode({
    'user': {'id': id, 'email': email, 'kid_profiles': []},
    'access': 'fixture-access-$id',
    'refresh': 'fixture-refresh-$id',
  }),
  200,
);
