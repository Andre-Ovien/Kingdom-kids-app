import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/puzzle_quest_engine.dart';

const _artworkAsset =
    'assets/images/games/puzzle_quest/noahs-ark-rainbow-v1.webp';

void main() {
  testWidgets(
    'shows the reference first and completes a tapped 2x2 puzzle once',
    (tester) async {
      _usePuzzleSurface(tester);
      final completions = <Map<String, dynamic>>[];

      await _pumpPuzzle(
        tester,
        level: _validPuzzleLevel,
        onComplete: completions.add,
      );

      expect(find.byKey(const Key('puzzle-reference-stage')), findsOneWidget);
      expect(find.byKey(const Key('puzzle-level-title')), findsOneWidget);
      expect(
        find.byKey(const Key('puzzle-level-instructions')),
        findsOneWidget,
      );
      expect(
        find.text('Look closely—remember where everything goes.'),
        findsOneWidget,
      );
      expect(find.text('Noah’s Rainbow'), findsOneWidget);
      expect(find.text('Rebuild the picture.'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Noah’s ark beneath a bright rainbow.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('puzzle-board-stage')), findsNothing);

      await tester.tap(find.byKey(const Key('puzzle-ready-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));

      expect(find.byKey(const Key('puzzle-reference-stage')), findsNothing);
      expect(find.byKey(const Key('puzzle-board-stage')), findsOneWidget);
      expect(find.text('Noah’s Rainbow'), findsNothing);
      expect(find.text('Rebuild the picture.'), findsNothing);
      expect(find.byKey(const Key('puzzle-board')), findsOneWidget);
      expect(find.text('0 / 4 placed'), findsOneWidget);
      expect(find.text('0 moves'), findsOneWidget);

      // Let the measured puzzle time cross one full second without relying on
      // real wall-clock time.
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(find.byKey(const Key('puzzle-piece-piece-00')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('puzzle-slot-slot-01')));
      await tester.pump();

      expect(find.text('Almost! That piece has another home.'), findsOneWidget);
      expect(find.text('0 / 4 placed'), findsOneWidget);
      expect(find.text('1 move'), findsOneWidget);
      expect(find.byKey(const Key('puzzle-piece-piece-00')), findsOneWidget);
      expect(
        find.bySemanticsLabel('Empty puzzle space 2 of 4'),
        findsOneWidget,
      );
      expect(completions, isEmpty);

      // The wrong attempt keeps this piece selected, so its correct slot can
      // be tapped directly.
      await tester.tap(find.byKey(const Key('puzzle-slot-slot-00')));
      await tester.pump();
      await _tapPieceIntoSlot(tester, pieceId: 'piece-01', slotId: 'slot-01');
      await _tapPieceIntoSlot(tester, pieceId: 'piece-10', slotId: 'slot-10');
      await _tapPieceIntoSlot(tester, pieceId: 'piece-11', slotId: 'slot-11');

      expect(find.byKey(const Key('puzzle-finished-art')), findsOneWidget);
      expect(
        find.text('Picture complete! Saving your puzzle.'),
        findsOneWidget,
      );
      expect(find.text('5 moves'), findsOneWidget);
      expect(completions, isEmpty);

      await tester.pump(const Duration(milliseconds: 650));

      expect(completions, hasLength(1));
      expect(completions.single.keys, {
        'placements',
        'moves',
        'elapsed_seconds',
      });
      expect(completions.single['placements'], [
        {'piece_id': 'piece-00', 'slot_id': 'slot-00'},
        {'piece_id': 'piece-01', 'slot_id': 'slot-01'},
        {'piece_id': 'piece-10', 'slot_id': 'slot-10'},
        {'piece_id': 'piece-11', 'slot_id': 'slot-11'},
      ]);
      expect(completions.single['moves'], 5);
      expect(completions.single['elapsed_seconds'], isA<int>());
      expect(
        completions.single['elapsed_seconds'] as int,
        greaterThanOrEqualTo(0),
      );

      await tester.pump(const Duration(seconds: 2));
      expect(completions, hasLength(1));
    },
  );

  testWidgets('shows a safe fallback for malformed puzzle config', (
    tester,
  ) async {
    _usePuzzleSurface(tester);

    await _pumpPuzzle(
      tester,
      level: GameLevel(
        id: 'broken-puzzle-level',
        number: 1,
        title: 'Broken puzzle',
        instructions: 'Build the picture.',
        config: {
          'artwork': {
            'asset_key': _artworkAsset,
            'title': 'Noah’s Rainbow',
            'alt_text': 'Noah’s ark beneath a bright rainbow.',
            'aspect_ratio': 1,
          },
          'grid': {'rows': 1, 'columns': 1},
          'pieces': const <Object>[],
          'slots': const <Object>[],
        },
        maxScore: 100,
      ),
      onComplete: (_) {},
    );

    expect(find.text('This picture is being prepared'), findsOneWidget);
    expect(
      find.text(
        'Our artists are adding the final sparkle. Please come back soon!',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('puzzle-unavailable-back')), findsOneWidget);
    expect(find.byKey(const Key('puzzle-reference-stage')), findsNothing);
    expect(find.byKey(const Key('puzzle-board-stage')), findsNothing);
  });

  testWidgets(
    'blocks play and offers an accessible return when artwork cannot load',
    (tester) async {
      _usePuzzleSurface(tester);
      final completions = <Map<String, dynamic>>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open-missing-artwork-puzzle'),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: PuzzleQuestEngine(
                              level: _missingArtworkLevel,
                              onComplete: completions.add,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('Open puzzle'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-missing-artwork-puzzle')));
      await _waitForArtworkCheck(tester);

      expect(
        find.byKey(const Key('puzzle-artwork-unavailable')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'This picture is being prepared. Please come back soon.',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Go back'), findsOneWidget);
      expect(find.byKey(const Key('puzzle-ready-button')), findsNothing);
      expect(find.byKey(const Key('puzzle-reference-stage')), findsNothing);
      expect(find.byKey(const Key('puzzle-board-stage')), findsNothing);
      expect(completions, isEmpty);

      await tester.tap(find.byKey(const Key('puzzle-unavailable-back')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('open-missing-artwork-puzzle')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('puzzle-artwork-unavailable')), findsNothing);
      expect(completions, isEmpty);
    },
  );

  testWidgets(
    'keeps one horizontal dock above the board and supports long-press drag',
    (tester) async {
      _usePuzzleSurface(tester);
      final completions = <Map<String, dynamic>>[];
      await _pumpPuzzle(
        tester,
        level: _validPuzzleLevel,
        onComplete: completions.add,
      );

      await tester.tap(find.byKey(const Key('puzzle-ready-button')));
      await tester.pumpAndSettle();

      final dock = find.byKey(const Key('puzzle-piece-dock'));
      final board = find.byKey(const Key('puzzle-board'));
      final pieceFinders = [
        for (final id in const ['piece-00', 'piece-01', 'piece-10', 'piece-11'])
          find.byKey(Key('puzzle-piece-$id')),
      ];

      expect(dock, findsOneWidget);
      expect(board, findsOneWidget);
      expect(tester.getTopLeft(dock).dy, lessThan(tester.getTopLeft(board).dy));
      expect(
        find.ancestor(
          of: pieceFinders.first,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.horizontal,
          ),
        ),
        findsOneWidget,
      );
      final dockRowY = tester.getCenter(pieceFinders.first).dy;
      for (final piece in pieceFinders.skip(1)) {
        expect(tester.getCenter(piece).dy, closeTo(dockRowY, 0.01));
      }

      final gesture = await tester.startGesture(
        tester.getCenter(pieceFinders.first),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('puzzle-slot-slot-00'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Piece placed! 1 of 4 complete.'), findsOneWidget);
      expect(find.text('1 / 4 placed'), findsOneWidget);
      expect(find.text('1 move'), findsOneWidget);
      expect(find.byKey(const Key('puzzle-piece-piece-00')), findsNothing);
      expect(completions, isEmpty);
    },
  );

  testWidgets('keeps every 3x3 piece large on a compact phone', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: PuzzleQuestEngine(
              level: _threeByThreeLevel,
              onComplete: (_) {},
            ),
          ),
        ),
      ),
    );
    await _waitForArtworkCheck(tester);
    final readyButton = find.byKey(const Key('puzzle-ready-button'));
    await tester.ensureVisible(readyButton);
    await tester.tap(readyButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('puzzle-board')), findsOneWidget);
    expect(find.byKey(const Key('puzzle-piece-dock')), findsOneWidget);
    expect(find.byType(LongPressDraggable<String>), findsNWidgets(9));
    final firstPiece = tester.getSize(
      find.byKey(const Key('puzzle-piece-piece-0-0')),
    );
    expect(firstPiece.shortestSide, greaterThanOrEqualTo(72));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPuzzle(
  WidgetTester tester, {
  required GameLevel level,
  required ValueChanged<Map<String, dynamic>> onComplete,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: PuzzleQuestEngine(level: level, onComplete: onComplete),
        ),
      ),
    ),
  );
  await _waitForArtworkCheck(tester);
}

Future<void> _waitForArtworkCheck(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (find.byKey(const Key('puzzle-artwork-loading')).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('Puzzle artwork did not finish its availability check.');
}

Future<void> _tapPieceIntoSlot(
  WidgetTester tester, {
  required String pieceId,
  required String slotId,
}) async {
  await tester.tap(find.byKey(Key('puzzle-piece-$pieceId')));
  await tester.pump();
  await tester.tap(find.byKey(Key('puzzle-slot-$slotId')));
  await tester.pump();
}

void _usePuzzleSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1600);
  addTearDown(tester.view.reset);
}

