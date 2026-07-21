import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app.dart';
import 'package:mobile/app/router.dart';

void main() {
  testWidgets('shows the image-led introduction and opens parent setup', (
    tester,
  ) async {
    await tester.pumpWidget(
      const KingdomKidsApp(initialRoute: AppRoutes.onboarding),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Big Bible adventures begin here'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/onboarding/story-explorer-v2.png',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_forward_rounded), findsNothing);
    expect(find.text('Kingdom Kids'), findsNothing);
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Skip'), findsOneWidget);

    await _advance(tester);
    expect(find.text('Watch wonder unfold').hitTestable(), findsOneWidget);

    await _advance(tester);
    expect(find.text('Grow, play, and shine').hitTestable(), findsOneWidget);
    expect(find.text("Let's go").hitTestable(), findsOneWidget);

    await tester.tap(find.text("Let's go"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('A joyful place starts with you'), findsOneWidget);
  });

  testWidgets('keeps the first screen usable with large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: KingdomKidsApp(initialRoute: AppRoutes.onboarding),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Big Bible adventures begin here'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _advance(WidgetTester tester) async {
  await tester.fling(find.byType(PageView), const Offset(-650, 0), 1200);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump();
}
