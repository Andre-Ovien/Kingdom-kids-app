import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/domain/password_reset.dart';
import 'package:mobile/features/auth/domain/email_verification.dart';
import 'package:mobile/features/auth/presentation/email_verification_screen.dart';
import 'package:mobile/features/auth/presentation/password_reset_screen.dart';
import 'package:mobile/features/auth/presentation/verification_code_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Render with the same native font used by the iPhone app, rather than
    // Flutter tests' deliberately square Ahem glyphs. No fonts are bundled anew.
    final avenir = File('/System/Library/Fonts/Avenir Next.ttc');
    final icons = File(
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (avenir.existsSync()) {
      await (FontLoader('Avenir Next')..addFont(
            Future.value(ByteData.sublistView(await avenir.readAsBytes())),
          ))
          .load();
    }
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          ))
          .load();
    }
  });

  testWidgets('render the original signup verification frame for comparison', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final output = Directory(
      '${Directory.current.parent.parent.path}/output/password-reset-20261108',
    )..createSync(recursive: true);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKingdomKidsTheme(),
        home: RepaintBoundary(
          key: key,
          child: const EmailVerificationScreen(
            pending: PendingEmailVerification(
              challengeId: 'dummy-signup-preview',
              email: 'parent@example.com',
              destinationHint: 'pa••••@example.com',
              expiresInSeconds: 600,
              resendAfterSeconds: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const phase = String.fromEnvironment(
      'VERIFICATION_FRAME_PHASE',
      defaultValue: 'shared',
    );
    await _capture(tester, key, '${output.path}/signup-$phase-393x852.png');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('render the three dedicated password recovery steps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final output = Directory(
      '${Directory.current.parent.parent.path}/output/password-reset-20261108',
    )..createSync(recursive: true);
    final boundary = GlobalKey();
    final repository = _PreviewResetRepository();
    Widget app() => MaterialApp(
      theme: buildKingdomKidsTheme(),
      home: RepaintBoundary(
        key: boundary,
        child: PasswordResetScreen(repository: repository),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Forgot your password?'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('password-reset-email-field')),
      'parent@example.com',
    );
    await tester.tap(find.byKey(const Key('password-reset-request-button')));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const Key('password-reset-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text(passwordResetGenericRequestMessage), findsNothing);
    expect(find.byType(VerificationCodeInput), findsOneWidget);
    expect(
      find.byKey(const Key('password-reset-new-password-field')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const Key('password-reset-code-field')),
      '12345',
    );
    await tester.pumpAndSettle();
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
    await _capture(tester, boundary, '${output.path}/code-v6-bear-393x852.png');
    expect(
      tester
          .getTopLeft(
            find.byKey(const Key('password-reset-use-different-email')),
          )
          .dy,
      greaterThan(
        tester
            .getTopLeft(
              find.byKey(const Key('password-reset-request-another-button')),
            )
            .dy,
      ),
    );
    await tester.enterText(
      find.byKey(const Key('password-reset-code-field')),
      '123456',
    );
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final passwordScroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const Key('password-reset-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    passwordScroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    await _capture(
      tester,
      boundary,
      '${output.path}/new-password-v8-rounded-393x852.png',
    );
    expect(find.byKey(const Key('password-reset-code-field')), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) =>
    tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });

class _PreviewResetRepository extends AuthRepository {
  _PreviewResetRepository() : super(sessionStore: MemoryAuthSessionStore());

  @override
  Future<void> verifyPasswordResetCode(
    PasswordResetVerifyRequest request,
  ) async {}

  @override
  Future<PendingPasswordReset> requestPasswordReset(
    PasswordResetRequest request,
  ) async => const PendingPasswordReset(
    challengeId: 'dummy-preview-challenge',
    expiresInSeconds: 300,
  );

  @override
  Future<void> confirmPasswordReset(PasswordResetConfirmRequest request) =>
      throw StateError('The visual preview cannot submit a password.');
}