final _validPuzzleLevel = GameLevel(
  id: 'noahs-rainbow-level',
  number: 1,
  title: 'Noah’s Rainbow',
  instructions: 'Rebuild the picture.',
  config: {
    'artwork': {
      'asset_key': _artworkAsset,
      'title': 'Noah’s Rainbow',
      'alt_text': 'Noah’s ark beneath a bright rainbow.',
      'aspect_ratio': 1,
    },
    'grid': {'rows': 2, 'columns': 2},
    'pieces': [
      {
        'id': 'piece-00',
        'label': 'Top-left rainbow piece',
        'source_row': 0,
        'source_column': 0,
      },
      {
        'id': 'piece-01',
        'label': 'Top-right rainbow piece',
        'source_row': 0,
        'source_column': 1,
      },
      {
        'id': 'piece-10',
        'label': 'Bottom-left ark piece',
        'source_row': 1,
        'source_column': 0,
      },
      {
        'id': 'piece-11',
        'label': 'Bottom-right ark piece',
        'source_row': 1,
        'source_column': 1,
      },
    ],
    'slots': [
      {'id': 'slot-00', 'row': 0, 'column': 0},
      {'id': 'slot-01', 'row': 0, 'column': 1},
      {'id': 'slot-10', 'row': 1, 'column': 0},
      {'id': 'slot-11', 'row': 1, 'column': 1},
    ],
    'preview_seconds': 4,
    'target_moves': 4,
    'target_seconds': 30,
  },
  maxScore: 100,
);

