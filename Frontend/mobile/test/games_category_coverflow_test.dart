import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/games_category_coverflow.dart';

void main() {
  testWidgets(
    'three visible covers loop through five games in both directions',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final games = List.generate(5, _game);
      MiniGame? opened;
      await tester.pumpWidget(_harness(games, onOpen: (game) => opened = game));
      await tester.pumpAndSettle();
      var selectedIndex = 2;
      final selected = find.byKey(const Key('game-coverflow-selected-quiz'));
      for (final direction in [-1, 1]) {
        for (var step = 0; step < 12; step++) {
          await tester.drag(
            find.byKey(const Key('games-coverflow-pages-quiz')),
            Offset(direction * 125, 0),
          );
          await tester.pumpAndSettle();
          selectedIndex = (selectedIndex - direction) % games.length;
          expect(
            find.descendant(
              of: selected,
              matching: find.text('Game $selectedIndex'),
            ),
            findsOneWidget,
          );
          final visible = [
            for (final index in [
              (selectedIndex - 1) % games.length,
              selectedIndex,
              (selectedIndex + 1) % games.length,
            ])
              tester.getRect(
                find
                    .byKey(Key('game-coverflow-image-game-$index'))
                    .hitTestable(),
              ),
          ]..sort((a, b) => a.left.compareTo(b.left));
          for (var index = 1; index < visible.length; index++) {
            expect(
              visible[index].left - visible[index - 1].right,
              greaterThanOrEqualTo(16),
            );
          }
        }
      }
      await tester.tap(
        find.byKey(Key('game-coverflow-play-game-$selectedIndex')),
      );
      expect(identical(opened, games[selectedIndex]), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'three real upright covers have a larger center and never auto-advance',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final games = List.generate(5, _game);
      MiniGame? opened;
      await tester.pumpWidget(_harness(games, onOpen: (game) => opened = game));
      await tester.pumpAndSettle();
      final rectangles = [
        for (var i = 1; i <= 3; i++)
          tester.getRect(find.byKey(Key('game-coverflow-image-game-$i'))),
      ];
      for (var i = 1; i < rectangles.length; i++) {
        expect(
          rectangles[i].left - rectangles[i - 1].right,
          greaterThanOrEqualTo(16),
        );
        expect(rectangles[i].center.dy, closeTo(rectangles[0].center.dy, .1));
      }
      expect(rectangles[1].width, greaterThan(rectangles[0].width));
      expect(rectangles[1].height, greaterThan(rectangles[0].height));
      expect(rectangles[1].width / rectangles[1].height, closeTo(.76, .01));
      final selected = find.byKey(const Key('game-coverflow-selected-quiz'));
      expect(
        find.descendant(of: selected, matching: find.text('Game 2')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 20));
      expect(
        find.descendant(of: selected, matching: find.text('Game 2')),
        findsOneWidget,
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.drag(
        find.byKey(const Key('games-coverflow-pages-quiz')),
        const Offset(-125, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: selected, matching: find.text('Game 3')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('game-coverflow-play-game-3')));
      expect(identical(opened, games[3]), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selection survives progress rebuild and resets or clamps with child and pool',
    (tester) async {
      final games = List.generate(5, _game);
      await tester.pumpWidget(_harness(games));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('game-card-game-3')));
      await tester.pumpAndSettle();
      final selected = find.byKey(const Key('game-coverflow-selected-quiz'));
      expect(
        find.descendant(of: selected, matching: find.text('Game 3')),
        findsOneWidget,
      );
      await tester.pumpWidget(
        _harness(List.generate(5, (i) => _game(i, completed: i == 3 ? 1 : 0))),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: selected, matching: find.text('Game 3')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: selected,
          matching: find.text('1/3 levels completed'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(_harness(games, scope: 'another-child'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: selected, matching: find.text('Game 2')),
        findsOneWidget,
      );
      await tester.pumpWidget(_harness([games.first], scope: 'another-child'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: selected, matching: find.text('Game 0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fewer covers never repeat and loading disables selected action',
    (tester) async {
      final games = List.generate(2, _game);
      var opens = 0;
      await tester.pumpWidget(
        _harness(games, enabled: false, onOpen: (_) => opens++),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('game-card-game-0')), findsOneWidget);
      expect(find.byKey(const Key('game-card-game-1')), findsOneWidget);
      expect(find.byKey(const Key('game-card-game-2')), findsNothing);
      await tester.tap(find.byKey(const Key('game-card-game-1')));
      await tester.tap(find.byKey(const Key('game-coverflow-play-game-1')));
      expect(opens, 0);
      await tester.pumpWidget(_harness(const []));
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large-text dark-shell selector supports accessible manual steps and real tap',
    (tester) async {
      tester.view.physicalSize = const Size(320, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final games = List.generate(5, _game);
      MiniGame? opened;
      await tester.pumpWidget(
        _harness(games, largeText: true, onOpen: (game) => opened = game),
      );
      await tester.pumpAndSettle();
      final selector = tester.getSemantics(
        find.byKey(const Key('games-coverflow-quiz')),
      );
      expect(
        selector.getSemanticsData().hasAction(ui.SemanticsAction.increase),
        isTrue,
      );
      selector.owner!.performAction(selector.id, ui.SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('game-coverflow-play-game-3')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('game-coverflow-play-game-3')),
      );
      await tester.tap(find.byKey(const Key('game-coverflow-play-game-3')));
      expect(identical(opened, games[3]), isTrue);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}

MiniGame _game(int index, {int completed = 0}) => MiniGame.fromJson({
  'id': 'id-$index',
  'slug': 'game-$index',
  'title': 'Game $index',
  'game_type': 'quiz',
  'total_levels': 3,
  'estimated_duration_seconds': 120,
  'progress': {
    'completed_levels': completed,
    'total_levels': 3,
    'percent': completed / 3,
  },
});

Widget _harness(
  List<MiniGame> games, {
  String scope = 'child',
  bool enabled = true,
  bool largeText = false,
  ValueChanged<MiniGame>? onOpen,
}) => MaterialApp(
  theme: largeText ? ThemeData.dark() : ThemeData.light(),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(393, 852),
      textScaler: TextScaler.linear(largeText ? 2.2 : 1),
      disableAnimations: largeText,
      accessibleNavigation: largeText,
    ),
    child: Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: GamesCategoryCoverflow(
            category: GameCategory.quiz,
            games: games,
            onOpen: onOpen ?? (_) {},
            scopeId: scope,
            enabled: enabled,
          ),
        ),
      ),
    ),
  ),
);
