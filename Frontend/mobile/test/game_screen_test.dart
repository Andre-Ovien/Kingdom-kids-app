import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/kid_character_pose.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/game_cover_image.dart';
import 'package:mobile/features/games/presentation/game_detail_screen.dart';
import 'package:mobile/features/games/presentation/david_sling_engine.dart';
import 'package:mobile/features/games/presentation/game_engines.dart';
import 'package:mobile/features/games/presentation/game_level_completion.dart';
import 'package:mobile/features/games/presentation/game_play_screen.dart';
import 'package:mobile/features/games/presentation/joseph_coat_engine.dart';
import 'package:mobile/features/games/presentation/ruth_harvest_engine.dart';
import 'package:mobile/features/games/presentation/find_my_sheep_engine.dart';
import 'package:mobile/features/games/presentation/creation_bloom_engine.dart';
import 'package:mobile/features/games/presentation/esther_table_engine.dart';
import 'package:mobile/features/games/presentation/games_screen.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_engine.dart';
import 'package:mobile/features/games/presentation/storm_sailing_engine.dart';
import 'package:mobile/features/milestones/data/level_milestone_store.dart';
import 'package:mobile/features/milestones/domain/level_milestone.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';

void main() {
  for (final mode in [
    'coat_studio',
    'harvest_chain',
    'sheep_reunion',
    'creation_bloom',
    'esther_table',
  ]) {
    testWidgets('matching $mode owns portrait and pauses during exit and save', (
      tester,
    ) async {
      _useSailingSurface(tester);
      _recordChromeModes(tester);
      final authored =
          jsonDecode(
                File(
                  '../../Backend/Core/apps/games/content/${mode == 'coat_studio' || mode == 'harvest_chain' ? 'matching_studio' : 'matching_collection'}_v1.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final configs =
          authored[switch (mode) {
                'coat_studio' => 'coat_rounds',
                'harvest_chain' => 'harvest_rounds',
                'sheep_reunion' => 'sheep_rounds',
                'creation_bloom' => 'creation_rounds',
                _ => 'esther_rounds',
              }]
              as List;
      final game = MiniGame(
        id: mode,
        slug: mode,
        title: 'Matching review',
        type: MiniGameType.matching,
        gameType: GameType.matching,
        difficulty: 'Easy',
        duration: '2 min',
        imageAsset: '',
        description: '',
        rewardStars: 3,
        totalLevels: 1,
        levels: [
          GameLevel(
            id: '$mode-1',
            number: 1,
            title: 'First round',
            instructions: '',
            config: Map<String, dynamic>.from(configs.first as Map),
            maxScore: 100,
          ),
        ],
      );
      final receipt = Completer<void>();
      final repository = _FakeGameRepository(
        games: [game],
        submissionBarrier: receipt.future,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GamePlayScreen(
            game: game,
            profile: _ada,
            repository: repository,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final engine = find.byType(switch (mode) {
        'coat_studio' => JosephCoatEngine,
        'harvest_chain' => RuthHarvestEngine,
        'sheep_reunion' => FindMySheepEngine,
        'creation_bloom' => CreationBloomEngine,
        _ => EstherTableEngine,
      });
      expect(tester.getRect(engine), const Rect.fromLTWH(0, 0, 390, 844));
      expect(find.byKey(const Key('start-level-button')), findsNothing);
      bool paused() => switch (tester.widget(engine)) {
        JosephCoatEngine e => e.paused,
        RuthHarvestEngine e => e.paused,
        FindMySheepEngine e => e.paused,
        CreationBloomEngine e => e.paused,
        EstherTableEngine e => e.paused,
        _ => throw StateError('Missing matching engine'),
      };
      final exit = tester
          .widget<GameLevelEngine>(find.byType(GameLevelEngine))
          .onExit!;
      expect(paused(), isFalse);
      exit();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('game-exit-dialog')), findsOneWidget);
      expect(paused(), isTrue);
      await tester.tap(find.text('Keep playing'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(paused(), isFalse);
      final complete = tester
          .widget<GameLevelEngine>(find.byType(GameLevelEngine))
          .onComplete;
      complete(mode == 'harvest_chain' ? {'chains': []} : {'actions': []});
      await tester.pump();
      expect(paused(), isTrue);
      exit();
      await tester.pump();
      expect(find.byKey(const Key('game-exit-dialog')), findsNothing);
      expect(repository.submissions, hasLength(1));
      receipt.complete();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'weekly banner uses the actual featured cover and opens that same game',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.reset);
      final repository = _FakeGameRepository(
        games: [_otherOrderGame, _quizGame],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: repository,
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final banner = find.byKey(const Key('games-featured-banner'));
      final coverFinder = find.byKey(const Key('games-featured-cover'));
      final cover = tester.widget<GameCoverImage>(coverFinder);
      expect(identical(cover.game, _quizGame), isTrue);
      expect(cover.game.coverAssetKey, _quizGame.coverAssetKey);
      expect(cover.fit, BoxFit.cover);
      final bannerRect = tester.getRect(banner);
      final coverRect = tester.getRect(coverFinder);
      expect(coverRect, bannerRect);
      expect(coverRect.width, 393);
      expect(
        find.descendant(
          of: banner,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Image &&
                _imageAssetName(widget.image) ==
                    'assets/images/home/play-premium-v1.png',
          ),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('game-week-play')));
      await tester.pumpAndSettle();
      final detail = tester.widget<GameDetailScreen>(
        find.byType(GameDetailScreen),
      );
      expect(identical(detail.game, _quizGame), isTrue);
      expect(repository.detailSlugs, ['esther-quiz']);
      expect(repository.listProfileIds, ['kid-1']);
      expect(repository.submissions, isEmpty);
    },
  );

  testWidgets(
    'a single-game section remains upright and has a real selected Play action',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.reset);
      final repository = _FakeGameRepository(games: [_quizGame]);
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: repository,
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final image = find.byKey(const Key('game-coverflow-image-esther-quiz'));
      await tester.ensureVisible(image);
      await tester.pumpAndSettle();
      final rect = tester.getRect(image);
      expect(rect.width, inExclusiveRange(100, 120));
      expect(rect.height / rect.width, closeTo(1 / .76, .01));
      expect(rect.center.dx, closeTo(393 / 2, .1));
      final selected = find.byKey(const Key('game-coverflow-selected-quiz'));
      expect(
        find.descendant(of: selected, matching: find.text('Esther Brave Quiz')),
        findsOneWidget,
      );
      final play = find.byKey(const Key('game-coverflow-play-esther-quiz'));
      await tester.ensureVisible(play);
      await tester.pumpAndSettle();
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(repository.detailSlugs, ['esther-quiz']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('game catalogue waits for the current child response', (
    tester,
  ) async {
    final response = Completer<List<MiniGame>>();
    final repository = _FakeGameRepository(
      games: [_quizGame],
      listResponse: response.future,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(
            repository: repository,
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.byKey(const Key('game-card-esther-quiz')), findsNothing);
    expect(repository.listProfileIds, ['kid-1']);
    response.complete([_quizGame]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-card-esther-quiz')), findsOneWidget);
  });

  testWidgets(
    'game room without a selected child never requests child progress',
    (tester) async {
      final repository = _FakeGameRepository(games: [_quizGame]);
      final auth = AuthRepository(sessionStore: MemoryAuthSessionStore());
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(repository: repository, authRepository: auth),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose your explorer'), findsOneWidget);
      expect(find.text('Choose a profile'), findsOneWidget);
      expect(repository.listProfileIds, isEmpty);
      expect(find.byKey(const Key('game-card-esther-quiz')), findsNothing);
    },
  );

  testWidgets(
    'expired game catalogue authentication returns to parent sign-in',
    (tester) async {
      final repository = _FakeGameRepository(
        games: [_quizGame],
        listError: const AppException(
          'Sign in again.',
          code: 'session_expired',
          statusCode: 401,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: repository,
              authRepository: await _activeAuth(),
            ),
          ),
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('Parent sign-in')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Parent sign-in'), findsOneWidget);
      expect(find.byType(GamesScreen), findsNothing);
      expect(repository.listProfileIds, ['kid-1']);
    },
  );

  testWidgets(
    'returning a saved quest reloads the same child catalogue and progress',
    (tester) async {
      _useTallSurface(tester);
      final games = [_quizGame];
      final repository = _FakeGameRepository(games: games);
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: repository,
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('game-card-esther-quiz'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('game-detail-title')), findsOneWidget);
      expect(repository.detailSlugs, ['esther-quiz']);
      games[0] = MiniGame.fromJson({
        'id': 'esther-quiz',
        'slug': 'esther-quiz',
        'title': 'Esther Brave Quiz',
        'game_type': 'quiz',
        'total_levels': 1,
        'progress': {
          'profile_id': 'kid-1',
          'completed_levels': 1,
          'total_levels': 1,
          'stars_earned': 3,
          'max_stars': 3,
          'percent': 1,
        },
      });
      Navigator.of(
        tester.element(find.byKey(const Key('game-detail-title'))),
      ).pop(true);
      await tester.pumpAndSettle();
      expect(repository.listProfileIds, ['kid-1', 'kid-1']);
      final cover = tester.widget<GameCoverImage>(
        find.descendant(of: card, matching: find.byType(GameCoverImage)),
      );
      expect(cover.game.playerProgress.completedLevels, 1);
      expect(cover.game.playerProgress.starsEarned, 3);
      expect(repository.submissions, isEmpty);
    },
  );

  testWidgets('game room loads kid progress, searches, and filters', (
    tester,
  ) async {
    _useTallSurface(tester);
    final auth = await _activeAuth();
    final repository = _FakeGameRepository(games: [_quizGame, _otherOrderGame]);

    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(repository: repository, authRepository: auth),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Games of the Week'), findsOneWidget);
    expect(find.text('GAME ROOM'), findsNothing);
    expect(find.byKey(const Key('games-header-icon')), findsNothing);
    expect(find.byKey(const Key('game-card-esther-quiz')), findsWidgets);
    expect(repository.listProfileIds, ['kid-1']);

    await _enterGameSearch(tester, 'Another');
    await tester.pump();
    expect(find.byKey(const Key('game-card-esther-quiz')), findsNothing);
    expect(
      find.byKey(const Key('game-card-another-order-quest')),
      findsOneWidget,
    );

    await _enterGameSearch(tester, '');
    await _selectGameCategory(tester, 'quiz');
    await tester.pump();
    expect(find.byKey(const Key('game-card-esther-quiz')), findsOneWidget);
    expect(
      find.byKey(const Key('game-card-another-order-quest')),
      findsNothing,
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('game-category-quiz')))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      ui.Tristate.isTrue,
    );
    await _selectGameCategory(tester, 'all');
    await tester.pump();
    expect(find.byKey(const Key('game-card-esther-quiz')), findsWidgets);
    expect(
      find.byKey(const Key('game-card-another-order-quest')),
      findsOneWidget,
    );
  });

  testWidgets(
    'inline game categories and the category menu share one live selection',
    (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: _FakeGameRepository(
                games: [_quizGame, _otherOrderGame],
              ),
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final category = find.byKey(const Key('game-category-game'));
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('game-card-another-order-quest')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('game-card-esther-quiz')), findsNothing);
      expect(find.text('1 GAME'), findsOneWidget);
      await _selectGameCategory(tester, 'quiz');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('game-card-esther-quiz')), findsOneWidget);
      expect(
        find.byKey(const Key('game-card-another-order-quest')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('game-category-all')));
      await tester.pumpAndSettle();
      expect(find.text('2 GAMES'), findsOneWidget);
      expect(
        find.byKey(const Key('game-card-another-order-quest')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('game-card-esther-quiz')), findsOneWidget);
    },
  );

  testWidgets('game lab announces live progress and actionable quests', (
    tester,
  ) async {
    _useTallSurface(tester);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(
            repository: _FakeGameRepository(
              games: [_quizGame, _otherOrderGame],
            ),
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 GAMES'), findsOneWidget);
    expect(
      find.byKey(const Key('game-coverflow-action-esther-quiz')),
      findsOneWidget,
    );
    final node = tester.getSemantics(
      find.byKey(const Key('game-coverflow-action-esther-quiz')),
    );
    expect(node.label, contains('Esther Brave Quiz. Quiz. 1 levels.'));
    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, ui.SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-detail-title')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'retired quests and their empty categories stay hidden from a stale catalogue',
    (tester) async {
      _useTallSurface(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: _FakeGameRepository(
                // Simulate a stale catalogue that still features retired games.
                games: [
                  _retiredPathGame,
                  _retiredMemoryGame,
                  _retiredArkGame,
                  _retiredCreationGame,
                  _retiredBuildersGame,
                  _quizGame,
                  _matchingGame,
                ],
              ),
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _expectGameCategories(
        tester,
        present: ['quiz'],
        absent: ['memory', 'matching', 'path', 'ordering'],
      );
      expect(find.text('Red Sea Crossing'), findsNothing);
      expect(find.text('Daniel Memory Match'), findsNothing);
      expect(find.text('Noah’s Ark Rescue'), findsNothing);
      expect(find.text('Moses Matching'), findsNothing);
      expect(find.text('Creation Order'), findsNothing);
      expect(find.text('Wise and Foolish Builders'), findsNothing);
      expect(find.text('1 GAME'), findsOneWidget);
      expect(
        find.byKey(const Key('game-coverflow-action-esther-quiz')),
        findsOneWidget,
      );

      for (final (query, retiredTitle) in [
        ('Daniel', 'Daniel Memory Match'),
        ('Noah', 'Noah’s Ark Rescue'),
        ('Moses', 'Moses Matching'),
        ('Red Sea', 'Red Sea Crossing'),
        ('Path', 'Red Sea Crossing'),
        ('Creation', 'Creation Order'),
        ('Builders', 'Wise and Foolish Builders'),
        ('Order', 'Creation Order'),
      ]) {
        await _enterGameSearch(tester, query);
        await tester.pump();
        expect(find.text('No quests found'), findsOneWidget);
        expect(find.text(retiredTitle), findsNothing);
      }

      await _enterGameSearch(tester, '');
      await tester.pump();
      expect(find.text('1 GAME'), findsOneWidget);
      expect(find.text('Esther Brave Quiz'), findsWidgets);
      semantics.dispose();
    },
  );

  testWidgets('retiring specific quests preserves other ordering games', (
    tester,
  ) async {
    _useTallSurface(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(
            repository: _FakeGameRepository(
              games: [
                _retiredCreationGame,
                _retiredBuildersGame,
                _otherOrderGame,
                _quizGame,
              ],
            ),
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Creation Order'), findsNothing);
    expect(find.text('Wise and Foolish Builders'), findsNothing);
    await _expectGameCategories(tester, present: ['game', 'quiz']);
    expect(find.text('2 GAMES'), findsOneWidget);
    expect(
      find.byKey(const Key('game-coverflow-action-esther-quiz')),
      findsOneWidget,
    );
    await _selectGameCategory(tester, 'game');
    await tester.pumpAndSettle();
    expect(find.text('1 GAME'), findsOneWidget);
    expect(find.text('Another Order Quest'), findsOneWidget);
    expect(find.text('Creation Order'), findsNothing);
    await _enterGameSearch(tester, 'Creation');
    await tester.pump();
    expect(find.text('No quests found'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'Quiz offers five retained story adventures with the correct covers',
    (tester) async {
      _useTallSurface(tester);
      final repository = _FakeGameRepository(
        games: [
          _retiredMemoryGame,
          _retiredArkGame,
          ..._storyQuizzes,
          _matchingGame,
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: repository,
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _expectGameCategories(tester, absent: ['matching']);
      await _selectGameCategory(tester, 'quiz');
      await tester.pumpAndSettle();
      expect(find.text('5 GAMES'), findsOneWidget);
      expect(find.text('Moses Matching'), findsNothing);
      expect(find.text('Noah’s Ark Rescue'), findsNothing);

      final keptQuizzes = _storyQuizzes
          .where((quiz) => _keptQuizSlugs.contains(quiz.slug))
          .toList();
      for (final quiz in keptQuizzes) {
        await _enterGameSearch(tester, quiz.title);
        await tester.pumpAndSettle();
        final card = find.byKey(Key('game-card-${quiz.slug}'));
        expect(card, findsOneWidget);
        final cover = tester.widget<GameCoverImage>(
          find.descendant(of: card, matching: find.byType(GameCoverImage)),
        );
        expect(cover.game.coverAssetKey, quiz.coverAssetKey);
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const Key('game-detail-title'))).data,
          quiz.title,
        );
        expect(repository.detailSlugs.last, quiz.slug);
        await tester.tap(find.byKey(const Key('game-detail-back')));
        await tester.pumpAndSettle();
      }
      expect(repository.detailSlugs, keptQuizzes.map((quiz) => quiz.slug));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale catalogue keeps five puzzles and five quizzes while action games pause',
    (tester) async {
      _useTallSurface(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: _FakeGameRepository(
                games: [
                  ..._storyQuizzes,
                  ..._storyPicturePuzzles,
                  _mazeGame,
                  _davidBattleGame,
                ],
              ),
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('10 GAMES'), findsOneWidget);
      await _expectGameCategories(
        tester,
        present: ['puzzle', 'quiz'],
        absent: ['game', 'aim', 'maze', 'ordering', 'matching'],
      );
      await _selectGameCategory(tester, 'puzzle');
      await tester.pumpAndSettle();
      expect(find.text('5 GAMES'), findsOneWidget);

      for (final puzzle in _storyPicturePuzzles) {
        await _enterGameSearch(tester, puzzle.title);
        await tester.pumpAndSettle();
        final card = find.byKey(Key('game-card-${puzzle.slug}'));
        if (_keptPuzzleSlugs.contains(puzzle.slug)) {
          expect(card, findsOneWidget);
          final cover = tester.widget<GameCoverImage>(
            find.descendant(of: card, matching: find.byType(GameCoverImage)),
          );
          expect(cover.game.coverAssetKey, puzzle.coverAssetKey);
        } else {
          expect(card, findsNothing);
          expect(find.text('No quests found'), findsOneWidget);
        }
      }
      await _enterGameSearch(tester, '');
      await _selectGameCategory(tester, 'quiz');
      await tester.pumpAndSettle();
      expect(find.text('5 GAMES'), findsOneWidget);
      for (final quiz in _storyQuizzes.where(
        (quiz) => !_keptQuizSlugs.contains(quiz.slug),
      )) {
        await _enterGameSearch(tester, quiz.title);
        await tester.pumpAndSettle();
        expect(find.byKey(Key('game-card-${quiz.slug}')), findsNothing);
        expect(find.text('No quests found'), findsOneWidget);
      }
      semantics.dispose();
    },
  );

  testWidgets(
    'paused Ark garden retains its Games identity without restoring matching quests',
    (tester) async {
      _useTallSurface(tester);
      final garden = MiniGame.fromJson({
        'id': 'garden',
        'slug': 'noahs-ark-garden',
        'title': 'Noah’s Ark Garden',
        'game_type': 'matching',
        'total_levels': 1,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: _FakeGameRepository(
                games: [
                  garden,
                  _retiredArkGame,
                  _matchingGame,
                  _quizGame,
                  _mazeGame,
                ],
              ),
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _expectGameCategories(tester, absent: ['matching']);
      expect(find.text('Noah’s Ark Rescue'), findsNothing);
      expect(find.text('Moses Matching'), findsNothing);
      await _expectGameCategories(tester, absent: ['game']);
      expect(find.text('1 GAME'), findsOneWidget);
      expect(find.text('Noah’s Ark Garden'), findsNothing);
      expect(find.text('Jonah Ocean Maze'), findsNothing);
      expect(find.text('Esther Brave Quiz'), findsWidgets);
      expect(find.text('MATCH'), findsNothing);
      expect(garden.gameType, GameType.matching);
      expect(garden.category, GameCategory.game);
    },
  );

  testWidgets(
    'paused action games cannot leak through stale featured search or category counts',
    (tester) async {
      _useTallSurface(tester);
      final semantics = tester.ensureSemantics();
      final kept = [
        ..._storyQuizzes.where((game) => _keptQuizSlugs.contains(game.slug)),
        ..._storyPicturePuzzles.where(
          (game) => _keptPuzzleSlugs.contains(game.slug),
        ),
        ..._matchingCatalogueGames,
      ];
      final paused = [
        for (final (slug, title, type) in const [
          ('david-sling-shot', 'David Sling', 'aim'),
          ('jonah-ocean-maze', 'Jonah Ocean Maze', 'maze'),
          ('noahs-ark-garden', 'Noah’s Ark Garden', 'matching'),
        ])
          MiniGame.fromJson({
            'id': slug,
            'slug': slug,
            'title': title,
            'game_type': type,
            'is_featured': true,
            'total_levels': 3,
            'progress': {
              'profile_id': 'kid-1',
              'completed_levels': 3,
              'total_levels': 3,
              'stars_earned': 9,
              'max_stars': 9,
            },
          }),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: _stillGames(
            GamesScreen(
              repository: _FakeGameRepository(games: [...paused, ...kept]),
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('15 GAMES'), findsOneWidget);
      await _expectGameCategories(tester, absent: ['game']);
      expect(
        find.byKey(const Key('game-coverflow-action-esther-quiz')),
        findsOneWidget,
      );
      for (final game in paused) {
        expect(find.byKey(Key('game-card-${game.slug}')), findsNothing);
        await _enterGameSearch(tester, game.title);
        await tester.pumpAndSettle();
        expect(find.text('No quests found'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == game.title,
          ),
          findsNothing,
        );
        expect(find.text('0 GAMES'), findsOneWidget);
      }
      for (final category in [
        GameCategory.puzzle,
        GameCategory.quiz,
        GameCategory.matching,
      ]) {
        await _enterGameSearch(tester, '');
        await _selectGameCategory(tester, category.name);
        await tester.pumpAndSettle();
        expect(find.text('5 GAMES'), findsOneWidget);
        for (final game in kept.where((game) => game.category == category)) {
          await _enterGameSearch(tester, game.title);
          await tester.pumpAndSettle();
          final card = find.byKey(Key('game-card-${game.slug}'));
          expect(card, findsOneWidget);
          final cover = tester.widget<GameCoverImage>(
            find.descendant(of: card, matching: find.byType(GameCoverImage)),
          );
          expect(cover.game.coverAssetKey, game.coverAssetKey);
        }
      }
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a refreshed 404 cannot replay previously cached quest levels', (
    tester,
  ) async {
    _useTallSurface(tester);
    final repository = _FakeGameRepository(games: [_davidBattleGame]);
    await tester.pumpWidget(
      MaterialApp(
        home: GameDetailScreen(
          game: _davidBattleGame,
          repository: repository,
          authRepository: await _activeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('play-game-button'));
    final previouslyEnabledPlay = tester
        .widget<FilledButton>(button)
        .onPressed!;
    repository.detailFailuresRemaining = 1;
    await tester.drag(
      find.descendant(
        of: find.byType(GameDetailScreen),
        matching: find.byType(CustomScrollView),
      ),
      const Offset(0, 650),
    );
    await tester.pumpAndSettle();
    expect(repository.detailFetches, 2);
    expect(
      find.text(
        'We couldn’t find that content. It may be unavailable right now.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    // An action queued from the old enabled button also rechecks availability.
    previouslyEnabledPlay();
    await tester.pumpAndSettle();
    expect(find.byType(GamePlayScreen), findsNothing);
    expect(repository.submissions, isEmpty);
  });

  testWidgets(
    'a new story quiz saves all three answers for the selected child',
    (tester) async {
      _useTallSurface(tester);
      final quiz = _storyQuizzes.firstWhere((game) => game.slug == 'noah-quiz');
      final repository = _FakeGameRepository(games: [quiz]);
      await tester.pumpWidget(
        MaterialApp(
          home: GameDetailScreen(
            game: quiz,
            repository: repository,
            authRepository: await _activeAuth(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('play-game-button')),
        250,
      );
      await tester.tap(find.byKey(const Key('play-game-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-level-button')));
      await tester.pumpAndSettle();

      expect(find.text('Meet Noah'), findsOneWidget);
      expect(
        find.text('Choose one kind answer for each question.'),
        findsOneWidget,
      );

      for (var question = 1; question <= 3; question++) {
        expect(find.text('QUESTION $question OF 3'), findsOneWidget);
        await tester.tap(find.byKey(const Key('quiz-option-b')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('quiz-continue')));
        await tester.pumpAndSettle();
      }
      expect(repository.submissions, hasLength(1));
      final submission = repository.submissions.single;
      expect(submission.slug, 'noah-quiz');
      expect(submission.profileId, _ada.id);
      expect(submission.level, 1);
      expect(submission.result, {
        'answers': [
          for (var question = 1; question <= 3; question++)
            {'question_id': 'noah-quiz-q$question', 'option_id': 'b'},
        ],
      });
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long story quiz names fit on small screens with large text', (
    tester,
  ) async {
    _useSmallSurface(tester);
    final quiz = _storyQuizzes.firstWhere((game) => game.slug == 'jonah-quiz');
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2.2),
          ),
          child: _stillGames(
            GamesScreen(
              repository: _FakeGameRepository(games: [quiz]),
              authRepository: await _activeAuth(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('game-card-jonah-quiz')),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(quiz.title), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('game room exposes a backend failure and retries', (
    tester,
  ) async {
    final repository = _FakeGameRepository(
      games: [_quizGame],
      listFailuresRemaining: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(
            repository: repository,
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The game room is taking a nap.'), findsOneWidget);
    await tester.ensureVisible(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Esther Brave Quiz'), findsWidgets);
    expect(repository.listProfileIds, ['kid-1', 'kid-1']);
  });

  testWidgets('an empty game catalogue promises new quests and can refresh', (
    tester,
  ) async {
    final repository = _FakeGameRepository(games: const []);
    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(
            repository: repository,
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New quests are being prepared!'), findsOneWidget);
    expect(
      find.text(
        'The next game adventures are almost ready. Check back soon or refresh now.',
      ),
      findsOneWidget,
    );
    expect(find.text('No quests found'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('games-refresh-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('games-refresh-button')));
    await tester.pumpAndSettle();
    expect(repository.listProfileIds, ['kid-1', 'kid-1']);
  });

  testWidgets('an empty game search can return to every quest', (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(
            repository: _FakeGameRepository(games: [_quizGame]),
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _enterGameSearch(tester, 'No quest has this title');
    await tester.pump();

    expect(find.text('No quests found'), findsOneWidget);
    expect(find.text('New quests are being prepared!'), findsNothing);
    await tester.tap(find.byKey(const Key('games-reset-button')));
    await tester.pump();
    expect(find.text('Esther Brave Quiz'), findsWidgets);
  });

  testWidgets('quiz submits once, retries safely, and shows saved rewards', (
    tester,
  ) async {
    _useTallSurface(tester);
    final repository = _FakeGameRepository(
      games: [_quizGame],
      submitFailuresRemaining: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GameDetailScreen(
          game: _quizGame,
          repository: repository,
          authRepository: await _activeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('game-progress-card')),
      250,
    );
    expect(find.byKey(const Key('game-progress-card')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('play-game-button')),
      250,
    );
    await tester.tap(find.byKey(const Key('play-game-button')));
    await tester.pumpAndSettle();
    expect(find.text('Ready, Ada?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start-level-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quiz-option-b')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quiz-continue')));
    await tester.pumpAndSettle();

    expect(repository.submissions, hasLength(1));
    expect(find.text('Could not save that try.'), findsOneWidget);
    expect(find.text('Redo level'), findsOneWidget);
    await tester.tap(find.text('Retry save'));
    await tester.pumpAndSettle();

    expect(repository.submissions, hasLength(2));
    expect(
      repository.submissions[0].operationId,
      repository.submissions[1].operationId,
    );
    expect(
      repository.submissions.last.operationId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(repository.submissions.last.result, {
      'answers': [
        {'question_id': 'q1', 'option_id': 'b'},
      ],
    });
    final completion = find.byKey(const Key('game-completion'));
    expect(completion, findsOneWidget);
    expect(find.byKey(const Key('game-exit')), findsNothing);
    expect(find.byKey(const Key('game-level-progress')), findsNothing);
    final character = tester.widget<KidProfileCharacterPose>(
      find.descendant(
        of: find.byKey(const Key('game-completion-character')),
        matching: find.byType(KidProfileCharacterPose),
      ),
    );
    expect(character.pose, KidCharacterPose.celebrate);
    expect(find.byKey(const Key('game-completion-stats')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('game-completion-score')),
        matching: find.text('10/10'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('game-completion-stars')),
        matching: find.text('3/3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: completion, matching: find.byType(FilledButton)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('finish-game-button')), findsOneWidget);
    expect(find.byKey(const Key('next-level-button')), findsNothing);
    expect(find.byKey(const Key('replay-quest-button')), findsNothing);
    expect(find.text('+3'), findsNothing);
    expect(repository.maxConcurrentSubmissions, 1);
  });

  testWidgets('cached games stay visible behind a retryable stale banner', (
    tester,
  ) async {
    _useTallSurface(tester);
    final repository = _FakeGameRepository(games: [_quizGame, _mazeGame]);
    await tester.pumpWidget(
      MaterialApp(
        home: _stillGames(
          GamesScreen(
            repository: repository,
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    repository.listFailuresRemaining = 1;
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, 320),
    );
    await tester.pumpAndSettle();

    expect(repository.listProfileIds, ['kid-1', 'kid-1']);
    expect(find.text('SHOWING SAVED QUESTS'), findsOneWidget);
    expect(find.text('Esther Brave Quiz'), findsWidgets);
    await tester.ensureVisible(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('SHOWING SAVED QUESTS'), findsNothing);
    expect(repository.listProfileIds, ['kid-1', 'kid-1', 'kid-1']);
  });

  testWidgets('a rejected result offers a fresh level with a new operation', (
    tester,
  ) async {
    _useTallSurface(tester);
    final repository = _FakeGameRepository(
      games: [_quizGame],
      submitFailuresRemaining: 1,
      submitFailureStatusCode: 409,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GameDetailScreen(
          game: _quizGame,
          repository: repository,
          authRepository: await _activeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('play-game-button')),
      250,
    );
    await tester.tap(find.byKey(const Key('play-game-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-level-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quiz-option-b')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quiz-continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('retry-game-save')), findsNothing);
    expect(find.byKey(const Key('redo-game-level')), findsOneWidget);
    final rejectedOperation = repository.submissions.single.operationId;

    await tester.tap(find.byKey(const Key('redo-game-level')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quiz-option-b')), findsOneWidget);
    await tester.tap(find.byKey(const Key('quiz-option-b')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quiz-continue')));
    await tester.pumpAndSettle();

    expect(repository.submissions, hasLength(2));
    expect(repository.submissions.last.operationId, isNot(rejectedOperation));
    expect(find.byKey(const Key('game-completion')), findsOneWidget);
  });

  testWidgets('system back from a result refreshes quest progress', (
    tester,
  ) async {
    _useTallSurface(tester);
    final repository = _FakeGameRepository(games: [_quizGame]);
    await tester.pumpWidget(
      MaterialApp(
        home: GameDetailScreen(
          game: _quizGame,
          repository: repository,
          authRepository: await _activeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('play-game-button')),
      250,
    );
    await tester.tap(find.byKey(const Key('play-game-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-level-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quiz-option-b')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quiz-continue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-completion')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-detail-title')), findsOneWidget);
    expect(repository.detailFetches, 2);
  });

  testWidgets(
    'an intermediate celebration offers only Next and opens level two',
    (tester) async {
      _useTallSurface(tester);
      final repository = _FakeGameRepository(games: [_twoLevelQuizGame]);

      await tester.pumpWidget(
        MaterialApp(
          home: GamePlayScreen(
            game: _twoLevelQuizGame,
            profile: _ada,
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('start-level-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quiz-option-b')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('quiz-continue')));
      await tester.pumpAndSettle();

      final completion = find.byKey(const Key('game-completion'));
      expect(completion, findsOneWidget);
      expect(find.byKey(const Key('game-exit')), findsNothing);
      expect(find.byKey(const Key('game-level-progress')), findsNothing);
      expect(
        find.descendant(of: completion, matching: find.byType(FilledButton)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('next-level-button')), findsOneWidget);
      expect(find.byKey(const Key('finish-game-button')), findsNothing);

      await tester.tap(find.byKey(const Key('next-level-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('game-completion')), findsNothing);
      expect(find.text('Level 2 of 2'), findsOneWidget);
      expect(find.text('A second brave choice'), findsOneWidget);
      expect(find.byKey(const Key('start-level-button')), findsOneWidget);
      expect(repository.submissions, hasLength(1));
    },
  );

  testWidgets(
    'completed is authoritative even when the answer is not marked correct',
    (tester) async {
      _useTallSurface(tester);
      final repository = _FakeGameRepository(
        games: [_quizGame],
        submissionCorrect: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GamePlayScreen(
            game: _quizGame,
            profile: _ada,
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('start-level-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quiz-option-b')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('quiz-continue')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(find.byKey(const Key('game-exit')), findsNothing);
      expect(find.byKey(const Key('game-level-progress')), findsNothing);
      expect(find.byKey(const Key('finish-game-button')), findsOneWidget);
      expect(find.byKey(const Key('retry-level-button')), findsNothing);
    },
  );

  testWidgets(
    'every non-puzzle game has a compact reduced-motion celebration',
    (tester) async {
      _useSmallSurface(tester);
      const expectedTitles = <GameType, String>{
        GameType.quiz: 'Brilliant thinking,\nAda!',
        GameType.memory: 'Memory magic,\nAda!',
        GameType.ordering: 'Perfect order,\nAda!',
        GameType.matching: 'Perfect match,\nAda!',
        GameType.maze: 'You found the way,\nAda!',
        GameType.path: 'Trailblazer,\nAda!',
        GameType.aim: 'Bullseye,\nAda!',
      };

      for (final entry in expectedTitles.entries) {
        var nextCalls = 0;
        var finishCalls = 0;
        final hasNext = entry.key.index.isEven;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) {
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              );
            },
            home: GameLevelCompletion(
              game: _completionGame(entry.key),
              profile: _ada,
              submission: _completionSubmission(entry.key),
              onNext: hasNext ? () => nextCalls += 1 : null,
              onFinish: () => finishCalls += 1,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final completion = find.byKey(const Key('game-completion'));
        expect(completion, findsOneWidget, reason: entry.key.name);
        expect(
          find.byKey(const Key('game-completion-title')),
          findsOneWidget,
          reason: entry.key.name,
        );
        expect(find.text(entry.value), findsOneWidget, reason: entry.key.name);
        final character = tester.widget<KidProfileCharacterPose>(
          find.descendant(
            of: find.byKey(const Key('game-completion-character')),
            matching: find.byType(KidProfileCharacterPose),
          ),
        );
        expect(
          character.pose,
          KidCharacterPose.celebrate,
          reason: entry.key.name,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('game-completion-score')),
            matching: find.text('7/10'),
          ),
          findsOneWidget,
          reason: entry.key.name,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('game-completion-stars')),
            matching: find.text('2/3'),
          ),
          findsOneWidget,
          reason: entry.key.name,
        );
        expect(
          find.descendant(of: completion, matching: find.byType(FilledButton)),
          findsOneWidget,
          reason: entry.key.name,
        );
        expect(
          find.descendant(of: completion, matching: find.byType(TextButton)),
          findsNothing,
          reason: entry.key.name,
        );
        expect(tester.takeException(), isNull, reason: entry.key.name);

        final action = find.byKey(
          Key(hasNext ? 'next-level-button' : 'finish-game-button'),
        );
        expect(action, findsOneWidget, reason: entry.key.name);
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pump();
        expect(nextCalls, hasNext ? 1 : 0, reason: entry.key.name);
        expect(finishCalls, hasNext ? 0 : 1, reason: entry.key.name);
      }
    },
  );

  testWidgets('a confirmed in-level exit returns to quest details', (
    tester,
  ) async {
    _useTallSurface(tester);
    final repository = _FakeGameRepository(games: [_quizGame]);
    await tester.pumpWidget(
      MaterialApp(
        home: GameDetailScreen(
          game: _quizGame,
          repository: repository,
          authRepository: await _activeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('play-game-button')),
      250,
    );
    await tester.tap(find.byKey(const Key('play-game-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-level-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('game-exit')));
    await tester.pumpAndSettle();
    expect(find.text('Leave this level?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-detail-title')), findsOneWidget);
    expect(find.byKey(const Key('game-exit')), findsNothing);
  });

  testWidgets('the quest detail back button returns to the game room', (
    tester,
  ) async {
    _useTallSurface(tester);
    final auth = await _activeAuth();
    final repository = _FakeGameRepository(games: [_quizGame]);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GameDetailScreen(
                    game: _quizGame,
                    repository: repository,
                    authRepository: auth,
                  ),
                ),
              ),
              child: const Text('Open quest'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open quest'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-detail-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('game-detail-back')));
    await tester.pumpAndSettle();

    expect(find.text('Open quest'), findsOneWidget);
    expect(find.byKey(const Key('game-detail-title')), findsNothing);
  });

  for (final viewport in const [
    Size(320, 568),
    Size(834, 1194),
    Size(1194, 834),
    Size(1032, 1376),
    Size(1376, 1032),
  ]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        'game room adapts at $viewport in ${brightness.name} with large text',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = viewport;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: viewport,
                  textScaler: const TextScaler.linear(2.2),
                ),
                child: _stillGames(
                  GamesScreen(
                    repository: _FakeGameRepository(
                      games: [_quizGame, _mazeGame],
                    ),
                    authRepository: await _activeAuth(),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('Games of the Week'), findsOneWidget);
          await _ensureGameControl(tester, const Key('game-filter-button'));
          expect(find.byKey(const Key('game-filter-button')), findsOneWidget);
          expect(
            find.byKey(const Key('games-courses-content-sheet')),
            findsOneWidget,
          );
          await _showGameSearch(tester);
          expect(
            Theme.of(
              tester.element(find.byKey(const Key('game-search-field'))),
            ).brightness,
            Brightness.light,
          );
          await tester.scrollUntilVisible(
            find.byKey(const Key('game-card-esther-quiz')),
            260,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            find.byKey(const Key('game-card-esther-quiz')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('quest detail adapts at 3x text on a small dark screen', (
    tester,
  ) async {
    _useSmallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(3),
          ),
          child: GameDetailScreen(
            game: _quizGame,
            repository: _FakeGameRepository(games: [_quizGame]),
            authRepository: await _activeAuth(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-detail-title')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('game-progress-card')),
      240,
    );
    expect(find.byKey(const Key('game-progress-card')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('play-game-button')),
      -240,
    );
    expect(find.byKey(const Key('play-game-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('play intro top bar adapts at 3x text on a small screen', (
    tester,
  ) async {
    _useSmallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(3),
          ),
          child: GamePlayScreen(
            game: _quizGame,
            profile: _ada,
            repository: _FakeGameRepository(games: [_quizGame]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-exit')), findsOneWidget);
    expect(find.byKey(const Key('game-level-progress')), findsOneWidget);
    expect(find.text('Ready, Ada?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('full-screen David battle route', () {
    testWidgets(
      'opens directly across the viewport and restores system chrome on exit',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        final chromeCalls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            chromeCalls.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: GamePlayScreen(
              game: _davidBattleGame,
              profile: _ada,
              repository: _FakeGameRepository(games: [_davidBattleGame]),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('start-level-button')), findsNothing);
        expect(find.textContaining('Level 1 of'), findsNothing);
        expect(
          tester.getRect(find.byKey(const Key('sling-board'))),
          const Rect.fromLTWH(0, 0, 390, 844),
        );
        expect(
          chromeCalls
              .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
              .last
              .arguments,
          'SystemUiMode.immersiveSticky',
        );
        final engine = tester.widget<DavidSlingEngine>(
          find.byType(DavidSlingEngine),
        );
        engine.onExit!();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Leave the battlefield?'), findsOneWidget);
        expect(
          tester.widget<DavidSlingEngine>(find.byType(DavidSlingEngine)).paused,
          isTrue,
        );
        await tester.tap(find.text('Keep playing'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<DavidSlingEngine>(find.byType(DavidSlingEngine)).paused,
          isFalse,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(
          chromeCalls
              .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
              .last
              .arguments,
          'SystemUiMode.edgeToEdge',
        );
      },
    );

    testWidgets(
      'leaving keeps the battle paused through the route transition',
      (tester) async {
        _useTallSurface(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => GamePlayScreen(
                        game: _davidBattleGame,
                        profile: _ada,
                        repository: _FakeGameRepository(
                          games: [_davidBattleGame],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open battlefield'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open battlefield'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        tester
            .widget<DavidSlingEngine>(find.byType(DavidSlingEngine))
            .onExit!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Leave'));
        await tester.pump();
        expect(
          tester.widget<DavidSlingEngine>(find.byType(DavidSlingEngine)).paused,
          isTrue,
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester.widget<DavidSlingEngine>(find.byType(DavidSlingEngine)).paused,
          isTrue,
        );
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byType(DavidSlingEngine), findsNothing);
        expect(find.text('Open battlefield'), findsOneWidget);
      },
    );

    testWidgets(
      'retrying a save keeps the battlefield and operation, next opens another battlefield',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        final repository = _FakeGameRepository(
          games: [_davidBattleGame],
          submitFailuresRemaining: 1,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: GamePlayScreen(
              game: _davidBattleGame,
              profile: _ada,
              repository: repository,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        tester
            .widget<DavidSlingEngine>(find.byType(DavidSlingEngine))
            .onComplete({
              'shots': [
                {'x': 160.0, 'y': 180.0},
              ],
            });
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const Key('david-fullscreen-battle')),
          findsOneWidget,
        );
        expect(find.text('Could not save that try.'), findsOneWidget);
        expect(find.byKey(const Key('game-completion')), findsNothing);
        final operation = repository.submissions.single.operationId;
        await tester.tap(find.byKey(const Key('retry-game-save')));
        await tester.pump(const Duration(milliseconds: 800));
        expect(repository.submissions, hasLength(2));
        expect(repository.submissions.last.operationId, operation);
        expect(find.byKey(const Key('game-completion')), findsOneWidget);
        await tester.tap(find.byKey(const Key('next-level-button')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const Key('sling-board')), findsOneWidget);
        expect(find.byKey(const Key('start-level-button')), findsNothing);
        expect(find.textContaining('Level 2 of'), findsNothing);
        expect(
          tester
              .widget<DavidSlingEngine>(find.byType(DavidSlingEngine))
              .level
              .number,
          2,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('full-screen storm sailing route', () {
    testWidgets(
      'opens directly, pauses offscreen, and restores immersive system chrome',
      (tester) async {
        _useSailingSurface(tester);
        final chromeModes = _recordChromeModes(tester);
        final navigator = GlobalKey<NavigatorState>();
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: GamePlayScreen(
              game: _sailingGame,
              profile: _ada,
              repository: _FakeGameRepository(games: [_sailingGame]),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const Key('start-level-button')), findsNothing);
        expect(find.byKey(const Key('game-level-progress')), findsNothing);
        expect(find.byKey(const Key('game-exit')), findsNothing);
        expect(find.textContaining('Level 1 of'), findsNothing);
        expect(find.byKey(const Key('sailing-start')), findsOneWidget);
        expect(
          tester.getRect(find.byType(StormSailingEngine)),
          const Rect.fromLTWH(0, 0, 390, 844),
        );
        expect(chromeModes.last, 'SystemUiMode.immersiveSticky');

        tester
            .widget<StormSailingEngine>(find.byType(StormSailingEngine))
            .onExit();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Leave this voyage?'), findsOneWidget);
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .paused,
          isTrue,
        );
        await tester.tap(find.text('Keep playing'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .paused,
          isFalse,
        );

        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Covered voyage')),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester
              .widget<StormSailingEngine>(
                find.byType(StormSailingEngine, skipOffstage: false),
              )
              .paused,
          isTrue,
        );
        expect(chromeModes.last, 'SystemUiMode.edgeToEdge');
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(chromeModes.last, 'SystemUiMode.edgeToEdge');
        navigator.currentState!.pop();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .paused,
          isFalse,
        );
        expect(chromeModes.last, 'SystemUiMode.immersiveSticky');

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .paused,
          isTrue,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .paused,
          isFalse,
        );
        expect(chromeModes.last, 'SystemUiMode.immersiveSticky');
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(chromeModes.last, 'SystemUiMode.edgeToEdge');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('leaving holds the voyage paused throughout the route pop', (
      tester,
    ) async {
      _useSailingSurface(tester);
      final repository = _FakeGameRepository(games: [_sailingGame]);
      bool? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  changed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => GamePlayScreen(
                        game: _sailingGame,
                        profile: _ada,
                        repository: repository,
                      ),
                    ),
                  );
                },
                child: const Text('Open voyage'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open voyage'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      tester
          .widget<StormSailingEngine>(find.byType(StormSailingEngine))
          .onExit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Leave'));
      await tester.pump();
      expect(
        tester
            .widget<StormSailingEngine>(find.byType(StormSailingEngine))
            .paused,
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester
            .widget<StormSailingEngine>(find.byType(StormSailingEngine))
            .paused,
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(StormSailingEngine), findsNothing);
      expect(find.text('Open voyage'), findsOneWidget);
      expect(changed, isFalse);
      expect(repository.submissions, isEmpty);
    });

    testWidgets(
      'a completed voyage saves once, retries its receipt, and opens the next sea',
      (tester) async {
        _useSailingSurface(tester);
        final chromeModes = _recordChromeModes(tester);
        final repository = _FakeGameRepository(
          games: [_sailingGame],
          submitFailuresRemaining: 1,
          idempotentReplay: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: GamePlayScreen(
              game: _sailingGame,
              profile: _ada,
              repository: repository,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final engine = tester.widget<StormSailingEngine>(
          find.byType(StormSailingEngine),
        );
        final voyage = _sailingResult();
        engine.onComplete(voyage);
        engine.onComplete(voyage);
        await tester.pump(const Duration(milliseconds: 100));

        expect(repository.submissions, hasLength(1));
        expect(repository.submissions.single.slug, _sailingGame.slug);
        expect(repository.submissions.single.profileId, _ada.id);
        expect(repository.submissions.single.level, 1);
        expect(repository.submissions.single.result, voyage);
        final operation = repository.submissions.single.operationId;
        expect(
          find.byKey(const Key('sailing-fullscreen-level')),
          findsOneWidget,
        );
        expect(find.text('Could not save that try.'), findsOneWidget);
        expect(find.byKey(const Key('game-completion')), findsNothing);
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .paused,
          isTrue,
        );

        await tester.tap(find.byKey(const Key('retry-game-save')));
        await tester.pump(const Duration(milliseconds: 800));
        expect(repository.submissions, hasLength(2));
        expect(repository.submissions.last.operationId, operation);
        expect(repository.submissions.last.result, voyage);
        expect(repository.maxConcurrentSubmissions, 1);
        expect(find.byKey(const Key('game-completion')), findsOneWidget);
        expect(find.byType(StormSailingEngine), findsNothing);
        await tester.tap(find.byKey(const Key('next-level-button')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const Key('sailing-start')), findsOneWidget);
        expect(find.byKey(const Key('start-level-button')), findsNothing);
        expect(find.byKey(const Key('game-level-progress')), findsNothing);
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .level
              .number,
          2,
        );
        expect(chromeModes.last, 'SystemUiMode.immersiveSticky');
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'an in-flight save pauses the engine and prevents another send',
      (tester) async {
        _useSailingSurface(tester);
        final saved = Completer<void>();
        final repository = _FakeGameRepository(
          games: [_sailingGame],
          submissionBarrier: saved.future,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: GamePlayScreen(
              game: _sailingGame,
              profile: _ada,
              repository: repository,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final engine = tester.widget<StormSailingEngine>(
          find.byType(StormSailingEngine),
        );
        engine.onComplete(_sailingResult());
        await tester.pump();
        expect(find.text('Saving this voyage…'), findsOneWidget);
        expect(find.byKey(const Key('game-completion')), findsNothing);
        expect(
          tester
              .widget<StormSailingEngine>(find.byType(StormSailingEngine))
              .paused,
          isTrue,
        );
        engine.onExit();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Leave this voyage?'), findsNothing);
        expect(find.text('Saving this voyage…'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.text('Leave this voyage?'), findsNothing);
        expect(find.byType(StormSailingEngine), findsOneWidget);
        engine.onComplete(_sailingResult());
        await tester.pump();
        expect(repository.submissions, hasLength(1));
        saved.complete();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byKey(const Key('game-completion')), findsOneWidget);
        expect(repository.submissions, hasLength(1));
      },
    );

    testWidgets('a rejected voyage restarts a fresh full-screen operation', (
      tester,
    ) async {
      _useSailingSurface(tester);
      final repository = _FakeGameRepository(
        games: [_sailingGame],
        submitFailuresRemaining: 1,
        submitFailureStatusCode: 409,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GamePlayScreen(
            game: _sailingGame,
            profile: _ada,
            repository: repository,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final oldState = tester.state(find.byType(StormSailingEngine));
      tester
          .widget<StormSailingEngine>(find.byType(StormSailingEngine))
          .onComplete(_sailingResult());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('retry-game-save')), findsNothing);
      expect(find.byKey(const Key('redo-game-level')), findsOneWidget);
      final rejectedOperation = repository.submissions.single.operationId;
      await tester.tap(find.byKey(const Key('redo-game-level')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.state(find.byType(StormSailingEngine)),
        isNot(same(oldState)),
      );
      expect(find.byKey(const Key('sailing-start')), findsOneWidget);
      expect(
        tester
            .widget<StormSailingEngine>(find.byType(StormSailingEngine))
            .paused,
        isFalse,
      );
      tester
          .widget<StormSailingEngine>(find.byType(StormSailingEngine))
          .onComplete(_sailingResult());
      await tester.pump(const Duration(milliseconds: 800));
      expect(repository.submissions, hasLength(2));
      expect(repository.submissions.last.operationId, isNot(rejectedOperation));
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
    });

    testWidgets('a saved sailing milestone restores chrome after Continue', (
      tester,
    ) async {
      _useSailingSurface(tester);
      final chromeModes = _recordChromeModes(tester);
      final store = MemoryLevelMilestoneStore();
      final repository = _FakeGameRepository(
        games: [_sailingGame],
        levelMilestone: _levelEightMilestone,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: GamePlayScreen(
            game: _sailingGame,
            profile: _ada,
            repository: repository,
            authRepository: await _activeAuth(),
            milestoneStore: store,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      tester
          .widget<StormSailingEngine>(find.byType(StormSailingEngine))
          .onComplete(_sailingResult());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
      expect(await store.highestPresentedLevel(_ada.id), 8);
      expect(chromeModes.last, 'SystemUiMode.edgeToEdge');
      await tester.tap(find.byKey(const Key('level-milestone-continue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(chromeModes.last, 'SystemUiMode.immersiveSticky');
      expect(repository.submissions, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(chromeModes.last, 'SystemUiMode.edgeToEdge');
    });

    testWidgets('legacy maze and Red Sea levels keep their existing intro', (
      tester,
    ) async {
      _useSailingSurface(tester);
      final chromeModes = _recordChromeModes(tester);
      for (final game in [_mazeGame, _redSeaGame]) {
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(game.slug),
            home: GamePlayScreen(
              game: game,
              profile: _ada,
              repository: _FakeGameRepository(games: [game]),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(StormSailingEngine), findsNothing);
        expect(find.byKey(const Key('start-level-button')), findsOneWidget);
        expect(find.byKey(const Key('game-level-progress')), findsOneWidget);
        await tester.tap(find.byKey(const Key('start-level-button')));
        await tester.pumpAndSettle();
        expect(find.byType(GameLevelEngine), findsOneWidget);
        expect(find.byType(StormSailingEngine), findsNothing);
      }
      expect(chromeModes, isEmpty);
    });
  });

  group('full-screen Red Sea crossing route', () {
    testWidgets('new crossing owns the viewport and pauses for exit', (
      tester,
    ) async {
      _useSailingSurface(tester);
      final chromeModes = _recordChromeModes(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: GamePlayScreen(
            game: _crossingGame,
            profile: _ada,
            repository: _FakeGameRepository(games: [_crossingGame]),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('red-sea-open')), findsOneWidget);
      expect(find.byKey(const Key('start-level-button')), findsNothing);
      expect(find.byKey(const Key('game-level-progress')), findsNothing);
      expect(find.byType(StormSailingEngine), findsNothing);
      expect(
        tester.getRect(find.byKey(const Key('red-sea-crossing-board'))),
        const Rect.fromLTWH(0, 0, 390, 844),
      );
      expect(chromeModes.last, 'SystemUiMode.immersiveSticky');
      tester
          .widget<RedSeaCrossingEngine>(find.byType(RedSeaCrossingEngine))
          .onExit();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Leave this crossing?'), findsOneWidget);
      expect(
        tester
            .widget<RedSeaCrossingEngine>(find.byType(RedSeaCrossingEngine))
            .paused,
        isTrue,
      );
      await tester.tap(find.text('Keep playing'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<RedSeaCrossingEngine>(find.byType(RedSeaCrossingEngine))
            .paused,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(chromeModes.last, 'SystemUiMode.edgeToEdge');
    });

    testWidgets('save retry preserves drops and next course opens directly', (
      tester,
    ) async {
      _useSailingSurface(tester);
      final repository = _FakeGameRepository(
        games: [_crossingGame],
        submitFailuresRemaining: 1,
        idempotentReplay: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GamePlayScreen(
            game: _crossingGame,
            profile: _ada,
            repository: repository,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final outcome = _crossingResult();
      tester
          .widget<RedSeaCrossingEngine>(find.byType(RedSeaCrossingEngine))
          .onComplete(outcome);
      await tester.pump(const Duration(milliseconds: 100));
      final operation = repository.submissions.single.operationId;
      expect(repository.submissions.single.result, outcome);
      expect(find.text('Could not save that try.'), findsOneWidget);
      expect(find.byKey(const Key('red-sea-fullscreen-level')), findsOneWidget);
      expect(
        tester
            .widget<RedSeaCrossingEngine>(find.byType(RedSeaCrossingEngine))
            .paused,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('retry-game-save')));
      await tester.pump(const Duration(milliseconds: 800));
      expect(repository.submissions, hasLength(2));
      expect(repository.submissions.last.result, outcome);
      expect(repository.submissions.last.operationId, operation);
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      await tester.tap(find.byKey(const Key('next-level-button')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('red-sea-open')), findsOneWidget);
      expect(find.byKey(const Key('start-level-button')), findsNothing);
      expect(
        tester
            .widget<RedSeaCrossingEngine>(find.byType(RedSeaCrossingEngine))
            .level
            .number,
        2,
      );
      expect(repository.maxConcurrentSubmissions, 1);
    });

    testWidgets(
      'partial timeout uses server failure and retries a fresh crossing',
      (tester) async {
        _useSailingSurface(tester);
        final repository = _FakeGameRepository(
          games: [_crossingGame],
          submissionCompleted: false,
          submissionCorrect: false,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: GamePlayScreen(
              game: _crossingGame,
              profile: _ada,
              repository: repository,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        tester
            .widget<RedSeaCrossingEngine>(find.byType(RedSeaCrossingEngine))
            .onComplete(_crossingResult(placed: 2, elapsedMs: 45000));
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byKey(const Key('game-completion')), findsNothing);
        expect(find.byKey(const Key('retry-level-button')), findsOneWidget);
        expect(find.byType(RedSeaCrossingEngine), findsNothing);
        expect(find.byKey(const Key('game-level-progress')), findsNothing);
        expect(find.text('0/3'), findsOneWidget);
        await tester.tap(find.byKey(const Key('retry-level-button')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('red-sea-open')), findsOneWidget);
        expect(find.byKey(const Key('start-level-button')), findsNothing);
        expect(find.text('0 / 6 safe'), findsOneWidget);
        expect(repository.submissions, hasLength(1));
      },
    );
  });

  group('overall level milestones after a saved quest', () {
    testWidgets('7 to 8 opens once and Continue preserves the saved result', (
      tester,
    ) async {
      _useTallSurface(tester);
      final store = MemoryLevelMilestoneStore();
      final repository = _FakeGameRepository(
        games: [_quizGame],
        levelMilestone: _levelEightMilestone,
      );
      final auth = await _activeAuth();
      await _pumpMilestoneQuest(tester, repository, auth, store);
      await _completeMilestoneQuiz(tester);

      expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
      expect(find.text('You reached\nlevel 8!'), findsOneWidget);
      expect(await store.highestPresentedLevel(_ada.id), 8);
      expect(repository.submissions, hasLength(1));
      await tester.tap(find.byKey(const Key('level-milestone-continue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(find.text('10/10'), findsOneWidget);
      expect(find.text('3/3'), findsOneWidget);
      expect(repository.submissions, hasLength(1));

      // Returning the same transition on another receipt cannot celebrate it twice.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await _pumpMilestoneQuest(tester, repository, auth, store);
      await _completeMilestoneQuiz(tester);
      expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(repository.submissions, hasLength(2));
    });

    testWidgets('a lost-response retry can celebrate its idempotent receipt', (
      tester,
    ) async {
      _useTallSurface(tester);
      final store = MemoryLevelMilestoneStore();
      final repository = _FakeGameRepository(
        games: [_quizGame],
        submitFailuresRemaining: 1,
        idempotentReplay: true,
        levelMilestone: _levelEightMilestone,
      );
      await _pumpMilestoneQuest(tester, repository, await _activeAuth(), store);
      await _completeMilestoneQuiz(tester);
      expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
      expect(await store.highestPresentedLevel(_ada.id), 0);
      await tester.tap(find.byKey(const Key('retry-game-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
      expect(repository.submissions, hasLength(2));
      expect(
        repository.submissions.last.operationId,
        repository.submissions.first.operationId,
      );
      expect(await store.highestPresentedLevel(_ada.id), 8);
      await tester.tap(find.byKey(const Key('level-milestone-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(find.text('3/3'), findsOneWidget);
    });

    testWidgets('a switched child cannot see another child’s milestone', (
      tester,
    ) async {
      _useTallSurface(tester);
      final store = MemoryLevelMilestoneStore();
      final barrier = Completer<void>();
      final auth = await _activeAuth();
      final repository = _FakeGameRepository(
        games: [_quizGame],
        levelMilestone: _levelEightMilestone,
        submissionBarrier: barrier.future,
      );
      await _pumpMilestoneQuest(tester, repository, auth, store);
      await _completeMilestoneQuiz(tester, waitForReceipt: false);
      expect(repository.submissions, hasLength(1));
      await auth.selectKid(_nia);
      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(await store.highestPresentedLevel(_ada.id), 0);
      expect(await store.highestPresentedLevel(_nia.id), 0);
    });

    testWidgets(
      'a completion without a level transition shows its normal result',
      (tester) async {
        _useTallSurface(tester);
        final store = MemoryLevelMilestoneStore(levels: {_ada.id: 7});
        await _pumpMilestoneQuest(
          tester,
          _FakeGameRepository(games: [_quizGame]),
          await _activeAuth(),
          store,
        );
        await _completeMilestoneQuiz(tester);
        expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
        expect(find.byKey(const Key('game-completion')), findsOneWidget);
        expect(await store.highestPresentedLevel(_ada.id), 7);
      },
    );

    testWidgets(
      'a background receipt waits for resume before being presented',
      (tester) async {
        _useTallSurface(tester);
        final store = MemoryLevelMilestoneStore();
        final barrier = Completer<void>();
        final repository = _FakeGameRepository(
          games: [_quizGame],
          levelMilestone: _levelEightMilestone,
          submissionBarrier: barrier.future,
        );
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        await _pumpMilestoneQuest(
          tester,
          repository,
          await _activeAuth(),
          store,
        );
        await _completeMilestoneQuiz(tester, waitForReceipt: false);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        barrier.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
        expect(await store.highestPresentedLevel(_ada.id), 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
        expect(await store.highestPresentedLevel(_ada.id), 8);
        await tester.tap(find.byKey(const Key('level-milestone-continue')));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'a local celebration-store failure keeps the saved quest usable',
      (tester) async {
        _useTallSurface(tester);
        final repository = _FakeGameRepository(
          games: [_quizGame],
          levelMilestone: _levelEightMilestone,
        );
        await _pumpMilestoneQuest(
          tester,
          repository,
          await _activeAuth(),
          _UnavailableMilestoneStore(),
        );
        await _completeMilestoneQuiz(tester);
        expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
        expect(find.byKey(const Key('game-completion')), findsOneWidget);
        expect(find.text('Could not save that try.'), findsNothing);
        expect(find.byKey(const Key('finish-game-button')), findsOneWidget);
        expect(repository.submissions, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a failed presentation watermark cannot lose a saved reward', (
      tester,
    ) async {
      _useTallSurface(tester);
      final repository = _FakeGameRepository(
        games: [_quizGame],
        levelMilestone: _levelEightMilestone,
      );
      await _pumpMilestoneQuest(
        tester,
        repository,
        await _activeAuth(),
        _UnavailableMilestoneStore(failOnRead: false),
      );
      await _completeMilestoneQuiz(tester);
      expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('level-milestone-continue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('game-completion')), findsOneWidget);
      expect(find.text('3/3'), findsOneWidget);
      expect(repository.submissions, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('story game routing', () {
    testWidgets('creation requires placing every day before submitting', (
      tester,
    ) async {
      Map<String, dynamic>? result;
      await _pumpEngine(
        tester,
        type: GameType.ordering,
        config: {
          'items': [
            {'id': 'day-2', 'label': 'Sky', 'asset_key': '☁️'},
            {'id': 'day-1', 'label': 'Light', 'asset_key': '💡'},
          ],
        },
        onComplete: (value) => result = value,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byKey(const Key('ordering-check')),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('creation-tile-day-2')));
      await tester.tap(find.byKey(const Key('creation-day-0')));
      await tester.tap(find.byKey(const Key('creation-tile-day-1')));
      await tester.tap(find.byKey(const Key('creation-day-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ordering-check')));
      expect(result, {
        'sequence': ['day-2', 'day-1'],
      });
    });

    testWidgets('Moses matching preserves the server pair contract', (
      tester,
    ) async {
      Map<String, dynamic>? result;
      await _pumpEngine(
        tester,
        type: GameType.matching,
        config: {
          'left_items': [
            {'id': 'staff', 'label': 'Staff', 'asset_key': '🪄'},
            {'id': 'tablets', 'label': 'Tablets', 'asset_key': '📜'},
          ],
          'right_items': [
            {'id': 'lead', 'label': 'Leadership', 'asset_key': '👣'},
            {'id': 'law', 'label': 'God’s law', 'asset_key': '✨'},
          ],
        },
        onComplete: (value) => result = value,
      );
      await tester.tap(find.byKey(const Key('match-left-staff')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('match-right-lead')));
      await tester.tap(find.byKey(const Key('match-left-tablets')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('match-right-law')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('matching-check')));
      expect(result?['pairs'], [
        {'left_id': 'staff', 'right_id': 'lead'},
        {'left_id': 'tablets', 'right_id': 'law'},
      ]);
    });

    testWidgets('timed Ark mode opens the boarding arena', (tester) async {
      await _pumpEngine(
        tester,
        type: GameType.matching,
        config: {
          'mode': 'ark_boarding',
          'time_limit_seconds': 45,
          'goal_pairs': 1,
          'left_items': [
            {'id': 'lion-1', 'label': 'Lion', 'asset_key': 'animal:lion'},
          ],
          'right_items': [
            {'id': 'lion-2', 'label': 'Lion', 'asset_key': 'animal:lion'},
          ],
        },
        onComplete: (_) {},
      );
      expect(find.byKey(const Key('ark-boarding-engine')), findsOneWidget);
      expect(find.text('Moses’ story links'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('David uses pull and release with no tap to hit shortcut', (
      tester,
    ) async {
      Map<String, dynamic>? result;
      await _pumpEngine(
        tester,
        type: GameType.aim,
        config: {
          'canvas': {'width': 320, 'height': 420},
          'target': {'x': 160, 'y': 180, 'radius': 58},
          'max_shots': 3,
          'obstacles': <Object>[],
        },
        onComplete: (value) => result = value,
      );
      expect(find.byKey(const Key('aim-target-action')), findsNothing);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('sling-board'))),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(result, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

Future<void> _pumpEngine(
  WidgetTester tester, {
  required GameType type,
  required Map<String, dynamic> config,
  required ValueChanged<Map<String, dynamic>> onComplete,
}) async {
  _useTallSurface(tester);
  final engine = GameLevelEngine(
    type: type,
    level: GameLevel(
      id: 'level-1',
      number: 1,
      title: 'Test level',
      instructions: 'Play carefully',
      config: config,
      maxScore: 10,
    ),
    onComplete: onComplete,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: type == GameType.aim
            ? engine
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: engine,
              ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _ensureGameControl(WidgetTester tester, Key key) async {
  final control = find.byKey(key);
  if (control.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      control,
      220,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('games-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(control);
  await tester.pumpAndSettle();
}

Future<void> _showGameSearch(WidgetTester tester) async {
  if (find.byKey(const Key('game-search-field')).evaluate().isNotEmpty) return;
  final toggle = find.byKey(const Key('game-search-toggle'));
  await _ensureGameControl(tester, const Key('game-search-toggle'));
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

Future<void> _enterGameSearch(WidgetTester tester, String query) async {
  await _showGameSearch(tester);
  final field = find.byKey(const Key('game-search-field'));
  await tester.ensureVisible(field);
  await tester.enterText(field, query);
}

Future<void> _openGameCategoryMenu(WidgetTester tester) async {
  final button = find.byKey(const Key('game-filter-button'));
  await _ensureGameControl(tester, const Key('game-filter-button'));
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _selectGameCategory(WidgetTester tester, String category) async {
  await _openGameCategoryMenu(tester);
  final option = find.byKey(Key('game-filter-$category'));
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

Future<void> _expectGameCategories(
  WidgetTester tester, {
  List<String> present = const [],
  List<String> absent = const [],
}) async {
  await _openGameCategoryMenu(tester);
  for (final category in present) {
    expect(find.byKey(Key('game-filter-$category')), findsOneWidget);
  }
  for (final category in absent) {
    expect(find.byKey(Key('game-filter-$category')), findsNothing);
  }
  Navigator.of(tester.element(find.byKey(const Key('game-filter-all')))).pop();
  await tester.pumpAndSettle();
}

void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1200);
  addTearDown(tester.view.reset);
}

void _useSmallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.reset);
}

MiniGame _completionGame(GameType type) {
  return MiniGame(
    id: '${type.name}-celebration',
    slug: '${type.name}-celebration',
    title: '${type.label} Celebration',
    type: type.legacyType,
    gameType: type,
    difficulty: 'Easy',
    duration: '1 min',
    imageAsset: '',
    description: 'A focused celebration test.',
    rewardStars: 3,
    totalLevels: 1,
    accentColor: '#7653E8',
  );
}

GameSubmission _completionSubmission(GameType type) {
  return GameSubmission(
    attemptId: '${type.name}-attempt',
    operationId: '${type.name}-operation',
    gameSlug: '${type.name}-celebration',
    profileId: _ada.id,
    levelNumber: 1,
    completed: true,
    correct: false,
    score: 7,
    maxScore: 10,
    starsAwarded: 2,
    feedback: '',
    progress: const GameProgress(
      profileId: 'kid-1',
      highestCompletedLevel: 1,
      currentLevel: 1,
      completedLevels: 1,
      totalLevels: 1,
      bestScore: 7,
      starsEarned: 2,
      maxStars: 3,
      percent: 1,
    ),
    idempotentReplay: false,
  );
}

Future<AuthRepository> _activeAuth() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(
    const AuthSession(
      parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
      accessToken: 'access-token',
      profiles: [_ada, _nia],
    ),
  );
  await store.writeSelectedKidId(_ada.id);
  return AuthRepository(sessionStore: store);
}

const _ada = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Ada',
  avatarKey: 'dove',
);

const _nia = KidProfile(
  id: 'kid-2',
  parentId: 'parent-1',
  displayName: 'Nia',
  avatarKey: 'nia',
);

const _levelEightMilestone = LevelMilestone(
  previousLevel: 7,
  level: ProfileLevel(
    number: 8,
    title: 'Faithful Adventurer',
    xp: 2100,
    nextLevelXp: 2400,
  ),
);

Future<void> _pumpMilestoneQuest(
  WidgetTester tester,
  _FakeGameRepository repository,
  AuthRepository auth,
  LevelMilestoneStore store,
) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: GamePlayScreen(
        game: _quizGame,
        profile: _ada,
        repository: repository,
        authRepository: auth,
        milestoneStore: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _completeMilestoneQuiz(
  WidgetTester tester, {
  bool waitForReceipt = true,
}) async {
  await tester.tap(find.byKey(const Key('start-level-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('quiz-option-b')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('quiz-continue')));
  if (waitForReceipt) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

class _UnavailableMilestoneStore implements LevelMilestoneStore {
  _UnavailableMilestoneStore({this.failOnRead = true});

  final bool failOnRead;

  @override
  Future<int> highestPresentedLevel(String profileId) async {
    if (failOnRead) throw StateError('Local storage unavailable');
    return 0;
  }

  @override
  Future<void> markPresented(String profileId, int level) async =>
      throw StateError('Local storage unavailable');
}

final _quizLevel = GameLevel(
  id: 'quiz-1',
  number: 1,
  title: 'A brave choice',
  instructions: 'Choose the best answer.',
  maxScore: 10,
  config: {
    'questions': [
      {
        'id': 'q1',
        'prompt': 'Who chose courage?',
        'options': [
          {'id': 'a', 'text': 'Haman'},
          {'id': 'b', 'text': 'Esther'},
        ],
      },
    ],
  },
);

final _retiredMemoryGame = MiniGame(
  id: 'daniel-memory',
  slug: 'daniel-memory',
  title: 'Daniel Memory Match',
  type: MiniGameType.memory,
  gameType: GameType.memory,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
  description: 'Remember the lions.',
  rewardStars: 9,
  totalLevels: 3,
  isFeatured: true,
  playerProgress: const GameProgress(
    profileId: 'kid-1',
    totalLevels: 3,
    completedLevels: 1,
    starsEarned: 3,
    maxStars: 9,
  ),
);

const _retiredPathGame = MiniGame(
  id: 'red-sea-path',
  slug: 'red-sea-path',
  title: 'Red Sea Crossing',
  type: MiniGameType.puzzle,
  gameType: GameType.path,
  difficulty: 'Easy',
  duration: '45 sec',
  imageAsset: 'assets/images/stories/crossing-the-red-sea-v2.webp',
  description: 'Help everyone cross the dry path.',
  rewardStars: 9,
  totalLevels: 3,
  isFeatured: true,
  playerProgress: GameProgress(
    profileId: 'kid-1',
    totalLevels: 3,
    completedLevels: 2,
    starsEarned: 6,
    maxStars: 9,
  ),
);

const _retiredCreationGame = MiniGame(
  id: 'creation-order',
  slug: 'creation-order',
  title: 'Creation Order',
  type: MiniGameType.dragAndDrop,
  gameType: GameType.ordering,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: 'assets/images/stories/creation-week-v2.webp',
  description: 'Build a living world through the creation days.',
  rewardStars: 9,
  totalLevels: 3,
  isFeatured: true,
  playerProgress: GameProgress(
    profileId: 'kid-1',
    totalLevels: 3,
    completedLevels: 2,
    starsEarned: 6,
    maxStars: 9,
  ),
);

const _retiredBuildersGame = MiniGame(
  id: 'wise-and-foolish-builders',
  slug: 'wise-and-foolish-builders',
  title: 'Wise and Foolish Builders',
  type: MiniGameType.dragAndDrop,
  gameType: GameType.ordering,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: 'assets/images/stories/creation-week-v2.webp',
  description: 'Build two houses and test their foundations.',
  rewardStars: 9,
  totalLevels: 3,
  isFeatured: true,
  playerProgress: GameProgress(
    profileId: 'kid-1',
    totalLevels: 3,
    completedLevels: 2,
    starsEarned: 6,
    maxStars: 9,
  ),
);

const _otherOrderGame = MiniGame(
  id: 'another-order-quest',
  slug: 'another-order-quest',
  title: 'Another Order Quest',
  type: MiniGameType.dragAndDrop,
  gameType: GameType.ordering,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: 'assets/images/stories/creation-week-v2.webp',
  description: 'An unrelated available ordering quest.',
  rewardStars: 9,
  totalLevels: 3,
);

const _matchingGame = MiniGame(
  id: 'moses-match',
  slug: 'moses-match',
  title: 'Moses Matching',
  type: MiniGameType.matching,
  gameType: GameType.matching,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: 'assets/images/stories/moses-follows-god-v2.webp',
  description: 'Match the story pictures.',
  rewardStars: 9,
  totalLevels: 3,
);

const _retiredArkGame = MiniGame(
  id: 'ark-animal-match',
  slug: 'ark-animal-match',
  title: 'Noah’s Ark Rescue',
  type: MiniGameType.matching,
  gameType: GameType.matching,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: 'assets/images/stories/noah-builds-the-ark-v2.webp',
  description: 'Guide animals onto the ark.',
  rewardStars: 9,
  totalLevels: 3,
  isFeatured: true,
);

const _keptQuizSlugs = {
  'esther-quiz',
  'noah-quiz',
  'david-quiz',
  'jonah-quiz',
  'lost-sheep-quiz',
};

const _keptPuzzleSlugs = {
  'puzzle-quest',
  'puzzle-esther',
  'puzzle-noah',
  'puzzle-david',
  'puzzle-lost-sheep',
};

final _matchingCatalogueGames = [
  for (final (slug, title, cover) in const [
    ('josephs-coat-studio', 'Joseph’s Coat Studio', 'joseph_atelier.png'),
    ('ruths-harvest', 'Ruth’s Harvest', 'ruth_field.png'),
    ('find-my-sheep', 'Find My Sheep', 'sheep_meadow.png'),
    ('creation-match-bloom', 'Creation: Match & Bloom', 'creation_garden.png'),
    (
      'esthers-celebration-table',
      'Esther’s Celebration Table',
      'esther_banquet_fullscreen_v2.png',
    ),
  ])
    MiniGame.fromJson({
      'id': slug,
      'slug': slug,
      'title': title,
      'game_type': 'matching',
      'cover_asset_key': 'assets/images/games/matching/$cover',
      'total_levels': 3,
    }),
];

final _storyPicturePuzzles = [
  for (final (slug, title, cover) in const [
    (
      'puzzle-quest',
      'Puzzle Quest',
      'assets/images/games/puzzle_quest/puzzle-quest-cover-v1.webp',
    ),
    (
      'puzzle-esther',
      'Esther Picture Puzzle',
      'assets/images/stories/esther-speaks-up-v2.webp',
    ),
    (
      'puzzle-noah',
      'Noah’s Ark Picture Puzzle',
      'assets/images/stories/noah-builds-the-ark-v2.webp',
    ),
    (
      'puzzle-david',
      'David Picture Puzzle',
      'assets/images/stories/david-and-goliath-v2.webp',
    ),
    (
      'puzzle-red-sea',
      'The Red Sea Picture Puzzle',
      'assets/images/stories/crossing-the-red-sea-v2.webp',
    ),
    (
      'puzzle-jonah',
      'Jonah Picture Puzzle',
      'assets/images/stories/jonah-and-the-big-fish-v2.webp',
    ),
    (
      'puzzle-lost-sheep',
      'The Lost Sheep Picture Puzzle',
      'assets/images/stories/lost-sheep-storybook-v1.webp',
    ),
    (
      'puzzle-joseph-colorful-coat',
      'Joseph’s Coat Picture Puzzle',
      'assets/images/stories/joseph-colorful-coat-storybook-v1.webp',
    ),
    (
      'puzzle-good-samaritan',
      'The Good Samaritan Picture Puzzle',
      'assets/images/stories/good-samaritan-storybook-v1.webp',
    ),
    (
      'puzzle-walls-of-jericho',
      'Jericho Picture Puzzle',
      'assets/images/stories/walls-of-jericho-storybook-v1.webp',
    ),
    (
      'puzzle-ruth-and-naomi',
      'Ruth and Naomi Picture Puzzle',
      'assets/images/stories/ruth-and-naomi-storybook-v1.webp',
    ),
  ])
    MiniGame.fromJson({
      'id': slug,
      'slug': slug,
      'title': title,
      'description': 'Put the picture pieces in place.',
      'game_type': 'puzzle',
      'cover_asset_key': cover,
      'total_levels': 3,
    }),
];

final _storyQuizzes = [
  for (final (slug, title, cover) in const [
    ('esther-quiz', 'Esther Brave Quiz', 'esther-speaks-up-v2.webp'),
    ('noah-quiz', 'Noah’s Ark Quiz', 'noah-builds-the-ark-v2.webp'),
    ('david-quiz', 'David and Goliath Quiz', 'david-and-goliath-v2.webp'),
    (
      'jonah-quiz',
      'Jonah and the Big Fish Quiz',
      'jonah-and-the-big-fish-v2.webp',
    ),
    ('creation-quiz', 'Creation Week Quiz', 'creation-week-v2.webp'),
    ('lost-sheep-quiz', 'The Lost Sheep Quiz', 'lost-sheep-storybook-v1.webp'),
    (
      'joseph-colorful-coat-quiz',
      'Joseph’s Colorful Coat Quiz',
      'joseph-colorful-coat-storybook-v1.webp',
    ),
    (
      'good-samaritan-quiz',
      'The Good Samaritan Quiz',
      'good-samaritan-storybook-v1.webp',
    ),
    (
      'walls-of-jericho-quiz',
      'The Walls of Jericho Quiz',
      'walls-of-jericho-storybook-v1.webp',
    ),
    (
      'ruth-and-naomi-quiz',
      'Ruth and Naomi Quiz',
      'ruth-and-naomi-storybook-v1.webp',
    ),
  ])
    MiniGame.fromJson({
      'id': slug,
      'slug': slug,
      'title': title,
      'subtitle': 'Explore a favorite Bible story.',
      'description': 'Choose answers and remember the story together.',
      'game_type': 'quiz',
      'cover_asset_key': 'assets/images/stories/$cover',
      'estimated_duration_seconds': 180,
      'total_levels': 3,
      'progress': {'profile_id': 'kid-1', 'total_levels': 3, 'max_stars': 9},
      'levels': [
        for (var round = 1; round <= 3; round++)
          {
            'id': '$slug-round-$round',
            'level_number': round,
            'title': slug == 'noah-quiz' ? 'Meet Noah' : 'Remember the story',
            'instructions': 'Choose one kind answer for each question.',
            'max_score': 30,
            'config': {
              'questions': [
                for (var question = 1; question <= 3; question++)
                  {
                    'id': '$slug-q$question',
                    'prompt': const [
                      'Who built the ark?',
                      'What did Noah build?',
                      'Who came onto the ark?',
                    ][question - 1],
                    'options': [
                      {
                        'id': 'a',
                        'text': const [
                          'Jonah',
                          'A tower',
                          'Only stones',
                        ][question - 1],
                      },
                      {
                        'id': 'b',
                        'text': const [
                          'Noah',
                          'An ark',
                          'The animals',
                        ][question - 1],
                      },
                    ],
                  },
              ],
            },
          },
      ],
    }),
];

final _quizLevelTwo = GameLevel(
  id: 'quiz-2',
  number: 2,
  title: 'A second brave choice',
  instructions: 'Choose another brave answer.',
  maxScore: 10,
  config: {
    'questions': [
      {
        'id': 'q2',
        'prompt': 'Who showed courage again?',
        'options': [
          {'id': 'a', 'text': 'Haman'},
          {'id': 'b', 'text': 'Esther'},
        ],
      },
    ],
  },
);

final _quizGame = MiniGame(
  id: 'esther-quiz',
  slug: 'esther-quiz',
  title: 'Esther Brave Quiz',
  subtitle: 'Courage at the right time',
  type: MiniGameType.quiz,
  gameType: GameType.quiz,
  difficulty: 'Easy',
  duration: '3 min',
  estimatedDurationSeconds: 180,
  imageAsset: 'assets/images/esther.jpeg',
  coverAssetKey: 'assets/images/esther.jpeg',
  description: 'Answer gentle questions about Esther.',
  rewardStars: 3,
  totalLevels: 1,
  isFeatured: true,
  levels: [_quizLevel],
  playerProgress: const GameProgress(
    profileId: 'kid-1',
    currentLevel: 1,
    totalLevels: 1,
    completedLevels: 0,
    starsEarned: 1,
    maxStars: 3,
    percent: 0,
  ),
);

final _twoLevelQuizGame = MiniGame(
  id: 'esther-quiz-two-levels',
  slug: 'esther-quiz-two-levels',
  title: 'Esther Brave Quiz',
  subtitle: 'Courage at the right time',
  type: MiniGameType.quiz,
  gameType: GameType.quiz,
  difficulty: 'Easy',
  duration: '4 min',
  estimatedDurationSeconds: 240,
  imageAsset: 'assets/images/esther.jpeg',
  coverAssetKey: 'assets/images/esther.jpeg',
  description: 'Answer gentle questions about Esther.',
  rewardStars: 6,
  totalLevels: 2,
  levels: [_quizLevel, _quizLevelTwo],
  playerProgress: const GameProgress(
    profileId: 'kid-1',
    currentLevel: 1,
    totalLevels: 2,
    completedLevels: 0,
    maxStars: 6,
    percent: 0,
  ),
);

final _mazeGame = MiniGame(
  id: 'jonah-ocean-maze',
  slug: 'jonah-ocean-maze',
  title: 'Jonah Ocean Maze',
  type: MiniGameType.puzzle,
  gameType: GameType.maze,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: 'assets/images/jonah.jpg',
  coverAssetKey: 'assets/images/jonah.jpg',
  description: 'Guide Jonah through the water.',
  rewardStars: 3,
  totalLevels: 1,
  levels: [
    GameLevel(
      id: 'maze-1',
      number: 1,
      title: 'Find the shore',
      instructions: 'Move right.',
      maxScore: 10,
      config: {
        'grid': {
          'rows': 2,
          'columns': 2,
          'start': [0, 0],
          'end': [0, 1],
          'walls': <Object>[],
        },
      },
    ),
  ],
);

final class _FakeGameRepository implements GameRepository {
  _FakeGameRepository({
    required this.games,
    this.listFailuresRemaining = 0,
    this.listResponse,
    this.listError,
    this.submitFailuresRemaining = 0,
    this.submitFailureStatusCode,
    this.submissionCorrect = true,
    this.submissionCompleted = true,
    this.levelMilestone,
    this.idempotentReplay = false,
    this.submissionBarrier,
  });

  final List<MiniGame> games;
  int listFailuresRemaining;
  final Future<List<MiniGame>>? listResponse;
  final AppException? listError;
  int detailFailuresRemaining = 0;
  int submitFailuresRemaining;
  final int? submitFailureStatusCode;
  final bool submissionCorrect;
  final bool submissionCompleted;
  final LevelMilestone? levelMilestone;
  final bool idempotentReplay;
  final Future<void>? submissionBarrier;
  int detailFetches = 0;
  final List<String> detailSlugs = [];
  final List<String> listProfileIds = [];
  final List<
    ({
      String slug,
      String profileId,
      int level,
      String operationId,
      Map<String, dynamic> result,
    })
  >
  submissions = [];
  int _activeSubmissions = 0;
  int maxConcurrentSubmissions = 0;

  @override
  Future<List<MiniGame>> fetchGames({required String profileId}) async {
    listProfileIds.add(profileId);
    if (listError != null) throw listError!;
    if (listResponse != null) return listResponse!;
    if (listFailuresRemaining > 0) {
      listFailuresRemaining -= 1;
      throw const AppException('The game room is taking a nap.');
    }
    return games;
  }

  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) async {
    detailFetches += 1;
    detailSlugs.add(slug);
    if (detailFailuresRemaining > 0) {
      detailFailuresRemaining -= 1;
      throw const AppException('This quest is unavailable.', statusCode: 404);
    }
    return games.firstWhere((game) => game.slug == slug);
  }

  @override
  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
  }) async {
    _activeSubmissions += 1;
    maxConcurrentSubmissions = mathMax(
      maxConcurrentSubmissions,
      _activeSubmissions,
    );
    submissions.add((
      slug: slug,
      profileId: profileId,
      level: levelNumber,
      operationId: operationId,
      result: result,
    ));
    try {
      if (submissionBarrier case final barrier?) await barrier;
      if (submitFailuresRemaining > 0) {
        submitFailuresRemaining -= 1;
        throw AppException(
          'Could not save that try.',
          statusCode: submitFailureStatusCode,
        );
      }
      return GameSubmission(
        attemptId: 'attempt-1',
        operationId: operationId,
        gameSlug: slug,
        profileId: profileId,
        levelNumber: levelNumber,
        completed: submissionCompleted,
        correct: submissionCorrect,
        score: submissionCompleted ? 10 : 0,
        maxScore: 10,
        starsAwarded: submissionCompleted ? 3 : 0,
        feedback: 'Esther would be proud of that brave answer!',
        progress: const GameProgress(
          profileId: 'kid-1',
          highestCompletedLevel: 1,
          currentLevel: 1,
          completedLevels: 1,
          totalLevels: 1,
          bestScore: 10,
          starsEarned: 3,
          maxStars: 3,
          percent: 1,
        ),
        idempotentReplay: idempotentReplay,
        levelMilestone: levelMilestone,
      );
    } finally {
      _activeSubmissions -= 1;
    }
  }
}

int mathMax(int left, int right) => left > right ? left : right;

void _useSailingSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

List<String> _recordChromeModes(WidgetTester tester) {
  final modes = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        modes.add(call.arguments as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return modes;
}

Map<String, dynamic> _sailingResult() => {
  'voyage': {
    'duration_ms': 60000,
    'samples': [
      for (var milliseconds = 0; milliseconds <= 60000; milliseconds += 100)
        [milliseconds, 0.0],
    ],
  },
};

final _sailingGame = MiniGame(
  id: 'jonah-storm-sailing',
  slug: 'jonah-storm-sailing',
  title: 'Jonah Storm Sailing',
  type: GameType.maze.legacyType,
  gameType: GameType.maze,
  difficulty: 'Easy',
  duration: '1 min',
  imageAsset: '',
  description: 'Guide the ship through the storm.',
  rewardStars: 6,
  totalLevels: 2,
  levels: [
    for (var number = 1; number <= 2; number++)
      GameLevel(
        id: 'jonah-sailing-$number',
        number: number,
        title: 'Storm voyage $number',
        instructions: 'Tilt or steer the wheel to avoid the reefs.',
        maxScore: 100,
        config: {
          'sailing': {
            'duration_seconds': 60,
            'distance_m': 1200,
            'ship_radius': 0.09,
            'collision_window': 0.007,
            'max_hits': 3,
            'steer_speed': 1.4,
            'obstacles': [
              {'id': 'reef-1', 'progress': 0.2, 'x': -0.5, 'radius': 0.16},
              {'id': 'reef-2', 'progress': 0.4, 'x': 0.5, 'radius': 0.16},
            ],
          },
        },
      ),
  ],
  playerProgress: const GameProgress(
    profileId: 'kid-1',
    currentLevel: 1,
    totalLevels: 2,
    completedLevels: 0,
    maxStars: 6,
    percent: 0,
  ),
);

Map<String, dynamic> _crossingResult({int placed = 6, int elapsedMs = 3000}) =>
    {
      'crossing': {
        'elapsed_ms': elapsedMs,
        'placements': [
          for (var index = 1; index <= placed; index++)
            {
              'traveller_id': 'traveller-$index',
              'x': .5,
              'y': .6,
              'released_at_ms': 1000 + (index - 1) * 250,
            },
        ],
      },
    };

final _crossingGame = MiniGame(
  id: 'red-sea-crossing',
  slug: 'red-sea-crossing',
  title: 'Red Sea Crossing',
  type: GameType.path.legacyType,
  gameType: GameType.path,
  difficulty: 'Easy',
  duration: '45 sec',
  imageAsset: '',
  description: 'Help everyone cross safely.',
  rewardStars: 9,
  totalLevels: 3,
  levels: [
    for (var number = 1; number <= 3; number++)
      GameLevel(
        id: 'crossing-$number',
        number: number,
        title: 'A way through the sea',
        instructions: 'Drag everyone onto the dry path.',
        maxScore: 100,
        config: {
          'crossing': {
            'time_limit_seconds': 45,
            'travellers': [
              for (var index = 1; index <= 4 + number * 2; index++)
                {'id': 'traveller-$index', 'label': 'Traveller $index'},
            ],
            'drop_zone': {'left': .34, 'top': .43, 'right': .66, 'bottom': .70},
          },
        },
      ),
  ],
);

final _redSeaGame = MiniGame(
  id: 'red-sea-path',
  slug: 'red-sea-path',
  title: 'Red Sea Crossing',
  type: GameType.path.legacyType,
  gameType: GameType.path,
  difficulty: 'Easy',
  duration: '1 min',
  imageAsset: '',
  description: 'Trace a path through the sea.',
  rewardStars: 3,
  totalLevels: 1,
  levels: [
    GameLevel(
      id: 'red-sea-1',
      number: 1,
      title: 'Find the shore',
      instructions: 'Trace the dry corridor.',
      maxScore: 10,
      config: {
        'grid': {
          'rows': 2,
          'columns': 2,
          'start': [0, 0],
          'end': [0, 1],
          'walls': <Object>[],
        },
      },
    ),
  ],
);

final _davidBattleGame = MiniGame(
  id: 'david-sling-shot',
  slug: 'david-sling-shot',
  title: 'David Sling',
  type: GameType.aim.legacyType,
  gameType: GameType.aim,
  difficulty: 'Easy',
  duration: '3 min',
  imageAsset: '',
  description: 'Pull and release a stone.',
  rewardStars: 3,
  totalLevels: 2,
  levels: [
    for (var number = 1; number <= 2; number++)
      GameLevel(
        id: 'david-battle-$number',
        number: number,
        title: 'David',
        instructions: 'Pull back the pouch. Aim. Release.',
        maxScore: 100,
        config: {
          'canvas': {'width': 320, 'height': 420},
          'target': {'x': 160, 'y': 180, 'radius': 58},
          'max_shots': 3,
          'obstacles': <Object>[],
        },
      ),
  ],
);

String? _imageAssetName(ImageProvider provider) {
  if (provider is ResizeImage) return _imageAssetName(provider.imageProvider);
  if (provider is AssetImage) return provider.assetName;
  if (provider is ExactAssetImage) return provider.assetName;
  return null;
}

// Data, navigation and layout fixtures remain still. Rotation is tested with
// real clocks and finite frames in games_week_rotation_test.dart.
Widget _stillGames(GamesScreen screen) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: screen,
  ),
);
