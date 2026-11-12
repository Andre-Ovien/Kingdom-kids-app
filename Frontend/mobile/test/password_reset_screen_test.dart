import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/password_reset_screen.dart';
import 'package:mobile/features/auth/presentation/verification_code_input.dart';
import 'package:mobile/features/auth/presentation/verification_friend.dart';
import 'package:mobile/features/auth/presentation/verification_page.dart';

void main() {
  testWidgets(
    'server success turns all six outlines green before one quick glide',
    (tester) async {
      final haptics = _recordHaptics(tester);
      final barrier = Completer<void>();
      final harness = _PasswordResetHarness(verifyBarrier: barrier.future);
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await tester.enterText(_otp, '123456');
      await _tapCodeVerification(tester);
      expect(_codeInput(tester).verified, isFalse);
      expect(find.text('Create a new password'), findsNothing);
      barrier.complete();
      await tester.pump();
      await tester.pump();
      expect(_codeInput(tester).verified, isTrue);
      final slots = tester.widgetList<AnimatedContainer>(
        find.descendant(of: _otp, matching: find.byType(AnimatedContainer)),
      );
      expect(slots, hasLength(6));
      for (final slot in slots) {
        final border = (slot.decoration! as BoxDecoration).border! as Border;
        expect(border.top.color, const Color(0xFF25844F));
        expect(slot.duration, Duration.zero);
      }
      expect(_codeInput(tester).enabled, isFalse);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const Key('password-reset-request-another-button')),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Create a new password'), findsNothing);
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.byKey(const Key('password-reset-success-glide')),
        findsWidgets,
      );
      expect(find.text('Create a new password'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('password-reset-new-password-field')),
            )
            .enabled,
        isFalse,
      );
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      expect(_otp, findsNothing);
      expect(
        find.byKey(const Key('password-reset-success-glide')),
        findsNothing,
      );
      expect(haptics, isEmpty);
      expect(_verifyRequests(harness), hasLength(1));
    },
  );

  testWidgets('reduced motion keeps the success beat but skips the glide', (
    tester,
  ) async {
    final harness = _PasswordResetHarness();
    await tester.pumpWidget(harness.app(reduceMotion: true));
    await _requestCode(tester);
    await tester.enterText(_otp, '123456');
    await _tapCodeVerification(tester);
    expect(_codeInput(tester).verified, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Create a new password'), findsNothing);
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pumpAndSettle();
    expect(find.text('Create a new password'), findsOneWidget);
    expect(find.byKey(const Key('password-reset-success-glide')), findsNothing);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets('a server rejection cues once, reduced motion=$reduceMotion', (
      tester,
    ) async {
      final haptics = _recordHaptics(tester);
      final harness = _PasswordResetHarness(verifyFails: true);
      await tester.pumpWidget(harness.app(reduceMotion: reduceMotion));
      await _requestCode(tester);
      await tester.enterText(_otp, '123456');
      await _tapCodeVerification(tester);
      expect(_codeInput(tester).verified, isFalse);
      expect(_codeInput(tester).rejected, isTrue);
      expect(find.byKey(const Key('password-reset-error')), findsNothing);
      final shake = find.byKey(const Key('verification-code-rejection-shake'));
      expect(tester.widget<VerificationCodeRejectionShake>(shake).attempt, 1);
      expect(
        tester
            .widget<TweenAnimationBuilder<double>>(
              find.descendant(
                of: shake,
                matching: find.byType(TweenAnimationBuilder<double>),
              ),
            )
            .duration,
        reduceMotion ? Duration.zero : const Duration(milliseconds: 250),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final transform = tester.widget<Transform>(
        find.descendant(
          of: shake,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Transform && widget.child is VerificationCodeInput,
          ),
        ),
      );
      expect(transform.transform.storage[12], reduceMotion ? 0 : isNot(0));
      expect(haptics, ['HapticFeedbackType.mediumImpact']);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(harness.app(reduceMotion: reduceMotion));
      await tester.pumpAndSettle();
      expect(haptics, hasLength(1));
      expect(_verifyRequests(harness), hasLength(1));
      expect(find.text('Create a new password'), findsNothing);
      // A fresh correction clears the static red state, not the attempt count.
      await tester.enterText(_otp, '9');
      await tester.pumpAndSettle();
      expect(_codeInput(tester).rejected, isFalse);
      expect(haptics, hasLength(1));
    });
  }

  testWidgets('transport failure does not shake, haptic, green or auto retry', (
    tester,
  ) async {
    final haptics = _recordHaptics(tester);
    final harness = _PasswordResetHarness(verifyNetworkFails: true);
    await tester.pumpWidget(harness.app());
    await _requestCode(tester);
    await _verifyCode(tester);
    expect(_codeInput(tester).verified, isFalse);
    expect(_codeInput(tester).rejected, isFalse);
    expect(_codeInput(tester).controller.text, '123456');
    expect(find.byKey(const Key('password-reset-error')), findsOneWidget);
    expect(
      tester
          .widget<VerificationCodeRejectionShake>(
            find.byKey(const Key('verification-code-rejection-shake')),
          )
          .attempt,
      0,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(haptics, isEmpty);
    expect(_verifyRequests(harness), hasLength(1));
    expect(find.text('Create a new password'), findsNothing);
  });

  for (final phase in ['green', 'glide']) {
    testWidgets('expiry during $phase cancels advancement and unlocks resend', (
      tester,
    ) async {
      final harness = _PasswordResetHarness(
        challenges: const [
          _Challenge('11111111-1111-4111-8111-111111111111', 2),
          _Challenge('22222222-2222-4222-8222-222222222222', 300),
        ],
      );
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await tester.enterText(_otp, '123456');
      await _tapCodeVerification(tester);
      expect(_codeInput(tester).verified, isTrue);
      if (phase == 'glide') {
        await tester.pump(const Duration(milliseconds: 310));
        expect(
          find.byKey(const Key('password-reset-success-glide')),
          findsWidgets,
        );
      }
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Create a new password'), findsNothing);
      expect(_codeInput(tester).verified, isFalse);
      expect(_codeInput(tester).controller.text, isEmpty);
      final resend = find.byKey(
        const Key('password-reset-request-another-button'),
      );
      expect(tester.widget<TextButton>(resend).onPressed, isNotNull);
      await tester.ensureVisible(resend);
      await tester.tap(resend);
      await tester.pumpAndSettle();
      expect(find.text('Code expires in 5:00'), findsOneWidget);
      expect(_verifyRequests(harness), hasLength(1));
    });
  }

  testWidgets(
    'covering the route during green cancels the deferred page change',
    (tester) async {
      final harness = _PasswordResetHarness();
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await tester.enterText(_otp, '123456');
      await _tapCodeVerification(tester);
      expect(_codeInput(tester).verified, isTrue);
      unawaited(
        harness.navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      harness.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.text('Create a new password'), findsNothing);
      expect(_codeInput(tester).verified, isFalse);
      expect(_codeInput(tester).controller.text, isEmpty);
      expect(_verifyRequests(harness), hasLength(1));
    },
  );

  testWidgets('dispose during green cancels the feedback ticker safely', (
    tester,
  ) async {
    final harness = _PasswordResetHarness();
    await tester.pumpWidget(harness.app());
    await _requestCode(tester);
    await tester.enterText(_otp, '123456');
    await _tapCodeVerification(tester);
    expect(_codeInput(tester).verified, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(harness.routedSettings, isEmpty);
  });

  for (final phase in ['pending rejection', 'green', 'glide']) {
    testWidgets(
      'backgrounding during $phase cancels late feedback and advance',
      (tester) async {
        final haptics = _recordHaptics(tester);
        final barrier = Completer<void>();
        final pending = phase == 'pending rejection';
        final harness = _PasswordResetHarness(
          verifyFails: pending,
          verifyBarrier: pending ? barrier.future : null,
        );
        await tester.pumpWidget(harness.app());
        await _requestCode(tester);
        await tester.enterText(_otp, '123456');
        await _tapCodeVerification(tester);
        if (phase == 'glide') {
          await tester.pump(const Duration(milliseconds: 310));
          expect(
            find.byKey(const Key('password-reset-success-glide')),
            findsWidgets,
          );
        }
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        if (pending) barrier.complete();
        await tester.pump(const Duration(seconds: 1));
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pumpAndSettle();
        expect(find.text('Create a new password'), findsNothing);
        expect(_codeInput(tester).verified, isFalse);
        expect(_codeInput(tester).rejected, isFalse);
        expect(haptics, isEmpty);
        expect(_verifyRequests(harness), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('AppRouter resolves the password-reset destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => AppRouter.onGenerateRoute(
            const RouteSettings(name: AppRoutes.passwordReset),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(PasswordResetScreen), findsOneWidget);
    expect(find.text('Forgot your password?'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byKey(const Key('password-reset-back-to-login')), findsNothing);
  });

  testWidgets(
    'one shared bear keeps its mailbox until password entry and protects both fields',
    (tester) async {
      final harness = _PasswordResetHarness();
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VerificationFriend>(find.byType(VerificationFriend))
            .showMailbox,
        isTrue,
      );
      expect(
        tester
            .widget<VerificationFriend>(find.byType(VerificationFriend))
            .eyesClosed,
        isFalse,
      );
      await _requestCode(tester);
      expect(
        tester
            .widget<VerificationFriend>(find.byType(VerificationFriend))
            .showMailbox,
        isTrue,
      );
      await _fillConfirmation(tester);
      expect(
        find.byKey(const Key('verification-friend-mailbox')),
        findsNothing,
      );
      expect(
        tester
            .widget<VerificationFriend>(find.byType(VerificationFriend))
            .eyesClosed,
        isTrue,
      );
      expect(
        find.byKey(const Key('verification-friend-closed-eyelid')),
        findsNWidgets(2),
      );
      await tester.ensureVisible(find.text('Create a new password'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a new password'));
      await tester.pump();
      var eyeAnimation = tester.widget<TweenAnimationBuilder<double>>(
        find.byKey(const Key('verification-friend-eye-animation')),
      );
      expect(eyeAnimation.duration, const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VerificationFriend>(find.byType(VerificationFriend))
            .eyesClosed,
        isFalse,
      );
      expect(
        find.byKey(const Key('verification-friend-closed-eyelid')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const Key('password-reset-confirm-password-field')),
      );
      await tester.tap(
        find.byKey(const Key('password-reset-confirm-password-field')),
      );
      await tester.pump();
      eyeAnimation = tester.widget<TweenAnimationBuilder<double>>(
        find.byKey(const Key('verification-friend-eye-animation')),
      );
      expect(eyeAnimation.duration, const Duration(milliseconds: 190));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VerificationFriend>(find.byType(VerificationFriend))
            .eyesClosed,
        isTrue,
      );
      expect(
        find.byKey(const Key('verification-friend-closed-eyelid')),
        findsNWidgets(2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('password bear eye changes honor reduced motion', (tester) async {
    final harness = _PasswordResetHarness();
    await tester.pumpWidget(harness.app(reduceMotion: true));
    await _requestCode(tester);
    await _fillConfirmation(tester);
    expect(
      tester
          .widget<VerificationFriend>(find.byType(VerificationFriend))
          .reduceMotion,
      isTrue,
    );
    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find.byKey(const Key('verification-friend-eye-animation')),
          )
          .duration,
      Duration.zero,
    );
    expect(
      find.byKey(const Key('verification-friend-closed-eyelid')),
      findsNWidgets(2),
    );
    await tester.ensureVisible(find.text('Create a new password'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a new password'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('verification-friend-closed-eyelid')),
      findsNothing,
    );
    expect(
      tester
          .widget<VerificationFriend>(find.byType(VerificationFriend))
          .eyesClosed,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'password fields keep floating labels in outlined gaps without prefix icons',
    (tester) async {
      final harness = _PasswordResetHarness();
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await _fillConfirmation(tester);
      for (final entry in [
        ('password-reset-new-password-field', 'New password'),
        ('password-reset-confirm-password-field', 'Confirm new password'),
      ]) {
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(Key(entry.$1)),
            matching: find.byType(TextField),
          ),
        );
        final decoration = field.decoration!;
        expect(decoration.floatingLabelBehavior, FloatingLabelBehavior.always);
        expect(decoration.labelText, entry.$2);
        expect(decoration.filled, isFalse);
        expect(decoration.hintText, isNull);
        expect(decoration.prefixIcon, isNull);
        expect(decoration.suffixIcon, isNotNull);
        expect(decoration.border, isA<OutlineInputBorder>());
        expect(
          (decoration.border! as OutlineInputBorder).gapPadding,
          greaterThan(0),
        );
        expect(field.obscureText, isTrue);
        expect(field.autocorrect, isFalse);
        expect(field.autofillHints, contains(AutofillHints.newPassword));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('requests a generic reset challenge with normalized email', (
    tester,
  ) async {
    final harness = _PasswordResetHarness(
      requestDetail: 'A deliberately account-specific server message.',
    );

    await tester.pumpWidget(harness.app());
    await tester.enterText(
      find.byKey(const Key('password-reset-email-field')),
      '  PARENT@EXAMPLE.COM  ',
    );
    await tester.tap(find.byKey(const Key('password-reset-request-button')));
    await tester.pumpAndSettle();

    final request = harness.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/accounts/password-reset/request/');
    expect(request.headers.containsKey('authorization'), isFalse);
    expect(jsonDecode(request.body), {'email': 'parent@example.com'});
    expect(find.text(passwordResetGenericRequestMessage), findsNothing);
    expect(
      find.text('A deliberately account-specific server message.'),
      findsNothing,
    );
    expect(find.textContaining('PARENT@EXAMPLE.COM'), findsNothing);
    expect(find.text('Code expires in 5:00'), findsOneWidget);
    expect(find.byKey(const Key('password-reset-code-field')), findsOneWidget);
    expect(
      find.byKey(const Key('password-reset-new-password-field')),
      findsNothing,
    );
  });

  testWidgets('validates numeric code and matching passwords before POST', (
    tester,
  ) async {
    final harness = _PasswordResetHarness();
    await tester.pumpWidget(harness.app());
    await _requestCode(tester);

    await tester.enterText(
      find.byKey(const Key('password-reset-code-field')),
      '12ab3456',
    );
    final codeField = tester.widget<VerificationCodeInput>(
      find.byKey(const Key('password-reset-code-field')),
    );
    expect(codeField.controller.text, '123456');
    await _tapCodeVerification(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('password-reset-new-password-field')),
      'New-Correct-Horse-Battery-Staple-2026!',
    );
    await tester.enterText(
      find.byKey(const Key('password-reset-confirm-password-field')),
      'different-password',
    );
    final confirmButton = find.byKey(
      const Key('password-reset-confirm-button'),
    );
    await tester.ensureVisible(confirmButton);
    await tester.pump();
    await tester.tap(confirmButton);
    await tester.pump();

    expect(find.text('The new passwords do not match.'), findsOneWidget);
    expect(
      harness.requests.where(
        (request) =>
            request.url.path == '/api/accounts/password-reset/confirm/',
      ),
      isEmpty,
    );
  });

  testWidgets(
    'reset reuses signup OTP slots with paste, autofill and keyboard submission',
    (tester) async {
      final harness = _PasswordResetHarness();
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      final otp = find.byKey(const Key('password-reset-code-field'));
      expect(find.byType(VerificationCodeInput), findsOneWidget);
      expect(
        find.descendant(of: otp, matching: find.byType(AnimatedContainer)),
        findsNWidgets(6),
      );
      final native = tester.widget<TextField>(
        find.descendant(of: otp, matching: find.byType(TextField)),
      );
      expect(native.keyboardType, TextInputType.number);
      expect(native.autofillHints, contains(AutofillHints.oneTimeCode));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('password-reset-verify-button')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(otp, '12a345');
      await tester.pumpAndSettle();
      for (final digit in ['1', '2', '3', '4', '5']) {
        expect(find.text(digit), findsOneWidget);
      }
      expect(
        harness.requests.where(
          (request) => request.url.path.endsWith('/verify/'),
        ),
        isEmpty,
      );
      await tester.enterText(otp, '12a3456789');
      expect(
        tester.widget<VerificationCodeInput>(otp).controller.text,
        '123456',
      );
      // Done and the queued completion share one in-flight submission.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Create a new password'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.url.path.endsWith('/verify/'),
        ),
        hasLength(1),
      );
    },
  );

  testWidgets('shows the safe invalid-or-expired error and preserves session', (
    tester,
  ) async {
    final harness = _PasswordResetHarness(confirmFails: true);
    await harness.seedStaleSession();
    await tester.pumpWidget(harness.app());
    await _requestCode(tester);
    await _fillConfirmation(tester);

    final confirmButton = find.byKey(
      const Key('password-reset-confirm-button'),
    );
    await tester.ensureVisible(confirmButton);
    await tester.pump();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    expect(
      find.text('That password reset code is incorrect or has expired.'),
      findsOneWidget,
    );
    expect(await harness.store.readSession(), isNotNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(
      harness.requests.where(
        (request) => request.url.path.endsWith('/verify/'),
      ),
      hasLength(1),
    );
    expect(await harness.store.readSelectedKidId(), 'kid-1');
    final codeField = tester.widget<VerificationCodeInput>(
      find.byKey(const Key('password-reset-code-field')),
    );
    expect(codeField.controller.text, isEmpty);
    expect(harness.routedSettings, isEmpty);
  });

  testWidgets('a rejected server code never opens the password page', (
    tester,
  ) async {
    final harness = _PasswordResetHarness(verifyFails: true);
    await harness.seedStaleSession();
    await tester.pumpWidget(harness.app());
    await _requestCode(tester);
    await _verifyCode(tester);
    expect(find.text('Check your email'), findsOneWidget);
    expect(
      find.byKey(const Key('password-reset-new-password-field')),
      findsNothing,
    );
    expect(
      find.text('That password reset code is incorrect or has expired.'),
      findsNothing,
    );
    final code = tester.widget<VerificationCodeInput>(
      find.byKey(const Key('password-reset-code-field')),
    );
    expect(code.controller.text, isEmpty);
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('password-reset-code-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(await harness.store.readSession(), isNotNull);
    expect(
      harness.requests.where(
        (request) => request.url.path.endsWith('/confirm/'),
      ),
      isEmpty,
    );
  });

  testWidgets(
    'password entry waits for server proof and exposes only reset action',
    (tester) async {
      final barrier = Completer<void>();
      final harness = _PasswordResetHarness(verifyBarrier: barrier.future);
      await harness.seedStaleSession();
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await tester.enterText(
        find.byKey(const Key('password-reset-code-field')),
        '123456',
      );
      final button = find.byKey(const Key('password-reset-verify-button'));
      await _tapCodeVerification(tester);
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(
        find.byKey(const Key('password-reset-new-password-field')),
        findsNothing,
      );
      expect(
        harness.requests.where(
          (request) => request.url.path.endsWith('/verify/'),
        ),
        hasLength(1),
      );
      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.text('Create a new password'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byKey(const Key('password-reset-code-field')), findsNothing);
      expect(
        find.byKey(const Key('password-reset-request-another-button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('password-reset-use-different-email')),
        findsNothing,
      );
      final verification = harness.requests.singleWhere(
        (request) => request.url.path.endsWith('/verify/'),
      );
      expect(jsonDecode(verification.body), {
        'challenge_id': '11111111-1111-4111-8111-111111111111',
        'code': '123456',
      });
      expect(verification.headers.containsKey('authorization'), isFalse);
      expect(await harness.store.readSession(), isNotNull);
    },
  );

  testWidgets(
    'a late reset verification result cannot open a disposed password page',
    (tester) async {
      final barrier = Completer<void>();
      final harness = _PasswordResetHarness(verifyBarrier: barrier.future);
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await tester.enterText(
        find.byKey(const Key('password-reset-code-field')),
        '123456',
      );
      await _tapCodeVerification(tester);
      expect(
        harness.requests.where(
          (request) => request.url.path.endsWith('/verify/'),
        ),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      barrier.complete();
      await tester.pumpAndSettle();
      expect(harness.routedSettings, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expiry during password entry returns to the code page without resetting',
    (tester) async {
      final harness = _PasswordResetHarness(
        challenges: const [
          _Challenge('11111111-1111-4111-8111-111111111111', 5),
        ],
      );
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await _fillConfirmation(tester);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.text('Check your email'), findsOneWidget);
      expect(
        find.byKey(const Key('password-reset-new-password-field')),
        findsNothing,
      );
      expect(
        find.text('This code has expired. Request another code to continue.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('password-reset-request-another-button')),
        findsOneWidget,
      );
      expect(
        harness.requests.where(
          (request) => request.url.path.endsWith('/confirm/'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'a code expiring during verification cannot advance after a late success',
    (tester) async {
      final barrier = Completer<void>();
      final harness = _PasswordResetHarness(
        verifyBarrier: barrier.future,
        challenges: const [
          _Challenge('11111111-1111-4111-8111-111111111111', 3),
        ],
      );
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await tester.enterText(
        find.byKey(const Key('password-reset-code-field')),
        '123456',
      );
      await _tapCodeVerification(tester);
      expect(
        harness.requests.where(
          (request) => request.url.path.endsWith('/verify/'),
        ),
        hasLength(1),
      );
      await tester.pump(const Duration(seconds: 4));
      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.text('Check your email'), findsOneWidget);
      expect(
        find.byKey(const Key('password-reset-new-password-field')),
        findsNothing,
      );
      expect(
        find.text('This code has expired. Request another code to continue.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'back from new password returns to code and clears transient passwords',
    (tester) async {
      final harness = _PasswordResetHarness();
      await tester.pumpWidget(harness.app());
      await _requestCode(tester);
      await _fillConfirmation(tester);
      await tester.ensureVisible(
        find.byKey(const Key('password-reset-back-button')),
      );
      await tester.tap(find.byKey(const Key('password-reset-back-button')));
      await tester.pumpAndSettle();
      expect(find.text('Check your email'), findsOneWidget);
      await _verifyCode(tester);
      final password = tester.widget<TextFormField>(
        find.byKey(const Key('password-reset-new-password-field')),
      );
      expect(password.controller?.text, isEmpty);
      expect(
        harness.requests.where(
          (request) => request.url.path.endsWith('/request/'),
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'another-code replaces the challenge and success clears auth then logs in',
    (tester) async {
      final harness = _PasswordResetHarness(
        challenges: const [
          _Challenge('11111111-1111-4111-8111-111111111111', 300),
          _Challenge('22222222-2222-4222-8222-222222222222', 900),
        ],
      );
      await harness.seedStaleSession();
      await tester.pumpWidget(harness.app());
      await _requestCode(tester, email: 'Parent@Example.com');

      final anotherButton = find.byKey(
        const Key('password-reset-request-another-button'),
      );
      await tester.ensureVisible(anotherButton);
      await tester.pump();
      await tester.tap(anotherButton);
      await tester.pumpAndSettle();

      expect(find.text(passwordResetGenericRequestMessage), findsNothing);
      expect(find.text('Code expires in 15:00'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) =>
              request.url.path == '/api/accounts/password-reset/request/',
        ),
        hasLength(2),
      );
      await _fillConfirmation(tester);
      final confirmButton = find.byKey(
        const Key('password-reset-confirm-button'),
      );
      await tester.ensureVisible(confirmButton);
      await tester.pump();
      await tester.tap(confirmButton);
      await tester.pumpAndSettle();

      final confirmation = harness.requests.singleWhere(
        (request) =>
            request.url.path == '/api/accounts/password-reset/confirm/',
      );
      expect(jsonDecode(confirmation.body), {
        'challenge_id': '22222222-2222-4222-8222-222222222222',
        'code': '123456',
        'new_password': 'New-Correct-Horse-Battery-Staple-2026!',
        'new_password_confirmation': 'New-Correct-Horse-Battery-Staple-2026!',
      });
      expect(await harness.store.readSession(), isNull);
      expect(await harness.store.readSelectedKidId(), isNull);
      expect(harness.routedSettings.last.name, AppRoutes.login);
      expect(harness.routedSettings.last.arguments, isNull);
      expect(find.text('Login route reached'), findsOneWidget);
    },
  );

  testWidgets('countdown expires locally and another request restores it', (
    tester,
  ) async {
    final harness = _PasswordResetHarness(
      challenges: const [
        _Challenge('11111111-1111-4111-8111-111111111111', 2),
        _Challenge('22222222-2222-4222-8222-222222222222', 60),
      ],
    );
    await tester.pumpWidget(harness.app());
    await _requestCode(tester);
    expect(find.text('Code expires in 0:02'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));

    expect(find.text('Code expired — request another code'), findsOneWidget);
    final disabledConfirm = tester.widget<FilledButton>(
      find.byKey(const Key('password-reset-verify-button')),
    );
    expect(disabledConfirm.onPressed, isNull);

    final anotherButton = find.byKey(
      const Key('password-reset-request-another-button'),
    );
    await tester.ensureVisible(anotherButton);
    await tester.pump();
    await tester.tap(anotherButton);
    await tester.pumpAndSettle();

    expect(find.text('Code expires in 1:00'), findsOneWidget);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'reset forms remain reachable on compact large-text keyboard view in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 210);
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final harness = _PasswordResetHarness();
        await tester.pumpWidget(harness.app(brightness: brightness));
        await tester.ensureVisible(
          find.byKey(const Key('password-reset-email-field')),
        );
        await tester.enterText(
          find.byKey(const Key('password-reset-email-field')),
          'parent@example.com',
        );
        await tester.ensureVisible(
          find.byKey(const Key('password-reset-request-button')),
        );
        await tester.tap(
          find.byKey(const Key('password-reset-request-button')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const Key('password-reset-code-field')),
        );
        await tester.enterText(
          find.byKey(const Key('password-reset-code-field')),
          '123456',
        );
        await tester.pumpAndSettle();
        await _tapCodeVerification(tester);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('password-reset-new-password-field')),
        );
        await tester.enterText(
          find.byKey(const Key('password-reset-new-password-field')),
          'Dummy-new-password-123!',
        );
        await tester.ensureVisible(
          find.byKey(const Key('password-reset-confirm-password-field')),
        );
        await tester.enterText(
          find.byKey(const Key('password-reset-confirm-password-field')),
          'Different-dummy-password!',
        );
        await tester.ensureVisible(
          find.byKey(const Key('password-reset-confirm-button')),
        );
        await tester.tap(
          find.byKey(const Key('password-reset-confirm-button')),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('The new passwords do not match.'), findsOneWidget);
        expect(
          harness.requests.where(
            (request) => request.url.path.endsWith('/confirm/'),
          ),
          isEmpty,
        );
        final password = tester.widget<TextFormField>(
          find.byKey(const Key('password-reset-new-password-field')),
        );
        expect(password.controller?.text, 'Dummy-new-password-123!');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

final _otp = find.byKey(const Key('password-reset-code-field'));

VerificationCodeInput _codeInput(WidgetTester tester) =>
    tester.widget<VerificationCodeInput>(_otp);

Iterable<http.Request> _verifyRequests(_PasswordResetHarness harness) =>
    harness.requests.where((request) => request.url.path.endsWith('/verify/'));

List<Object?> _recordHaptics(WidgetTester tester) {
  final events = <Object?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') events.add(call.arguments);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return events;
}

Future<void> _requestCode(
  WidgetTester tester, {
  String email = 'parent@example.com',
}) async {
  await tester.enterText(
    find.byKey(const Key('password-reset-email-field')),
    email,
  );
  await tester.tap(find.byKey(const Key('password-reset-request-button')));
  await tester.pumpAndSettle();
}

Future<void> _fillConfirmation(WidgetTester tester) async {
  await _verifyCode(tester);
  expect(find.byKey(const Key('password-reset-code-field')), findsNothing);
  expect(
    find.byKey(const Key('password-reset-request-another-button')),
    findsNothing,
  );
  expect(
    find.byKey(const Key('password-reset-use-different-email')),
    findsNothing,
  );
  await tester.enterText(
    find.byKey(const Key('password-reset-new-password-field')),
    'New-Correct-Horse-Battery-Staple-2026!',
  );
  await tester.enterText(
    find.byKey(const Key('password-reset-confirm-password-field')),
    'New-Correct-Horse-Battery-Staple-2026!',
  );
}

Future<void> _tapCodeVerification(WidgetTester tester) async {
  // Completing the sixth digit schedules verification after the next frame.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

Future<void> _verifyCode(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('password-reset-code-field')),
    '123456',
  );
  await _tapCodeVerification(tester);
  await tester.pumpAndSettle();
}

class _PasswordResetHarness {
  _PasswordResetHarness({
    this.confirmFails = false,
    this.verifyFails = false,
    this.verifyNetworkFails = false,
    this.verifyBarrier,
    this.requestDetail = passwordResetGenericRequestMessage,
    this.challenges = const [
      _Challenge('11111111-1111-4111-8111-111111111111', 300),
    ],
  }) {
    client = MockClient(_respond);
    repository = AuthRepository(
      api: HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: client,
      ),
      sessionStore: store,
    );
  }

  final bool confirmFails;
  final bool verifyFails;
  final bool verifyNetworkFails;
  final Future<void>? verifyBarrier;
  final String requestDetail;
  final List<_Challenge> challenges;
  final MemoryAuthSessionStore store = MemoryAuthSessionStore();
  final List<http.Request> requests = [];
  final List<RouteSettings> routedSettings = [];
  final navigator = GlobalKey<NavigatorState>();
  late final http.Client client;
  late final AuthRepository repository;
  int _requestCount = 0;

  Future<void> seedStaleSession() async {
    await store.writeSession(
      const AuthSession(
        parent: ParentAccount(id: 'parent-1', email: 'stale@example.com'),
        accessToken: 'stale-access',
        refreshToken: 'stale-refresh',
      ),
    );
    await store.writeSelectedKidId('kid-1');
  }

  Widget app({
    Brightness brightness = Brightness.light,
    bool reduceMotion = false,
  }) {
    return MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [appRouteObserver],
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: PasswordResetScreen(repository: repository),
      onGenerateRoute: (settings) {
        routedSettings.add(settings);
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const Scaffold(body: Text('Login route reached')),
        );
      },
    );
  }

  Future<http.Response> _respond(http.Request request) async {
    requests.add(request);
    switch ((request.method, request.url.path)) {
      case ('POST', '/api/accounts/password-reset/request/'):
        final challenge =
            challenges[_requestCount < challenges.length
                ? _requestCount
                : challenges.length - 1];
        _requestCount += 1;
        return http.Response(
          jsonEncode({
            'detail': requestDetail,
            'challenge_id': challenge.id,
            'expires_in': challenge.expiresInSeconds,
          }),
          202,
        );
      case ('POST', '/api/accounts/password-reset/verify/'):
        await verifyBarrier;
        if (verifyFails) return _invalidCodeResponse();
        if (verifyNetworkFails) {
          return http.Response(
            jsonEncode({'detail': 'Please try again later.'}),
            503,
          );
        }
        return http.Response('', 204);
      case ('POST', '/api/accounts/password-reset/confirm/'):
        if (confirmFails) {
          return _invalidCodeResponse();
        }
        return http.Response('', 204);
      default:
        return http.Response(
          jsonEncode({'detail': 'Unexpected test request.'}),
          500,
        );
    }
  }
}

http.Response _invalidCodeResponse() => http.Response(
  jsonEncode({
    'code': 'invalid_or_expired_password_reset',
    'detail': 'That password reset code is incorrect or has expired.',
  }),
  400,
);

class _Challenge {
  const _Challenge(this.id, this.expiresInSeconds);

  final String id;
  final int expiresInSeconds;
}
