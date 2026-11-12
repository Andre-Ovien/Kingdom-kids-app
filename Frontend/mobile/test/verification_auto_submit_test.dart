import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/features/auth/presentation/verification_page.dart';

void main() {
  testWidgets(
    'server-cleared code can be re-entered identically without a button',
    (tester) async {
      final controller = TextEditingController(), focus = FocusNode();
      var calls = 0;
      await tester.pumpWidget(
        _app(controller, focus, () async {
          calls++;
          controller.clear();
        }),
      );
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(controller.text, isEmpty);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );

  testWidgets(
    'incomplete correction re-arms an unchanged completed code once',
    (tester) async {
      final controller = TextEditingController(), focus = FocusNode();
      var calls = 0;
      await tester.pumpWidget(
        _app(controller, focus, () async {
          calls++;
        }),
      );
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '12345');
      await tester.pump();
      expect(calls, 1);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(calls, 2);
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );

  testWidgets(
    'duplicate clear-and-fill while pending never duplicates the request',
    (tester) async {
      final controller = TextEditingController(), focus = FocusNode();
      final barrier = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        _app(controller, focus, () {
          calls++;
          return barrier.future;
        }),
      );
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      expect(calls, 1);
      controller.clear();
      controller.text = '123456';
      await tester.pump();
      expect(calls, 1);
      barrier.complete();
      await tester.pumpAndSettle();
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pumpAndSettle();
      expect(calls, 1);
      controller.clear();
      await tester.pump();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );

  testWidgets('rapid code replacement checks the latest value once', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    final submitted = <String>[];
    await tester.pumpWidget(
      _app(controller, focus, () async {
        submitted.add(controller.text);
      }),
    );
    await tester.pumpAndSettle();
    controller.text = '123456';
    controller.text = '654321';
    await tester.pumpAndSettle();
    expect(submitted, ['654321']);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
  });
  testWidgets(
    'typing checks only the sixth digit; Done, rebuild and button cannot duplicate it',
    (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final barrier = Completer<void>();
      var calls = 0;
      Future<void> submit() {
        calls++;
        return barrier.future;
      }

      Widget app() => _app(controller, focus, submit);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      for (final partial in ['1', '12', '123', '1234', '12345']) {
        await tester.enterText(find.byType(TextField), partial);
        await tester.pump();
        expect(calls, 0);
      }
      await tester.enterText(find.byType(TextField), '123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('verification-submit-button')),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(app());
      await tester.pump();
      expect(calls, 1);
      barrier.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 1);
      // A manual retry remains possible for the same rejected/network-failed code.
      tester
          .widget<FilledButton>(
            find.byKey(const Key('verification-submit-button')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(calls, 2);
      await tester.enterText(find.byType(TextField), '123457');
      await tester.pumpAndSettle();
      expect(calls, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );

  testWidgets(
    'resend cancels queued completion and only fresh digits use the replacement challenge',
    (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final calls = <String>[];
      var challenge = 'first';
      Widget app() => _app(
        controller,
        focus,
        () async {
          calls.add(challenge);
        },
        challenge: challenge,
        onResend: () {
          controller.clear();
          challenge = 'second';
        },
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      tester
          .widget<TextButton>(
            find.byKey(const Key('verification-resend-button')),
          )
          .onPressed!();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.enterText(find.byType(TextField), '654321');
      await tester.pumpAndSettle();
      expect(calls, ['second']);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );

  testWidgets(
    'a covered route cancels queued completion without submitting on return',
    (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final navigator = GlobalKey<NavigatorState>();
      var calls = 0;
      await tester.pumpWidget(
        _app(controller, focus, () async {
          calls++;
        }, navigator: navigator),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );

  testWidgets('expiry and disposal cancel a pending completion', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    var calls = 0;
    await tester.pumpWidget(
      _app(controller, focus, () async {
        calls++;
      }),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpWidget(
      _app(controller, focus, () async {
        calls++;
      }, expiresAt: DateTime.utc(2020)),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    controller.clear();
    await tester.pumpWidget(
      _app(controller, focus, () async {
        calls++;
      }),
    );
    await tester.enterText(find.byType(TextField), '654321');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls, 0);
    controller.dispose();
    focus.dispose();
  });

  testWidgets(
    'backgrounding cancels queued completion until a fresh edit or manual retry',
    (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      var calls = 0;
      addTearDown(() => _resume(tester));
      await tester.pumpWidget(
        _app(controller, focus, () async {
          calls++;
        }),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      _resume(tester);
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.enterText(find.byType(TextField), '654321');
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    },
  );
}

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

Widget _app(
  TextEditingController controller,
  FocusNode focus,
  Future<void> Function() submit, {
  String challenge = 'first',
  VoidCallback? onResend,
  GlobalKey<NavigatorState>? navigator,
  DateTime? expiresAt,
}) => MaterialApp(
  navigatorKey: navigator,
  navigatorObservers: [appRouteObserver],
  home: VerificationPage(
    controller: controller,
    focusNode: focus,
    heading: 'Check your email',
    description: 'Enter six digits.',
    challengeKey: challenge,
    autoSubmitExpiresAt: expiresAt,
    onSubmit: submit,
    onBack: () {},
    onResend: onResend ?? () {},
    resendLabel: 'Resend',
    resendEnabled: true,
  ),
);
