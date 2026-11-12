import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/email_verification.dart';
import 'package:mobile/features/auth/presentation/auth_screen.dart';
import 'package:mobile/features/auth/presentation/email_verification_screen.dart';
import 'package:mobile/features/privacy/presentation/privacy_policy_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts =
        jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>;
    for (final entry in fonts.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List<dynamic>) {
        loader.addFont(rootBundle.load((font as Map)['asset'] as String));
      }
      await loader.load();
    }
  });
  for (final mode in AuthScreenMode.values) {
    testWidgets(
      'reads privacy in app before ${mode.name} without losing form values',
      (tester) async {
        final launchedUris = <Uri>[];
        await tester.pumpWidget(
          MaterialApp(
            home: AuthScreen(
              initialMode: mode,
              externalUrlLauncher: (uri) async {
                launchedUris.add(uri);
                return true;
              },
            ),
          ),
        );

        await tester.enterText(
          _fieldWithin(const Key('auth-email-field')),
          'parent@example.com',
        );
        await tester.enterText(
          _fieldWithin(const Key('auth-password-field')),
          'Parent-password-2026!',
        );

        final privacyLink = find.byKey(const Key('auth-privacy-policy'));
        final submitButton = find.byKey(const Key('auth-submit-button'));
        await tester.ensureVisible(privacyLink);
        await tester.pump();

        expect(privacyLink, findsOneWidget);
        expect(submitButton, findsOneWidget);
        expect(
          tester.getTopLeft(privacyLink).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(submitButton).dy),
        );
        await tester.tap(privacyLink);
        await tester.pumpAndSettle();

        expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
        expect(launchedUris, isEmpty);
        await tester.tap(find.byKey(const Key('privacy-policy-back')));
        await tester.pumpAndSettle();
        expect(find.byType(PrivacyPolicyScreen), findsNothing);
        expect(
          tester
              .widget<TextFormField>(
                _fieldWithin(const Key('auth-email-field')),
              )
              .controller!
              .text,
          'parent@example.com',
        );
        expect(
          tester
              .widget<TextFormField>(
                _fieldWithin(const Key('auth-password-field')),
              )
              .controller!
              .text,
          'Parent-password-2026!',
        );
        expect(launchedUris, isEmpty);
      },
    );
  }

  testWidgets('switches between the playful sign-up and sign-in forms', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));

    expect(find.text('Hey, welcome!'), findsOneWidget);
    expect(
      find.byKey(const Key('auth-confirm-password-field')),
      findsOneWidget,
    );
    expect(find.text('up').hitTestable(), findsOneWidget);

    final modeLink = find.byKey(const Key('auth-mode-link'));
    await tester.ensureVisible(modeLink);
    await tester.pump();
    await tester.tap(modeLink);
    await tester.pumpAndSettle();

    expect(find.text('Welcome back!'), findsOneWidget);
    expect(find.byKey(const Key('auth-confirm-password-field')), findsNothing);
    expect(find.text('in').hitTestable(), findsOneWidget);
  });

  testWidgets('opens password recovery from login without route secrets', (
    tester,
  ) async {
    RouteSettings? resetRouteSettings;
    await tester.pumpWidget(
      MaterialApp(
        home: const AuthScreen(initialMode: AuthScreenMode.login),
        onGenerateRoute: (settings) {
          resetRouteSettings = settings;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('Reset route reached')),
          );
        },
      ),
    );

    final forgotPassword = find.byKey(const Key('auth-forgot-password'));
    await tester.ensureVisible(forgotPassword);
    await tester.pump();
    await tester.tap(forgotPassword);
    await tester.pumpAndSettle();

    expect(find.text('Reset route reached'), findsOneWidget);
    expect(resetRouteSettings?.name, AppRoutes.passwordReset);
    expect(resetRouteSettings?.arguments, isNull);
  });

  testWidgets(
    'mode change morphs one header with Sign anchored and keeps typed email',
    (tester) async {
      _setAuthView(tester, const Size(393, 852));
      await tester.pumpWidget(
        const MaterialApp(home: AuthScreen(initialMode: AuthScreenMode.login)),
      );
      final sign = find.byKey(const Key('auth-sign-label'));
      final header = find.byKey(const Key('auth-wave-header'));
      final initialSign = tester.getTopLeft(sign);
      final initialHeight = tester.getSize(header).height;
      await tester.enterText(
        _fieldWithin(const Key('auth-email-field')),
        'parent@example.com',
      );
      await tester.tap(find.byKey(const Key('auth-mode-link')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 340));
      expect(tester.getTopLeft(sign), initialSign);
      expect(tester.getSize(header).height, lessThan(initialHeight));
      expect(tester.getSize(header).height, greaterThan(210));
      await tester.pump(const Duration(milliseconds: 340));
      expect(tester.getTopLeft(sign), initialSign);
      expect(tester.getSize(header).height, 210);
      expect(
        tester
            .widget<TextFormField>(_fieldWithin(const Key('auth-email-field')))
            .controller!
            .text,
        'parent@example.com',
      );
      expect(
        find.byKey(const Key('auth-confirm-password-field')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion changes mode immediately without moving Sign', (
    tester,
  ) async {
    _setAuthView(tester, const Size(393, 852));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const AuthScreen(initialMode: AuthScreenMode.login),
      ),
    );
    final sign = tester.getTopLeft(find.byKey(const Key('auth-sign-label')));
    await tester.tap(find.byKey(const Key('auth-mode-link')));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('auth-wave-header'))).height,
      210,
    );
    expect(tester.getTopLeft(find.byKey(const Key('auth-sign-label'))), sign);
    expect(
      find.byKey(const Key('auth-confirm-password-field')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('auth-submit-button')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'rapid reversal returns the same form to sign in without losing values',
    (tester) async {
      _setAuthView(tester, const Size(393, 852));
      await tester.pumpWidget(
        const MaterialApp(home: AuthScreen(initialMode: AuthScreenMode.login)),
      );
      await tester.enterText(
        _fieldWithin(const Key('auth-email-field')),
        'parent@example.com',
      );
      await tester.tap(find.byKey(const Key('auth-mode-link')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final middleHeight = tester
          .getSize(find.byKey(const Key('auth-wave-header')))
          .height;
      await tester.tap(find.byKey(const Key('auth-mode-link')));
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const Key('auth-wave-header'))).height,
        closeTo(middleHeight, 0.1),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('auth-confirm-password-field')),
        findsNothing,
      );
      expect(find.text('Welcome back!'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(_fieldWithin(const Key('auth-email-field')))
            .controller!
            .text,
        'parent@example.com',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in AuthScreenMode.values) {
    testWidgets(
      'empty ${mode.name} keeps normal header and inline field geometry',
      (tester) async {
        var requests = 0;
        final repository = _testRepository((_) async {
          requests++;
          throw StateError('Empty validation must not make a request');
        });
        await _pumpAuthPhone(tester, mode, repository);
        final header = tester.getRect(
          find.byKey(const Key('auth-wave-header')),
        );
        final caption = tester.getRect(
          find.text(
            mode == AuthScreenMode.login ? 'Welcome back!' : 'Hey, welcome!',
          ),
        );
        final fields = [
          'auth-email-field',
          'auth-password-field',
          if (mode == AuthScreenMode.register) 'auth-confirm-password-field',
        ];
        final before = {
          for (final name in fields)
            name: tester.getRect(find.byKey(Key(name))),
        };
        await tester.tap(find.byKey(const Key('auth-submit-button')));
        await tester.pumpAndSettle();
        expect(requests, 0);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          tester.getRect(find.byKey(const Key('auth-wave-header'))),
          header,
        );
        expect(
          tester.getRect(
            find.text(
              mode == AuthScreenMode.login ? 'Welcome back!' : 'Hey, welcome!',
            ),
          ),
          caption,
        );
        expect(find.text('Please enter your email address.'), findsOneWidget);
        expect(find.text('Please enter your password.'), findsOneWidget);
        if (mode == AuthScreenMode.register) {
          expect(find.text('Please confirm your password.'), findsOneWidget);
        }
        for (final name in fields) {
          expect(tester.getRect(find.byKey(Key(name))), before[name]);
          final input = tester.widget<TextField>(
            find.descendant(
              of: find.byKey(Key(name)),
              matching: find.byType(TextField),
            ),
          );
          expect(input.decoration!.errorText, isNotEmpty);
          expect(
            input.decoration!.errorBorder!.borderSide.color,
            const Color(0xFFA3334E),
          );
        }
        expect(
          tester
              .widget<SingleChildScrollView>(
                find.byKey(const Key('auth-form-scroll')),
              )
              .controller!
              .position
              .maxScrollExtent,
          0,
        );
        expect(
          find.byKey(const Key('auth-parent-safety-note')).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester
              .getBottomRight(find.byKey(const Key('auth-parent-safety-note')))
              .dy,
          lessThanOrEqualTo(818),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('fast ${mode.name} shows spinner for600ms before navigation', (
      tester,
    ) async {
      var requests = 0;
      var routes = 0;
      final repository = _testRepository((_) async {
        requests++;
        return _successResponse(mode);
      });
      await _pumpAuthPhone(
        tester,
        mode,
        repository,
        onGenerateRoute: (settings) {
          routes++;
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Next screen reached')),
          );
        },
      );
      await _enterValidAuth(tester, mode);
      await tester.tap(find.byKey(const Key('auth-submit-button')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(requests, 1);
      expect(routes, 0);
      await tester.pump(const Duration(milliseconds: 599));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(routes, 0);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(routes, 1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Next screen reached'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'server failure on ${mode.name} leaves header and caption stable',
      (tester) async {
        final repository = _testRepository(
          (_) async =>
              http.Response(jsonEncode({'detail': 'Please retry.'}), 503),
        );
        await _pumpAuthPhone(tester, mode, repository);
        await _enterValidAuth(tester, mode);
        final header = tester.getRect(
          find.byKey(const Key('auth-wave-header')),
        );
        final caption = tester.getRect(
          find.text(
            mode == AuthScreenMode.login ? 'Welcome back!' : 'Hey, welcome!',
          ),
        );
        await tester.tap(find.byKey(const Key('auth-submit-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 599));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const Key('auth-wave-header'))),
          header,
        );
        expect(
          tester.getRect(
            find.text(
              mode == AuthScreenMode.login ? 'Welcome back!' : 'Hey, welcome!',
            ),
          ),
          caption,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'invalid email and mismatched signup passwords stay inline without reflow',
    (tester) async {
      var requests = 0;
      final repository = _testRepository((_) async {
        requests++;
        throw StateError('Invalid input');
      });
      await _pumpAuthPhone(tester, AuthScreenMode.register, repository);
      await tester.enterText(
        _fieldWithin(const Key('auth-email-field')),
        'not-an-email',
      );
      await tester.enterText(
        _fieldWithin(const Key('auth-password-field')),
        'short',
      );
      await tester.enterText(
        _fieldWithin(const Key('auth-confirm-password-field')),
        'different',
      );
      final header = tester.getRect(find.byKey(const Key('auth-wave-header')));
      final caption = tester.getRect(find.text('Hey, welcome!'));
      await tester.tap(find.byKey(const Key('auth-submit-button')));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(find.text('Those passwords do not match.'), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('auth-wave-header'))), header);
      expect(tester.getRect(find.text('Hey, welcome!')), caption);
      expect(
        find.byKey(const Key('auth-parent-safety-note')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('primary Sign stays fixed and mode links have no touch capsule', (
    tester,
  ) async {
    await _pumpAuthPhone(
      tester,
      AuthScreenMode.login,
      _testRepository((_) async => _successResponse(AuthScreenMode.login)),
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('auth-submit-button')),
    );
    for (final states in [
      <WidgetState>{},
      {WidgetState.pressed},
      {WidgetState.disabled},
    ]) {
      expect(
        button.style!.backgroundColor!.resolve(states),
        const Color(0xFF1457FF),
      );
      expect(button.style!.overlayColor!.resolve(states), Colors.transparent);
    }
    expect(button.style!.splashFactory, NoSplash.splashFactory);
    final oldHighlightStrategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    expect(
      button.style!.side!.resolve({WidgetState.focused})!.width,
      greaterThan(0),
    );
    FocusManager.instance.highlightStrategy = oldHighlightStrategy;
    final modeLink = tester.widget<TextButton>(
      find.byKey(const Key('auth-mode-link')),
    );
    expect(
      modeLink.style!.overlayColor!.resolve({WidgetState.pressed}),
      Colors.transparent,
    );
    expect(modeLink.style!.splashFactory, NoSplash.splashFactory);
    final beforeSignX = tester
        .getTopLeft(find.byKey(const Key('auth-submit-sign-label')))
        .dx;
    await tester.tap(find.byKey(const Key('auth-mode-link')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));
    expect(
      tester.getTopLeft(find.byKey(const Key('auth-submit-sign-label'))).dx,
      beforeSignX,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('auth-submit-button')))
          .onPressed,
      isNull,
    );
    await tester.pumpAndSettle();
    expect(find.text('up').hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('auth-submit-sign-label'))).dx,
      beforeSignX,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('registration opens verification without storing a JWT', (
    tester,
  ) async {
    late http.Request registerRequest;
    final store = MemoryAuthSessionStore();
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          registerRequest = request;
          return http.Response(
            jsonEncode({
              'verification': {
                'challenge_id': 'challenge-1',
                'email': 'parent@example.com',
                'destination_hint': 'pa••••@example.com',
                'expires_in': 600,
                'resend_after': 60,
              },
            }),
            202,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthScreen(repository: repository),
        onGenerateRoute: (settings) {
          if (settings.name == AppRoutes.emailVerification &&
              settings.arguments is PendingEmailVerification) {
            return MaterialPageRoute<void>(
              builder: (_) => EmailVerificationScreen(
                pending: settings.arguments! as PendingEmailVerification,
                repository: repository,
              ),
            );
          }
          return null;
        },
      ),
    );

    await tester.enterText(
      _fieldWithin(const Key('auth-email-field')),
      'PARENT@EXAMPLE.COM',
    );
    await tester.enterText(
      _fieldWithin(const Key('auth-password-field')),
      'Correct-Horse-Battery-Staple-2026!',
    );
    await tester.enterText(
      _fieldWithin(const Key('auth-confirm-password-field')),
      'Correct-Horse-Battery-Staple-2026!',
    );
    final submitButton = find.byKey(const Key('auth-submit-button'));
    await tester.ensureVisible(submitButton);
    await tester.pump();
    await tester.tap(submitButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Enter your magic code.'), findsOneWidget);
    expect(await store.readSession(), isNull);
    expect(jsonDecode(registerRequest.body), {
      'email': 'parent@example.com',
      'password': 'Correct-Horse-Battery-Staple-2026!',
      'password_confirmation': 'Correct-Horse-Battery-Staple-2026!',
    });
  });

  testWidgets('unverified sign-in returns to the pending challenge', (
    tester,
  ) async {
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'code': 'email_verification_required',
              'detail': 'Verify your email address before signing in.',
              'verification': {
                'challenge_id': 'challenge-1',
                'email': 'parent@example.com',
                'destination_hint': 'pa••••@example.com',
                'expires_in': 600,
                'resend_after': 15,
              },
            }),
            403,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
      sessionStore: MemoryAuthSessionStore(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthScreen(
          initialMode: AuthScreenMode.login,
          repository: repository,
        ),
        onGenerateRoute: (settings) {
          if (settings.name == AppRoutes.emailVerification &&
              settings.arguments is PendingEmailVerification) {
            return MaterialPageRoute<void>(
              builder: (_) => EmailVerificationScreen(
                pending: settings.arguments! as PendingEmailVerification,
                repository: repository,
              ),
            );
          }
          return null;
        },
      ),
    );

    await tester.enterText(
      _fieldWithin(const Key('auth-email-field')),
      'parent@example.com',
    );
    await tester.enterText(
      _fieldWithin(const Key('auth-password-field')),
      'Correct-Horse-Battery-Staple-2026!',
    );
    final submitButton = find.byKey(const Key('auth-submit-button'));
    await tester.ensureVisible(submitButton);
    await tester.pump();
    await tester.tap(submitButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Enter your magic code.'), findsOneWidget);
    expect(find.textContaining('pa••••@example.com'), findsOneWidget);
  });

  testWidgets('auth form remains scroll-safe with large text', (tester) async {
    _setAuthView(tester, const Size(360, 640));

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
        home: const AuthScreen(),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Hey, welcome!'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores a second keyboard submission while registering', (
    tester,
  ) async {
    var registrationCount = 0;
    final response = Completer<http.Response>();
    final repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((_) {
          registrationCount += 1;
          return response.future;
        }),
      ),
      sessionStore: MemoryAuthSessionStore(),
    );

    await tester.pumpWidget(
      MaterialApp(home: AuthScreen(repository: repository)),
    );
    await tester.enterText(
      _fieldWithin(const Key('auth-email-field')),
      'parent@example.com',
    );
    await tester.enterText(
      _fieldWithin(const Key('auth-password-field')),
      'Correct-Horse-Battery-Staple-2026!',
    );
    await tester.enterText(
      _fieldWithin(const Key('auth-confirm-password-field')),
      'Correct-Horse-Battery-Staple-2026!',
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.testTextInput.receiveAction(TextInputAction.done);

    expect(registrationCount, 1);
    response.complete(
      http.Response(jsonEncode({'detail': 'Please retry.'}), 503),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Finder _fieldWithin(Key key) {
  return find.descendant(
    of: find.byKey(key),
    matching: find.byType(TextFormField),
  );
}

AuthRepository _testRepository(
  Future<http.Response> Function(http.Request) handler,
) => AuthRepository(
  api: HttpAuthApi(
    baseUrl: 'https://kingdom-kids.test/api',
    client: MockClient(handler),
  ),
  sessionStore: MemoryAuthSessionStore(),
);

http.Response _successResponse(AuthScreenMode mode) => http.Response(
  jsonEncode(
    mode == AuthScreenMode.register
        ? {
            'verification': {
              'challenge_id': 'challenge-1',
              'email': 'parent@example.com',
              'destination_hint': 'pa••••@example.com',
              'expires_in': 300,
              'resend_after': 60,
            },
          }
        : {
            'parent': {'id': 'parent-1', 'email': 'parent@example.com'},
            'access': 'test-access',
            'refresh': 'test-refresh',
            'profiles': [],
          },
  ),
  mode == AuthScreenMode.register ? 202 : 200,
  headers: {'content-type': 'application/json'},
);

Future<void> _pumpAuthPhone(
  WidgetTester tester,
  AuthScreenMode mode,
  AuthRepository repository, {
  RouteFactory? onGenerateRoute,
}) async {
  _setAuthView(tester, const Size(393, 852));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 59, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
        ),
        child: child!,
      ),
      home: AuthScreen(initialMode: mode, repository: repository),
      onGenerateRoute: onGenerateRoute,
    ),
  );
}

Future<void> _enterValidAuth(WidgetTester tester, AuthScreenMode mode) async {
  await tester.enterText(
    _fieldWithin(const Key('auth-email-field')),
    'parent@example.com',
  );
  await tester.enterText(
    _fieldWithin(const Key('auth-password-field')),
    'Correct-Horse-Battery-Staple-2026!',
  );
  if (mode == AuthScreenMode.register) {
    await tester.enterText(
      _fieldWithin(const Key('auth-confirm-password-field')),
      'Correct-Horse-Battery-Staple-2026!',
    );
  }
}

void _setAuthView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
