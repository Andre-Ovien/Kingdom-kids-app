import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/game_play_screen.dart';
import 'package:mobile/features/games/presentation/puzzle_quest_completion.dart';

const _artworkAsset =
    'assets/images/games/puzzle_quest/noahs-ark-rainbow-v1.webp';

void main() {
  testWidgets(
    'Puzzle Quest previews, solves, submits, and celebrates the exact result',
    (tester) async {
      _usePuzzleSurface(tester);
      final repository = _FakePuzzleRepository(game: _puzzleGame);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(disableAnimations: true),
              child: child!,
            );
          },
          home: GamePlayScreen(
            game: _puzzleGame,
            profile: _ada,
            repository: repository,
          ),
        ),
      );
      await _waitForArtworkCheck(tester);

      expect(find.byKey(const Key('puzzle-reference-stage')), findsOneWidget);
      expect(find.text('Rainbow Rescue'), findsOneWidget);
      expect(
        find.text('Study the picture, then rebuild it with four big pieces.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('start-level-button')), findsNothing);
      expect(find.byKey(const Key('puzzle-board-stage')), findsNothing);

      await tester.tap(find.byKey(const Key('puzzle-ready-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('puzzle-board-stage')), findsOneWidget);
      expect(find.text('Rainbow Rescue'), findsNothing);
      expect(
        find.text('Study the picture, then rebuild it with four big pieces.'),
        findsNothing,
      );
      expect(find.text('0 / 4 placed'), findsOneWidget);

      await _tapPieceIntoSlot(
        tester,
        pieceId: 'rainbow-sky',
        slotId: 'slot-00',
      );
      await _tapPieceIntoSlot(
        tester,
        pieceId: 'flying-dove',
        slotId: 'slot-01',
      );
      await _tapPieceIntoSlot(tester, pieceId: 'wooden-ark', slotId: 'slot-10');
      await _tapPieceIntoSlot(
        tester,
        pieceId: 'sparkling-water',
        slotId: 'slot-11',
      );

      expect(find.byKey(const Key('puzzle-finished-art')), findsOneWidget);
      expect(
        find.text('Picture complete! Saving your puzzle.'),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();

      expect(repository.submissions, hasLength(1));
      final submission = repository.submissions.single;
      expect(submission.slug, 'puzzle-quest');
      expect(submission.profileId, 'kid-1');
      expect(submission.levelNumber, 1);
      expect(
        submission.operationId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(submission.result['placements'], [
        {'piece_id': 'rainbow-sky', 'slot_id': 'slot-00'},
        {'piece_id': 'flying-dove', 'slot_id': 'slot-01'},
        {'piece_id': 'wooden-ark', 'slot_id': 'slot-10'},
        {'piece_id': 'sparkling-water', 'slot_id': 'slot-11'},
      ]);
      expect(submission.result['moves'], 4);
      expect(submission.result['elapsed_seconds'], isA<int>());
      expect(
        submission.result['elapsed_seconds'] as int,
        greaterThanOrEqualTo(0),
      );

      expect(find.byKey(const Key('puzzle-completion')), findsOneWidget);
      expect(find.byKey(const Key('game-exit')), findsNothing);
      expect(find.byKey(const Key('game-level-progress')), findsNothing);
      expect(find.byKey(const Key('puzzle-completion-artwork')), findsNothing);
      expect(
        find.byKey(const Key('puzzle-completion-character')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('puzzle-completion-stats')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('puzzle-completion-stars')),
          matching: find.text('3/3'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('puzzle-completion-moves')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('puzzle-completion-time')),
          matching: find.text('${submission.result['elapsed_seconds']}s'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('puzzle-completion')),
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('puzzle-next-button')), findsOneWidget);
      expect(find.text('Next puzzle'), findsOneWidget);

      await tester.tap(find.byKey(const Key('puzzle-next-button')));
      await _waitForArtworkCheck(tester);

      expect(find.byKey(const Key('puzzle-reference-stage')), findsOneWidget);
      expect(find.text('Dove in the Sky'), findsOneWidget);
      expect(
        find.text('Study the second picture, then rebuild it.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('puzzle-completion')), findsNothing);
      expect(repository.submissions, hasLength(1));
    },
  );

  testWidgets(
    'compact final celebration stays focused and offers one finish action',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      var finished = false;

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: const TextScaler.linear(1.5),
            ),
            child: child!,
          ),
          home: PuzzleQuestCompletion(
            game: _puzzleGame,
            profile: _ada,
            submission: _completedSubmission,
            result: const {'moves': 4, 'elapsed_seconds': 38},
            onNext: null,
            onFinish: () => finished = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('puzzle-completion')), findsOneWidget);
      expect(find.byKey(const Key('puzzle-completion-artwork')), findsNothing);
      expect(
        find.byKey(const Key('puzzle-completion-character')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('puzzle-completion-stats')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('puzzle-completion')),
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('puzzle-finish-button')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(const Key('puzzle-finish-button')));
      await tester.tap(find.byKey(const Key('puzzle-finish-button')));
      expect(finished, isTrue);
    },
  );
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
  final piece = find.byKey(Key('puzzle-piece-$pieceId'));
  final slot = find.byKey(Key('puzzle-slot-$slotId'));
  await tester.ensureVisible(piece);
  await tester.tap(piece);
  await tester.pump();
  await tester.ensureVisible(slot);
  await tester.tap(slot);
  await tester.pump();
}

void _usePuzzleSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1600);
  addTearDown(tester.view.reset);
}

