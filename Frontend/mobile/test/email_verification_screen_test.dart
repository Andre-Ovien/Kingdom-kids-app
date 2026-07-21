import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/email_verification.dart';
import 'package:mobile/features/auth/presentation/email_verification_screen.dart';

const _pending = PendingEmailVerification(
  challengeId: 'challenge-1',
  email: 'parent@example.com',
  destinationHint: 'pa••••@example.com',
  expiresInSeconds: 600,
  resendAfterSeconds: 60,
);

void main() {
  testWidgets('shows six code slots and enables completion after a paste', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: EmailVerificationScreen(pending: _pending)),
    );

    expect(find.text('Enter your magic code.'), findsOneWidget);
    expect(find.text('Kingdom Kids'), findsNothing);
    expect(find.textContaining('pa••••@example.com'), findsOneWidget);
    expect(find.text('Complete'), findsOneWidget);

    var completeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Complete'),
    );
    expect(completeButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();

    for (final digit in ['1', '2', '3', '4', '5', '6']) {
      expect(find.text(digit), findsOneWidget);
    }
    completeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Complete'),
    );
    expect(completeButton.onPressed, isNotNull);
  });

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
    final completeButton = find.byKey(const Key('verification-submit-button'));
    await tester.ensureVisible(completeButton);
    await tester.pump();
    await tester.tap(completeButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Profile setup reached'), findsOneWidget);
    expect((await store.readSession())?.accessToken, 'access-token');
  });
}