final _missingArtworkLevel = GameLevel(
  id: 'missing-artwork-level',
  number: 1,
  title: 'Picture on the way',
  instructions: 'Rebuild the picture.',
  config: {
    ..._validPuzzleLevel.config,
    'artwork': {
      ...(_validPuzzleLevel.config['artwork'] as Map<String, dynamic>),
      'asset_key': 'assets/images/games/puzzle_quest/not-in-the-bundle.webp',
    },
  },
  maxScore: 100,
);

final _threeByThreeLevel = GameLevel(
  id: 'promise-parade-level',
  number: 3,
  title: 'Promise Parade',
  instructions: 'Rebuild the picture with nine pieces.',
  config: {
    'artwork': {
      'asset_key':
          'assets/images/games/puzzle_quest/puzzle-quest-cover-v1.webp',
      'title': 'The Rainbow Promise',
      'alt_text': 'Noah and friendly animals beneath a bright rainbow.',
      'aspect_ratio': 1,
    },
    'grid': {'rows': 3, 'columns': 3},
    'pieces': [
      for (var row = 0; row < 3; row++)
        for (var column = 0; column < 3; column++)
          {
            'id': 'piece-$row-$column',
            'label': 'Picture piece ${row * 3 + column + 1}',
            'source_row': row,
            'source_column': column,
          },
    ],
    'slots': [
      for (var row = 0; row < 3; row++)
        for (var column = 0; column < 3; column++)
          {'id': 'slot-$row-$column', 'row': row, 'column': column},
    ],
    'preview_seconds': 7,
    'target_moves': 9,
    'target_seconds': 120,
  },
  maxScore: 100,
);