const _ada = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Ada Grace',
  avatarKey: 'dove',
);

const _completedSubmission = GameSubmission(
  attemptId: 'puzzle-attempt-compact',
  operationId: 'puzzle-operation-compact',
  gameSlug: 'puzzle-quest',
  profileId: 'kid-1',
  levelNumber: 2,
  completed: true,
  correct: true,
  score: 100,
  maxScore: 100,
  starsAwarded: 3,
  feedback: 'Puzzle complete.',
  progress: GameProgress(
    profileId: 'kid-1',
    highestCompletedLevel: 2,
    currentLevel: 2,
    completedLevels: 2,
    totalLevels: 2,
    bestScore: 100,
    starsEarned: 6,
    maxStars: 6,
    percent: 1,
  ),
  idempotentReplay: false,
);

final _puzzleLevel = GameLevel(
  id: 'rainbow-rescue-level',
  number: 1,
  title: 'Rainbow Rescue',
  instructions: 'Study the picture, then rebuild it with four big pieces.',
  maxScore: 100,
  config: {
    'artwork': {
      'asset_key': _artworkAsset,
      'title': 'Noah’s Rainbow Ark',
      'alt_text':
          'A joyful wooden ark sailing beneath a bright rainbow with a dove.',
      'aspect_ratio': 1,
    },
    'grid': {'rows': 2, 'columns': 2},
    'pieces': [
      {
        'id': 'flying-dove',
        'label': 'Rainbow and dove puzzle piece',
        'source_row': 0,
        'source_column': 1,
      },
      {
        'id': 'sparkling-water',
        'label': 'Sparkling water puzzle piece',
        'source_row': 1,
        'source_column': 1,
      },
      {
        'id': 'rainbow-sky',
        'label': 'Sunny rainbow puzzle piece',
        'source_row': 0,
        'source_column': 0,
      },
      {
        'id': 'wooden-ark',
        'label': 'Noah’s ark puzzle piece',
        'source_row': 1,
        'source_column': 0,
      },
    ],
    'slots': [
      {'id': 'slot-00', 'row': 0, 'column': 0},
      {'id': 'slot-01', 'row': 0, 'column': 1},
      {'id': 'slot-10', 'row': 1, 'column': 0},
      {'id': 'slot-11', 'row': 1, 'column': 1},
    ],
    'preview_seconds': 6,
    'target_moves': 4,
    'target_seconds': 45,
  },
);

