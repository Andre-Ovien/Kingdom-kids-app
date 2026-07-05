import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/app/app.dart';

void main() {
  Future<void> enterHome(WidgetTester tester) async {
    await tester.pumpWidget(const KingdomKidsApp());
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.tap(find.byKey(const Key('streak-close-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the app open streak celebration before entering home', (
    tester,
  ) async {
    await tester.pumpWidget(const KingdomKidsApp());
    await tester.pump(const Duration(milliseconds: 2000));

    expect(find.text('5 day streak!'), findsOneWidget);
    expect(find.text('Keep going to unlock more badges.'), findsOneWidget);
    expect(find.byKey(const Key('streak-close-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('streak-close-button')));
    await tester.pumpAndSettle();

    expect(find.text('Hello, Ethan'), findsOneWidget);
  });

  testWidgets('shows the Kingdom Kids home shell', (tester) async {
    await enterHome(tester);

    expect(find.text('Hello, Ethan'), findsOneWidget);
    expect(find.text('Good morning'), findsOneWidget);
    expect(find.text('David & Goliath'), findsOneWidget);
    expect(find.text('Start Reading'), findsOneWidget);
    expect(find.text('Continue reading'), findsOneWidget);
    expect(find.text('Stories'), findsWidgets);
    expect(find.text('Watch'), findsWidgets);
    expect(find.text('Games'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('New stories'),
      220,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('New stories'), findsOneWidget);
  });

  testWidgets('opens story detail from the home hero button', (tester) async {
    await enterHome(tester);

    await tester.tap(find.text('Start Reading').first);
    await tester.pumpAndSettle();

    expect(find.text('David & Goliath'), findsOneWidget);
    expect(find.text('Kingdom Kids'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
  });

  testWidgets('opens a local game detail without backend', (tester) async {
    await enterHome(tester);

    await tester.tap(find.text('Games').last);
    await tester.pumpAndSettle();

    expect(find.text('TODAY\'S QUEST'), findsOneWidget);
    expect(find.text('Quick Bible Games'), findsOneWidget);

    await tester.tap(find.text('Play').first);
    await tester.pumpAndSettle();

    expect(find.text('Match the Ark Animals'), findsWidgets);
    expect(find.text('Resume Game'), findsOneWidget);

    await tester.drag(find.byType(Scrollable).last, const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume Game'));
    await tester.pumpAndSettle();

    expect(find.text('Ready'), findsOneWidget);
  });
}
