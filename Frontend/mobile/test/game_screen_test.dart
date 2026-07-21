import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/game_detail_screen.dart';
import 'package:mobile/features/games/presentation/game_engines.dart';
import 'package:mobile/features/games/presentation/game_play_screen.dart';
import 'package:mobile/features/games/presentation/games_screen.dart';

void main() {
  testWidgets('game room loads kid progress, searches, and filters', (
    tester,
  ) async {
    _useTallSurface(tester);
    final auth = await _activeAuth();
    final repository = _FakeGameRepository(games: [_quizGame, _mazeGame]);

    await tester.pumpWidget(
      MaterialApp(
        home: GamesScreen(repository: repository, authRepository: auth),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ready, Ada?'), findsOneWidget);
    expect(find.text('GAME ROOM'), findsNothing);
    expect(find.byKey(const Key('games-header-icon')), findsOneWidget);
    expect(find.text('Esther Brave Quiz'), findsWidgets);
    expect(repository.listProfileIds, ['kid-1']);

    await tester.enterText(find.byKey(const Key('game-search-field')), 'Jonah');
    await tester.pump();
    expect(find.text('Esther Brave Quiz'), findsNothing);
    expect(find.text('Jonah Ocean Maze'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('game-search-field')), '');
    await tester.tap(find.byKey(const Key('game-filter-quiz')));
    await tester.pump();
    expect(find.text('Esther Brave Quiz'), findsOneWidget);
    expect(find.text('Jonah Ocean Maze'), findsNothing);
  });

  testWidgets('game lab announces live progress and actionable quests', (
    tester,
  ) async {
    _useTallSurface(tester);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: GamesScreen(
          repository: _FakeGameRepository(games: [_quizGame, _mazeGame]),
          authRepository: await _activeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('2 quests available. 1 started. 1 star earned.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Today’s big quest\. Esther Brave Quiz\.')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Esther Brave Quiz\. Quiz\. 1 levels\.')),
      findsOneWidget,
    );
    semantics.dispose();
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
        home: GamesScreen(
          repository: repository,
          authRepository: await _activeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The game room is taking a nap.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Esther Brave Quiz'), findsWidgets);
    expect(repository.listProfileIds, ['kid-1', 'kid-1']);
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
    expect(find.text('Quest complete!'), findsOneWidget);
    expect(find.text('10/10'), findsOneWidget);
    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('Level score'), findsOneWidget);
    expect(find.text('Level stars'), findsOneWidget);
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
        home: GamesScreen(
          repository: repository,
          authRepository: await _activeAuth(),
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

    expect(find.byKey(const Key('stale-games-banner')), findsOneWidget);
    expect(find.text('Esther Brave Quiz'), findsWidgets);
    await tester.tap(find.byKey(const Key('retry-stale-games')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('stale-games-banner')), findsNothing);
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
    expect(find.text('Quest complete!'), findsOneWidget);
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
    expect(find.text('Quest complete!'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-detail-title')), findsOneWidget);
    expect(repository.detailFetches, 2);
  });

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

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'game room adapts on a small ${brightness.name} screen with large text',
      (tester) async {
        _useSmallSurface(tester);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 568),
                textScaler: TextScaler.linear(2.2),
              ),
              child: GamesScreen(
                repository: _FakeGameRepository(games: [_quizGame, _mazeGame]),
                authRepository: await _activeAuth(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Ready, Ada?'), findsOneWidget);
        expect(find.byKey(const Key('game-filter-all')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('game-card-esther-quiz')),
          260,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byKey(const Key('game-card-esther-quiz')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
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
      240,
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

  group('code-native engines', () {
    testWidgets('ordering sends the visible sequence', (tester) async {
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

      expect(tester.getSize(find.byTooltip('Move Sky down')).height, 48);

      await tester.tap(find.byKey(const Key('ordering-check')));
      expect(result, {
        'sequence': ['day-2', 'day-1'],
      });
    });

    testWidgets('matching sends each chosen pair', (tester) async {
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
            {'id': 'law', 'label': 'God\'s law', 'asset_key': '✨'},
          ],
        },
        onComplete: (value) => result = value,
      );

      await tester.tap(find.byKey(const Key('match-left-staff')));
      await tester.tap(find.byKey(const Key('match-right-lead')));
      await tester.tap(find.byKey(const Key('match-left-tablets')));
      await tester.tap(find.byKey(const Key('match-right-law')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('matching-check')));

      expect(result?['pairs'], [
        {'left_id': 'staff', 'right_id': 'lead'},
        {'left_id': 'tablets', 'right_id': 'law'},
      ]);
    });

    testWidgets('memory reveals pairs and reports measured play', (
      tester,
    ) async {
      Map<String, dynamic>? result;
      await _pumpEngine(
        tester,
        type: GameType.memory,
        config: {
          'preview_seconds': 0.2,
          'cards': [
            {
              'id': 'lion-1',
              'label': 'Lion',
              'asset_key': '🦁',
              'match_key': 'lion',
            },
            {
              'id': 'lion-2',
              'label': 'Lion',
              'asset_key': '🦁',
              'match_key': 'lion',
            },
          ],
        },
        onComplete: (value) => result = value,
      );
      await tester.tap(find.byKey(const Key('memory-ready')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('memory-card-lion-1')));
      await tester.tap(find.byKey(const Key('memory-card-lion-2')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(result?['matched_pairs'], [
        ['lion-1', 'lion-2'],
      ]);
      expect(result?['moves'], 1);
      expect(result?['elapsed_seconds'], greaterThanOrEqualTo(1));
    });

    testWidgets(
      'memory shuffles adjacent pairs, waits for ready, and announces results',
      (tester) async {
        Map<String, dynamic>? result;
        const pairForCard = {
          'lion-1': 'lion',
          'lion-2': 'lion',
          'dove-1': 'dove',
          'dove-2': 'dove',
        };
        await _pumpEngine(
          tester,
          type: GameType.memory,
          config: {
            'cards': [
              {
                'id': 'lion-1',
                'label': 'Lion',
                'asset_key': '🦁',
                'match_key': 'lion',
              },
              {
                'id': 'lion-2',
                'label': 'Lion',
                'asset_key': '🦁',
                'match_key': 'lion',
              },
              {
                'id': 'dove-1',
                'label': 'Dove',
                'asset_key': '🕊️',
                'match_key': 'dove',
              },
              {
                'id': 'dove-2',
                'label': 'Dove',
                'asset_key': '🕊️',
                'match_key': 'dove',
              },
            ],
          },
          onComplete: (value) => result = value,
        );

        final positionsBefore = <String, Offset>{
          for (final id in pairForCard.keys)
            id: tester.getCenter(find.byKey(Key('memory-card-$id'))),
        };
        final visualOrder = positionsBefore.entries.toList()
          ..sort((left, right) {
            final row = left.value.dy.compareTo(right.value.dy);
            return row == 0 ? left.value.dx.compareTo(right.value.dx) : row;
          });
        for (var index = 1; index < visualOrder.length; index++) {
          expect(
            pairForCard[visualOrder[index].key],
            isNot(pairForCard[visualOrder[index - 1].key]),
          );
        }

        final previewCard = tester
            .getSemantics(find.byKey(const Key('memory-card-lion-1')))
            .getSemanticsData();
        expect(previewCard.value, contains('face up'));
        expect(previewCard.flagsCollection.isEnabled, Tristate.isFalse);

        await tester.tap(find.byKey(const Key('memory-ready')));
        await tester.pump();
        final orderAfterHiding = pairForCard.keys.toList()
          ..sort((left, right) {
            final leftPosition = tester.getCenter(
              find.byKey(Key('memory-card-$left')),
            );
            final rightPosition = tester.getCenter(
              find.byKey(Key('memory-card-$right')),
            );
            final row = leftPosition.dy.compareTo(rightPosition.dy);
            return row == 0 ? leftPosition.dx.compareTo(rightPosition.dx) : row;
          });
        expect(orderAfterHiding, visualOrder.map((entry) => entry.key));
        for (var index = 0; index < orderAfterHiding.length; index++) {
          final semantics = tester
              .getSemantics(
                find.byKey(Key('memory-card-${orderAfterHiding[index]}')),
              )
              .getSemanticsData();
          expect(semantics.label, 'Card ${index + 1} of 4');
        }
        final hiddenCard = tester
            .getSemantics(find.byKey(const Key('memory-card-lion-1')))
            .getSemanticsData();
        expect(hiddenCard.value, 'Hidden');
        expect(hiddenCard.flagsCollection.isEnabled, Tristate.isTrue);

        await tester.tap(find.byKey(const Key('memory-card-lion-1')));
        await tester.tap(find.byKey(const Key('memory-card-dove-1')));
        await tester.pump();
        final missStatus = tester
            .getSemantics(find.byKey(const Key('memory-live-status')))
            .getSemanticsData();
        expect(missStatus.label, contains('Not a match'));
        expect(missStatus.flagsCollection.isLiveRegion, isTrue);
        expect(
          tester
              .getSemantics(find.byKey(const Key('memory-card-lion-2')))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );

        await tester.pump(const Duration(milliseconds: 750));
        await tester.tap(find.byKey(const Key('memory-card-lion-1')));
        await tester.tap(find.byKey(const Key('memory-card-lion-2')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('memory-card-dove-1')));
        await tester.tap(find.byKey(const Key('memory-card-dove-2')));
        await tester.pump(const Duration(milliseconds: 400));

        expect(result?['moves'], 3);
        final submittedCards = (result?['matched_pairs'] as List<dynamic>)
            .expand((pair) => pair as List<dynamic>)
            .toSet();
        expect(submittedCards, pairForCard.keys.toSet());
      },
    );

    for (final type in [GameType.maze, GameType.path]) {
      testWidgets('${type.name} reports an adjacent grid path', (tester) async {
        Map<String, dynamic>? result;
        await _pumpEngine(
          tester,
          type: type,
          config: {
            'grid': {
              'rows': 2,
              'columns': 2,
              'start': [0, 0],
              'end': [0, 1],
              'walls': <Object>[],
              'decorations': <Object>[],
            },
          },
          onComplete: (value) => result = value,
        );

        await tester.tap(find.byTooltip('Move right'));
        expect(result?['path'], [
          [0, 0],
          [0, 1],
        ]);
      });
    }

    testWidgets('journey exposes coordinates and disables blocked moves', (
      tester,
    ) async {
      await _pumpEngine(
        tester,
        type: GameType.maze,
        config: {
          'grid': {
            'rows': 3,
            'columns': 3,
            'start': [0, 0],
            'end': [2, 2],
            'walls': [
              [0, 1],
            ],
            'decorations': <Object>[],
          },
        },
        onComplete: (_) {},
      );

      final status = tester
          .getSemantics(find.byKey(const Key('journey-live-status')))
          .getSemanticsData();
      expect(status.label, contains('Current row 1, column 1'));
      expect(status.label, contains('Goal row 3, column 3'));
      expect(status.label, contains('Blocked directions: up, left, right'));
      expect(status.flagsCollection.isLiveRegion, isTrue);
      expect(
        find.bySemanticsLabel('Row 1, column 1, current position'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.keyboard_arrow_up_rounded),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.keyboard_arrow_right_rounded),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.keyboard_arrow_down_rounded),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('journey collapses backtracking and caps the submitted path', (
      tester,
    ) async {
      Map<String, dynamic>? result;
      await _pumpEngine(
        tester,
        type: GameType.path,
        config: {
          'grid': {
            'rows': 3,
            'columns': 3,
            'start': [0, 0],
            'end': [2, 2],
            'walls': <Object>[],
            'decorations': <Object>[],
          },
        },
        onComplete: (value) => result = value,
      );

      Future<void> move(String direction) async {
        await tester.tap(find.byTooltip('Move $direction'));
        await tester.pump();
      }

      for (var cycle = 0; cycle < 8; cycle++) {
        await move('right');
        await move('down');
        await move('left');
        await move('up');
      }
      await move('right');
      await move('down');
      await move('left');

      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.keyboard_arrow_right_rounded),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.keyboard_arrow_down_rounded),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );

      await move('right');
      await move('up');
      await move('left');
      await move('down');
      await move('down');
      await move('right');
      await move('right');

      final path = result?['path'] as List<dynamic>;
      expect(path, hasLength(35));
      expect(path.length, lessThanOrEqualTo(3 * 3 * 4));
      for (var index = 1; index < path.length; index++) {
        final previous = path[index - 1] as List<dynamic>;
        final current = path[index] as List<dynamic>;
        final distance =
            ((current[0] as int) - (previous[0] as int)).abs() +
            ((current[1] as int) - (previous[1] as int)).abs();
        expect(distance, 1);
      }
    });

    testWidgets('aim records the child\'s canvas shot', (tester) async {
      Map<String, dynamic>? result;
      await _pumpEngine(
        tester,
        type: GameType.aim,
        config: {
          'canvas': {'width': 100, 'height': 100},
          'target': {'x': 50, 'y': 50, 'radius': 20},
          'max_shots': 3,
          'obstacles': <Object>[],
        },
        onComplete: (value) => result = value,
      );

      await tester.tapAt(tester.getCenter(find.byKey(const Key('aim-board'))));
      await tester.pump(const Duration(milliseconds: 700));

      final shots = result?['shots'] as List<dynamic>?;
      expect(shots, hasLength(1));
      expect((shots!.single as Map<String, dynamic>)['x'], closeTo(50, 1));
      expect((shots.single as Map<String, dynamic>)['y'], closeTo(50, 1));
    });

    testWidgets('aim supports focus activation and announces its result', (
      tester,
    ) async {
      Map<String, dynamic>? result;
      await _pumpEngine(
        tester,
        type: GameType.aim,
        config: {
          'canvas': {'width': 100, 'height': 100},
          'target': {'x': 70, 'y': 30, 'radius': 10},
          'max_shots': 3,
          'obstacles': <Object>[],
        },
        onComplete: (value) => result = value,
      );

      expect(find.byKey(const Key('aim-target-action')), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Aim board. Activate to shoot the glowing target.',
        ),
        findsOneWidget,
      );
      tester
          .widget<FocusableActionDetector>(
            find.byKey(const Key('aim-focus-target')),
          )
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 700));

      expect(result?['shots'], [
        {'x': 70, 'y': 30},
      ]);
      final status = tester
          .getSemantics(find.byKey(const Key('aim-live-status')))
          .getSemanticsData();
      expect(status.label, contains('Bullseye'));
      expect(status.flagsCollection.isLiveRegion, isTrue);
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
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: GameLevelEngine(
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
          ),
        ),
      ),
    ),
  );
  await tester.pump();
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

Future<AuthRepository> _activeAuth() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(
    const AuthSession(
      parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
      accessToken: 'access-token',
      profiles: [_ada],
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
    this.submitFailuresRemaining = 0,
    this.submitFailureStatusCode,
  });

  final List<MiniGame> games;
  int listFailuresRemaining;
  int submitFailuresRemaining;
  final int? submitFailureStatusCode;
  int detailFetches = 0;
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
    if (listFailuresRemaining > 0) {
      listFailuresRemaining -= 1;
      throw const AppException('The game room is taking a nap.');
    }
    return games;
  }

  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) async {
    detailFetches += 1;
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
        completed: true,
        correct: true,
        score: 10,
        maxScore: 10,
        starsAwarded: 3,
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
        idempotentReplay: false,
      );
    } finally {
      _activeSubmissions -= 1;
    }
  }
}

int mathMax(int left, int right) => left > right ? left : right;