final _secondPuzzleLevel = GameLevel(
  id: 'dove-in-the-sky-level',
  number: 2,
  title: 'Dove in the Sky',
  instructions: 'Study the second picture, then rebuild it.',
  maxScore: 100,
  config: {
    'artwork': {
      'asset_key': _artworkAsset,
      'title': 'The Dove Returns',
      'alt_text': 'A dove flying above Noah’s ark and a bright rainbow.',
      'aspect_ratio': 1,
    },
    'grid': {'rows': 2, 'columns': 2},
    'pieces': [
      {
        'id': 'second-piece-00',
        'label': 'Top-left picture piece',
        'source_row': 0,
        'source_column': 0,
      },
      {
        'id': 'second-piece-01',
        'label': 'Top-right picture piece',
        'source_row': 0,
        'source_column': 1,
      },
      {
        'id': 'second-piece-10',
        'label': 'Bottom-left picture piece',
        'source_row': 1,
        'source_column': 0,
      },
      {
        'id': 'second-piece-11',
        'label': 'Bottom-right picture piece',
        'source_row': 1,
        'source_column': 1,
      },
    ],
    'slots': [
      {'id': 'second-slot-00', 'row': 0, 'column': 0},
      {'id': 'second-slot-01', 'row': 0, 'column': 1},
      {'id': 'second-slot-10', 'row': 1, 'column': 0},
      {'id': 'second-slot-11', 'row': 1, 'column': 1},
    ],
    'preview_seconds': 6,
    'target_moves': 4,
    'target_seconds': 45,
  },
);

final _puzzleGame = MiniGame(
  id: 'puzzle-quest',
  slug: 'puzzle-quest',
  title: 'Puzzle Quest',
  subtitle: 'Study it. Shuffle it. Build it!',
  type: MiniGameType.jigsaw,
  gameType: GameType.puzzle,
  difficulty: 'Easy',
  duration: '4 min',
  estimatedDurationSeconds: 240,
  imageAsset: 'assets/images/games/puzzle_quest/puzzle-quest-cover-v1.webp',
  coverAssetKey: 'assets/images/games/puzzle_quest/puzzle-quest-cover-v1.webp',
  accentColor: '#7653E8',
  iconKey: 'extension',
  description: 'Rebuild a bright Bible picture one piece at a time.',
  rewardStars: 6,
  totalLevels: 2,
  isFeatured: true,
  levels: [_puzzleLevel, _secondPuzzleLevel],
  playerProgress: const GameProgress(
    profileId: 'kid-1',
    currentLevel: 1,
    totalLevels: 2,
    maxStars: 6,
  ),
);

typedef _Submission = ({
  String slug,
  String profileId,
  int levelNumber,
  String operationId,
  Map<String, dynamic> result,
});

final class _FakePuzzleRepository implements GameRepository {
  _FakePuzzleRepository({required this.game});

  final MiniGame game;
  final List<_Submission> submissions = [];

  @override
  Future<List<MiniGame>> fetchGames({required String profileId}) async {
    return [game];
  }

  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) async {
    return game;
  }

  @override
  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
  }) async {
    submissions.add((
      slug: slug,
      profileId: profileId,
      levelNumber: levelNumber,
      operationId: operationId,
      result: result,
    ));
    return GameSubmission(
      attemptId: 'puzzle-attempt-1',
      operationId: operationId,
      gameSlug: slug,
      profileId: profileId,
      levelNumber: levelNumber,
      completed: true,
      correct: true,
      score: 100,
      maxScore: 100,
      starsAwarded: 3,
      feedback: 'Picture perfect! Every piece found its place.',
      progress: const GameProgress(
        profileId: 'kid-1',
        highestCompletedLevel: 1,
        currentLevel: 2,
        completedLevels: 1,
        totalLevels: 2,
        bestScore: 100,
        starsEarned: 3,
        maxStars: 6,
        percent: 0.5,
      ),
      idempotentReplay: false,
    );
  }
}
