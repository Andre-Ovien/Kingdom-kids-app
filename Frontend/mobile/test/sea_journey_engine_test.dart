import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/sea_journey_engine.dart';

GameLevel _level() => GameLevel(
  id: 'sea-one',
  number: 1,
  title: 'Across the sea',
  instructions: 'Draw a route to the island.',
  maxScore: 100,
  config: {
    'grid': {
      'rows': 3,
      'columns': 3,
      'start': [0, 0],
      'end': [2, 2],
      'walls': [
        [1, 1],
      ],
    },
  },
);

void main() {
  // Published level fixtures include the repaired storm maze. Replay a genuine
  // open route through touch input, preserving every crossed cell in the result.
  const authoredGrids = [
    {
      'rows': 5,
      'columns': 5,
      'start': [0, 0],
      'end': [4, 4],
      'walls': [
        [0, 2],
        [1, 2],
        [3, 1],
        [3, 2],
        [3, 3],
      ],
    },
    {
      'rows': 6,
      'columns': 6,
      'start': [5, 0],
      'end': [0, 5],
      'walls': [
        [4, 1],
        [4, 2],
        [2, 0],
        [2, 1],
        [2, 2],
        [2, 4],
        [2, 5],
        [0, 3],
      ],
    },
    {
      'rows': 7,
      'columns': 7,
      'start': [0, 0],
      'end': [6, 6],
      'walls': [
        [0, 3],
        [1, 1],
        [1, 3],
        [1, 5],
        [2, 1],
        [2, 5],
        [3, 1],
        [3, 2],
        [3, 3],
        [3, 5],
        [4, 3],
        [5, 0],
        [5, 1],
        [5, 3],
        [5, 5],
        [6, 5],
      ],
    },
    {
      'rows': 5,
      'columns': 5,
      'start': [2, 0],
      'end': [2, 4],
      'walls': [
        [0, 1],
        [0, 2],
        [0, 3],
        [4, 1],
        [4, 2],
        [4, 3],
        [1, 2],
        [3, 2],
      ],
    },
    {
      'rows': 6,
      'columns': 6,
      'start': [0, 0],
      'end': [5, 5],
      'walls': [
        [0, 2],
        [1, 2],
        [1, 4],
        [2, 0],
        [2, 4],
        [3, 2],
        [3, 3],
        [3, 4],
        [4, 2],
        [5, 2],
      ],
    },
    {
      'rows': 7,
      'columns': 7,
      'start': [6, 0],
      'end': [0, 6],
      'walls': [
        [5, 1],
        [5, 2],
        [5, 3],
        [3, 0],
        [3, 1],
        [3, 3],
        [3, 4],
        [3, 5],
        [1, 1],
        [1, 2],
        [1, 3],
        [1, 5],
        [2, 5],
        [4, 3],
      ],
    },
  ];
  for (var index = 0; index < authoredGrids.length; index++) {
    testWidgets(
      'published ${index < 3 ? 'Jonah' : 'Red Sea'} level ${index % 3 + 1} can be traced to its destination',
      (tester) async {
        final level = GameLevel(
          id: 'published-$index',
          number: index % 3 + 1,
          title: 'Sea journey',
          instructions: '',
          maxScore: 100,
          config: {'grid': authoredGrids[index]},
        );
        final path = _openPath(SeaJourneyRoute.fromLevel(level));
        final results = <Map<String, dynamic>>[];
        await _pump(tester, index >= 3, results.add, level: level);
        if (index == 2) {
          expect(
            find.text('Guide your boat to the friendly big fish.'),
            findsOneWidget,
          );
          final goal = tester.widget<Semantics>(
            find.byKey(const Key('sea-cell-6-6')),
          );
          expect(goal.properties.label, contains('Friendly big fish'));
        }
        final gesture = await tester.startGesture(
          _center(tester, path.first.row, path.first.column),
        );
        for (final cell in path.skip(1)) {
          await gesture.moveTo(_center(tester, cell.row, cell.column));
          await tester.pump();
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(results, [
          {
            'path': [for (final cell in path) cell.coordinates],
          },
        ]);
      },
    );
  }

  test('route rejects walls, diagonal jumps and outside cells', () {
    final route = SeaJourneyRoute.fromLevel(_level());
    expect(route.advance(const SeaJourneyCell(1, 1)), false);
    expect(route.advance(const SeaJourneyCell(0, 2)), false);
    expect(route.advance(const SeaJourneyCell(-1, 0)), false);
    expect(route.advance(const SeaJourneyCell(0, 1)), true);
    expect(route.advance(const SeaJourneyCell(1, 1)), false);
    expect(route.current, const SeaJourneyCell(0, 1));
  });

  test('tracing back erases a loop instead of submitting repeated cells', () {
    final route = SeaJourneyRoute.fromLevel(_level());
    route.advance(const SeaJourneyCell(0, 1));
    route.advance(const SeaJourneyCell(0, 2));
    route.advance(const SeaJourneyCell(0, 1));
    expect(route.path.map((e) => e.coordinates), [
      [0, 0],
      [0, 1],
    ]);
    route.reset();
    expect(route.path, [const SeaJourneyCell(0, 0)]);
  });

  for (final seaPath in [false, true]) {
    testWidgets(
      '${seaPath ? 'dry corridor' : 'boat'} traces actual adjacent cells to shore',
      (tester) async {
        final results = <Map<String, dynamic>>[];
        await _pump(tester, seaPath, results.add);
        final gesture = await tester.startGesture(_center(tester, 0, 0));
        // A quick swipe can cross two cells, but neither cell is omitted.
        await gesture.moveTo(_center(tester, 0, 2));
        await tester.pump();
        expect(find.text('2 turns'), findsOneWidget);
        await gesture.moveTo(_center(tester, 2, 2));
        await tester.pump();
        expect(results, isEmpty);
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(results, [
          {
            'path': [
              [0, 0],
              [0, 1],
              [0, 2],
              [1, 2],
              [2, 2],
            ],
          },
        ]);
        expect(find.byIcon(Icons.arrow_upward), findsNothing);
        expect(find.text('👣'), findsNothing);
      },
    );
  }

  testWidgets('a reef blocks a fast swipe and cannot be jumped over', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pump(tester, false, results.add);
    final gesture = await tester.startGesture(_center(tester, 0, 0));
    await gesture.moveTo(_center(tester, 0, 1));
    await tester.pump();
    await gesture.moveTo(_center(tester, 2, 1));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('1 turns'), findsOneWidget);
    expect(find.text('A reef! Sail around it.'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('can lift and continue, but a new drag must begin at the boat', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pump(tester, false, results.add);
    var gesture = await tester.startGesture(_center(tester, 0, 0));
    await gesture.moveTo(_center(tester, 0, 1));
    await gesture.up();
    await tester.pump();
    gesture = await tester.startGesture(_center(tester, 2, 0));
    await gesture.moveTo(_center(tester, 2, 2));
    await gesture.up();
    await tester.pump();
    expect(find.text('1 turns'), findsOneWidget);
    expect(results, isEmpty);
    gesture = await tester.startGesture(_center(tester, 0, 1));
    await gesture.moveTo(_center(tester, 0, 2));
    await gesture.moveTo(_center(tester, 2, 2));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(results, hasLength(1));
  });

  testWidgets('cancelled gesture does not auto-submit a trace at the shore', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pump(tester, false, results.add);
    final gesture = await tester.startGesture(_center(tester, 0, 0));
    await gesture.moveTo(_center(tester, 0, 2));
    await gesture.moveTo(_center(tester, 2, 2));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(results, isEmpty);
  });

  testWidgets('keyboard follows the same walls and submits the chosen route', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pump(tester, true, results.add);
    final focus = tester.widget<Focus>(
      find
          .ancestor(
            of: find.byKey(const Key('sea-route-board')),
            matching: find.byType(Focus),
          )
          .first,
    );
    focus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('1 turns'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(results, [
      {
        'path': [
          [0, 0],
          [0, 1],
          [0, 2],
          [1, 2],
          [2, 2],
        ],
      },
    ]);
  });

  testWidgets(
    'accessible cell actions still require adjacency and avoid walls',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pump(tester, false, results.add);
      final distant = tester.widget<Semantics>(
        find.byKey(const Key('sea-cell-2-2')),
      );
      distant.properties.onTap!();
      await tester.pump();
      expect(find.text('0 turns'), findsOneWidget);
      expect(results, isEmpty);
      final wall = tester.widget<Semantics>(
        find.byKey(const Key('sea-cell-1-1')),
      );
      expect(wall.properties.onTap, isNull);
      for (final coordinate in [
        [0, 1],
        [0, 2],
        [1, 2],
        [2, 2],
      ]) {
        tester
            .widget<Semantics>(
              find.byKey(Key('sea-cell-${coordinate[0]}-${coordinate[1]}')),
            )
            .properties
            .onTap!();
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
    },
  );

  testWidgets('background and disposal cannot submit an unfinished arrival', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pump(tester, false, results.add);
    final gesture = await tester.startGesture(_center(tester, 0, 0));
    await gesture.moveTo(_center(tester, 0, 2));
    await gesture.moveTo(_center(tester, 2, 2));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 3));
    expect(results, isEmpty);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(results, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'restart removes the drawn route on a compact large-text screen',
    (tester) async {
      await _pump(tester, true, (_) {}, scale: 1.8);
      final gesture = await tester.startGesture(_center(tester, 0, 0));
      await gesture.moveTo(_center(tester, 0, 1));
      await gesture.up();
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('sea-restart')));
      await tester.tap(find.byKey(const Key('sea-restart')));
      await tester.pumpAndSettle();
      expect(find.text('0 turns'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  bool seaPath,
  void Function(Map<String, dynamic>) complete, {
  double scale = 1,
  GameLevel? level,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 860);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 860),
            textScaler: TextScaler.linear(scale),
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(25),
              child: SeaJourneyEngine(
                level: level ?? _level(),
                isSeaPath: seaPath,
                onComplete: complete,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Offset _center(WidgetTester tester, int row, int column) =>
    tester.getCenter(find.byKey(Key('sea-cell-$row-$column')));

List<SeaJourneyCell> _openPath(SeaJourneyRoute route) {
  final queue = <List<SeaJourneyCell>>[
    [route.start],
  ];
  final seen = {route.start};
  for (var index = 0; index < queue.length; index++) {
    final path = queue[index];
    final cell = path.last;
    if (cell == route.end) return path;
    for (final step in const [
      SeaJourneyCell(-1, 0),
      SeaJourneyCell(1, 0),
      SeaJourneyCell(0, -1),
      SeaJourneyCell(0, 1),
    ]) {
      final next = SeaJourneyCell(
        cell.row + step.row,
        cell.column + step.column,
      );
      if (route.isOpen(next) && seen.add(next)) queue.add([...path, next]);
    }
  }
  throw TestFailure(
    'Published sea journey has no open route to its destination.',
  );
}
