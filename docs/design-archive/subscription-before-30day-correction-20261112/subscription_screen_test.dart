import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/privacy/presentation/privacy_policy_screen.dart';
import 'package:mobile/features/subscription/presentation/subscription_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final fonts =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in fonts.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load((font as Map)['asset'] as String));
      }
      await loader.load();
    }
  });

  testWidgets('switches the actual price and example renewal disclosure', (
    tester,
  ) async {
    await _pump(tester, reviewMode: true);
    expect(find.text(r'Today · $9.99 USD'), findsOneWidget);
    expect(find.text(r'28 Nov · $9.99 USD'), findsOneWidget);
    expect(find.byKey(const Key('subscription-review-notice')), findsOneWidget);

    await tester.tap(find.byKey(const Key('subscription-yearly')));
    await tester.pumpAndSettle();
    expect(find.text(r'Today · $107.89 USD'), findsOneWidget);
    expect(find.text(r'28 Nov 2027 · $107.89 USD'), findsOneWidget);
    expect(find.text('Every 28 Nov after that'), findsOneWidget);
    expect(find.text(r'Today · $9.99 USD'), findsNothing);

    await tester.tap(find.byKey(const Key('subscription-monthly')));
    await tester.pumpAndSettle();
    expect(find.text(r'28 Nov · $9.99 USD'), findsOneWidget);
    expect(
      find.textContaining('first two full payments may be close'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'normal screen does not present local examples as purchase dates',
    (tester) async {
      await _pump(tester);
      expect(
        find.byKey(const Key('subscription-unavailable-notice')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('subscription-review-notice')), findsNothing);
      expect(find.text(r'Next 28th · $9.99 USD'), findsOneWidget);
      expect(find.textContaining('28 Nov'), findsNothing);
      await tester.tap(find.byKey(const Key('subscription-yearly')));
      await tester.pumpAndSettle();
      expect(find.text(r'28th next year · $107.89 USD'), findsOneWidget);
      expect(find.textContaining('2027'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final outerBrightness in Brightness.values) {
    testWidgets(
      'both plans remain readable at 320px and 2.2x in ${outerBrightness.name} shell',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pump(
          tester,
          reviewMode: true,
          textScale: 2.2,
          outerBrightness: outerBrightness,
        );
        expect(
          Theme.of(
            tester.element(find.byKey(const Key('subscription-monthly'))),
          ).brightness,
          Brightness.light,
        );
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(
          find.byKey(const Key('subscription-yearly')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('subscription-yearly')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Every 28 Nov after that'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .getRect(find.text('Every 28 Nov after that'))
              .overlaps(
                tester.getRect(find.byKey(const Key('subscription-scroll'))),
              ),
          isTrue,
        );

        final details = find.byKey(const Key('subscription-billing-details'));
        final privacy = find.byKey(const Key('subscription-privacy-policy'));
        expect(details.hitTestable(), findsOneWidget);
        expect(privacy.hitTestable(), findsOneWidget);
        await tester.tap(details);
        await tester.pumpAndSettle();
        expect(find.text('Billing details'), findsNWidgets(2));
        expect(
          find.textContaining('Exact dates and the billing timezone'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'checkout is disabled for both plans and exposes disabled semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pump(tester, reviewMode: true);
        final checkout = find.byKey(const Key('subscription-parent-continue'));
        for (final plan in ['monthly', 'yearly']) {
          await tester.tap(find.byKey(Key('subscription-$plan')));
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(checkout).onPressed, isNull);
          final data = tester.getSemantics(checkout).getSemanticsData();
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.flagsCollection.isEnabled, Tristate.isFalse);
          await tester.tap(checkout);
          await tester.pumpAndSettle();
          expect(find.byType(SubscriptionScreen), findsOneWidget);
          expect(find.text('Checkout unavailable'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'privacy opens in app and Back preserves the selected yearly plan',
    (tester) async {
      await _pump(tester, reviewMode: true);
      await tester.tap(find.byKey(const Key('subscription-yearly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('subscription-privacy-policy')));
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
      expect(find.byKey(const Key('privacy-policy-screen')), findsOneWidget);
      await tester.tap(find.byKey(const Key('privacy-policy-back')));
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyPolicyScreen), findsNothing);
      expect(find.text(r'Today · $107.89 USD'), findsOneWidget);
      expect(find.text(r'28 Nov 2027 · $107.89 USD'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'close hands control to the supplied parent-review continuation',
    (tester) async {
      var closed = 0;
      await _pump(tester, reviewMode: true, onClose: () => closed++);
      await tester.tap(find.byKey(const Key('subscription-back')));
      await tester.pumpAndSettle();
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester, {
  bool reviewMode = false,
  double textScale = 1,
  Brightness outerBrightness = Brightness.light,
  VoidCallback? onClose,
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(brightness: outerBrightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: SubscriptionScreen(
      reviewMode: reviewMode,
      previewDate: DateTime.utc(2026, 11, 12),
      onClose: onClose,
    ),
  ),
);
