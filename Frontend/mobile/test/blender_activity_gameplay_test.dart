import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/ark_traffic_engine.dart';
import 'package:mobile/features/games/presentation/creation_world_engine.dart';
import 'package:mobile/features/games/presentation/game_level_completion.dart';
import 'package:mobile/features/games/presentation/game_play_screen.dart';
import 'package:mobile/features/games/presentation/wise_builders_engine.dart';
import 'package:mobile/features/milestones/data/level_milestone_store.dart';

// These exercise the real fullscreen parent and production asset loaders.
// Detailed drawing/building/replay rules are covered by the engine tests.
void main() {
  for (final activity in _Activity.values) {
    group('${activity.label} GamePlayScreen', () {
      testWidgets('all three rounds own the viewport and exit preserves state', (
        tester,
      ) async {
        _portraitSurface(tester);
        final repository = _ControlledRepository();
        for (final number in [1, 2, 3]) {
          await _pumpGame(tester, activity, repository, number: number);
          final engine = _engineFinder(activity);
          expect(tester.getRect(engine), const Rect.fromLTWH(0, 0, 390, 844));
          expect(
            tester.getRect(
              find.byKey(Key('${activity.mode}-fullscreen-level')),
            ),
            const Rect.fromLTWH(0, 0, 390, 844),
          );
          expect(_engineLevel(tester.widget(engine)).number, number);
          expect(find.byType(AppBar), findsNothing);
          expect(find.byKey(const Key('start-level-button')), findsNothing);
          expect(find.byKey(const Key('game-level-progress')), findsNothing);
          expect(find.byKey(const Key('game-exit')), findsNothing);
          expect(_paused(tester.widget(engine)), isFalse);
          final originalState = tester.state(engine);

          // Tap the activity's actual exit control, through the parent callback.
          await tester.tap(activity.exitControl);
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byKey(const Key('game-exit-dialog')), findsOneWidget);
          expect(find.text('Leave this level?'), findsOneWidget);
          expect(_paused(tester.widget(engine)), isTrue);
          await tester.pump(const Duration(seconds: 1));
          expect(tester.state(engine), same(originalState));

          await tester.tap(find.byKey(const Key('game-exit-keep-playing')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('game-exit-dialog')), findsNothing);
          expect(_paused(tester.widget(engine)), isFalse);
          expect(tester.state(engine), same(originalState));
          expect(repository.requests, isEmpty);
          expect(tester.takeException(), isNull);
          await _unmount(tester);
        }
      });

      testWidgets('background and covered routes pause the same run', (
        tester,
      ) async {
        _portraitSurface(tester);
        final navigator = GlobalKey<NavigatorState>();
        await _pumpGame(
          tester,
          activity,
          _ControlledRepository(),
          navigator: navigator,
        );
        final engine = _engineFinder(activity, skipOffstage: false);
        final originalState = tester.state(engine);
        for (final lifecycle in [
          AppLifecycleState.inactive,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(lifecycle);
          await tester.pump();
          expect(_paused(tester.widget(engine)), isTrue);
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(_paused(tester.widget(engine)), isFalse);
        expect(tester.state(engine), same(originalState));

        final covered = navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('Covered activity'))),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Covered activity'), findsOneWidget);
        expect(_paused(tester.widget(engine)), isTrue);
        await tester.pump(const Duration(seconds: 1));
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await covered;
        expect(_paused(tester.widget(engine)), isFalse);
        expect(tester.state(engine), same(originalState));
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });

      testWidgets('pending and failed saves pause; retry preserves the replay', (
        tester,
      ) async {
        _portraitSurface(tester);
        final repository = _ControlledRepository();
        await _pumpGame(tester, activity, repository);
        final engine = _engineFinder(activity);
        final originalState = tester.state(engine);
        final outcome = activity.recordedResult();
        final complete = _completionCallback(tester.widget(engine));
        complete(outcome);
        // Even duplicate callbacks before a frame cannot launch another save.
        complete(outcome);
        await tester.pump();
        expect(repository.requests, hasLength(1));
        final first = repository.requests.single;
        expect(first.slug, activity.slug);
        expect(first.profileId, _ada.id);
        expect(first.levelNumber, 1);
        expect(first.operationId, matches(_uuidPattern));
        expect(first.result, outcome);
        expect(find.text('Saving this round…'), findsOneWidget);
        expect(_paused(tester.widget(engine)), isTrue);
        await tester.pump(const Duration(seconds: 1));
        expect(_paused(tester.widget(engine)), isTrue);
        expect(tester.state(engine), same(originalState));
        // A late successful receipt must still refresh the caller's progress.
        // The parent therefore keeps this route open until its save resolves.
        _exitCallback(tester.widget(engine))();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('game-exit-dialog')), findsNothing);
        expect(find.byType(GamePlayScreen), findsOneWidget);
        expect(tester.state(engine), same(originalState));
        expect(_paused(tester.widget(engine)), isTrue);

        first.response.completeError(
          const AppException('Save unavailable.', statusCode: 503),
        );
        await tester.pump();
        expect(find.text('Saving this round…'), findsNothing);
        expect(find.byKey(const Key('retry-game-save')), findsOneWidget);
        expect(find.byKey(const Key('redo-game-level')), findsOneWidget);
        expect(_paused(tester.widget(engine)), isTrue);
        expect(tester.state(engine), same(originalState));

        // Foregrounding or dismissing an exit prompt cannot release a save pause.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(_paused(tester.widget(engine)), isTrue);
        _exitCallback(tester.widget(engine))();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('game-exit-dialog')), findsOneWidget);
        await tester.tap(find.byKey(const Key('game-exit-keep-playing')));
        await tester.pumpAndSettle();
        expect(_paused(tester.widget(engine)), isTrue);

        await tester.tap(find.byKey(const Key('retry-game-save')));
        await tester.pump();
        expect(repository.requests, hasLength(2));
        final retry = repository.requests.last;
        expect(retry.operationId, first.operationId);
        expect(retry.slug, first.slug);
        expect(retry.profileId, first.profileId);
        expect(retry.levelNumber, first.levelNumber);
        expect(retry.result, outcome);
        expect(retry.result, same(first.result));
        expect(_paused(tester.widget(engine)), isTrue);
        expect(find.text('Saving this round…'), findsOneWidget);
        expect(repository.maxConcurrentRequests, 1);

        final receipt = retry.savedReceipt();
        retry.response.complete(receipt);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('game-completion')), findsOneWidget);
        expect(find.byType(activity.engineType), findsNothing);
        final celebration = tester.widget<GameLevelCompletion>(
          find.byType(GameLevelCompletion),
        );
        expect(celebration.submission, same(receipt));
        expect(celebration.submission.score, 92);
        expect(celebration.submission.starsAwarded, 3);
        expect(celebration.submission.idempotentReplay, isTrue);
        expect(repository.requests, hasLength(2));
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });
    });
  }
}

enum _Activity {
  ark,
  creation,
  builders;

  String get label => switch (this) {
    ark => 'Ark traffic',
    creation => 'Creation living world',
    builders => 'Wise builders',
  };
  String get slug => switch (this) {
    ark => 'ark-animal-match',
    creation => 'creation-order',
    builders => 'wise-and-foolish-builders',
  };
  String get mode => switch (this) {
    ark => 'ark_traffic',
    creation => 'living_world',
    builders => 'wise_builders',
  };
  Type get engineType => switch (this) {
    ark => ArkTrafficEngine,
    creation => CreationWorldEngine,
    builders => WiseBuildersEngine,
  };
  Finder get exitControl => switch (this) {
    ark => find.text('Back to games'),
    creation => find.byTooltip('Leave this world'),
    builders => find.byTooltip('Leave building'),
  };
  String get configFile => switch (this) {
    ark => '../../Motion/ark-traffic-blender-v1/traffic-levels.json',
    creation => 'test/fixtures/creation_world_levels.json',
    builders => '../../Motion/wise-builders-blender-v1/builders-levels.json',
  };

  MiniGame game() {
    final configs = jsonDecode(File(configFile).readAsStringSync()) as Map;
    return MiniGame.fromJson({
      'id': slug,
      'slug': slug,
      'title': label,
      'game_type': this == ark ? 'matching' : 'ordering',
      'total_levels': 3,
      'levels': [
        for (final number in [1, 2, 3])
          {
            'id': '$slug-$number',
            'level_number': number,
            'title': '$label round $number',
            'instructions': 'Play and explore.',
            'max_score': 100,
            'config': configs['$number'],
          },
      ],
    });
  }

  Map<String, dynamic> recordedResult() {
    final path = switch (this) {
      ark =>
        '../../Motion/ark-traffic-blender-v1/review/mobile-replay-proof.json',
      creation => '../../Motion/creation-world-blender-v1/world-examples.json',
      builders =>
        '../../Motion/wise-builders-blender-v1/builders-examples.json',
    };
    final examples = jsonDecode(File(path).readAsStringSync()) as Map;
    final round = examples['1'] as Map;
    return Map<String, dynamic>.from(
      this == ark ? round['result'] as Map : round,
    );
  }
}

Finder _engineFinder(_Activity activity, {bool skipOffstage = true}) =>
    find.byType(activity.engineType, skipOffstage: skipOffstage);

bool _paused(Widget engine) => switch (engine) {
  ArkTrafficEngine() => engine.paused,
  CreationWorldEngine() => engine.paused,
  WiseBuildersEngine() => engine.paused,
  _ => throw StateError('Expected a Blender activity engine.'),
};

GameLevel _engineLevel(Widget engine) => switch (engine) {
  ArkTrafficEngine() => engine.level,
  CreationWorldEngine() => engine.level,
  WiseBuildersEngine() => engine.level,
  _ => throw StateError('Expected a Blender activity engine.'),
};

void Function(Map<String, dynamic>) _completionCallback(Widget engine) =>
    switch (engine) {
      ArkTrafficEngine() => engine.onComplete,
      CreationWorldEngine() => engine.onComplete,
      WiseBuildersEngine() => engine.onComplete,
      _ => throw StateError('Expected a Blender activity engine.'),
    };

VoidCallback _exitCallback(Widget engine) => switch (engine) {
  ArkTrafficEngine() => engine.onExit!,
  CreationWorldEngine() => engine.onExit!,
  WiseBuildersEngine() => engine.onExit!,
  _ => throw StateError('Expected a Blender activity engine.'),
};

void _portraitSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(tester.view.reset);
  addTearDown(
    () => tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    ),
  );
}

Future<void> _pumpGame(
  WidgetTester tester,
  _Activity activity,
  _ControlledRepository repository, {
  int number = 1,
  GlobalKey<NavigatorState>? navigator,
}) async {
  await _unmount(tester);
  await _loadTypography(tester);
  // Each widget test owns a new FakeAsync zone. Do not reuse the manifest's
  // cached Future from an earlier test's zone (Creation also uses this atlas).
  rootBundle.evict('assets/images/games/ark_traffic/manifest.json');
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: buildKingdomKidsTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: GamePlayScreen(
        game: activity.game(),
        profile: _ada,
        repository: repository,
        startingLevel: number,
        authRepository: AuthRepository(sessionStore: MemoryAuthSessionStore()),
        milestoneStore: MemoryLevelMilestoneStore(),
      ),
    ),
  );
  // Native image decoding needs real async work, rather than animation settling.
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (activity.exitControl.evaluate().isNotEmpty) return;
  }
  fail('${activity.label} round $number did not load its production artwork.');
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

bool _fontsLoaded = false;

Future<void> _loadTypography(WidgetTester tester) async {
  if (_fontsLoaded) return;
  await tester.runAsync(() async {
    // Ahem's square glyphs exaggerate ChoiceChip widths. Use the app's native
    // typeface where available and Flutter's bundled Roboto on other hosts.
    final nativeFont = File('/System/Library/Fonts/Avenir Next.ttc');
    final bundledFont = File.fromUri(
      File(
        Platform.resolvedExecutable,
      ).parent.uri.resolve('../../material_fonts/Roboto-Regular.ttf'),
    );
    final bytes = await (nativeFont.existsSync() ? nativeFont : bundledFont)
        .readAsBytes();
    for (final family in ['Avenir Next', 'Roboto']) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  _fontsLoaded = true;
}

const _ada = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Ada',
  avatarKey: 'dove',
);

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

final class _SaveRequest {
  _SaveRequest({
    required this.slug,
    required this.profileId,
    required this.levelNumber,
    required this.operationId,
    required this.result,
  });
  final String slug;
  final String profileId;
  final int levelNumber;
  final String operationId;
  final Map<String, dynamic> result;
  final response = Completer<GameSubmission>();

  GameSubmission savedReceipt() => GameSubmission(
    attemptId: 'saved-attempt',
    operationId: operationId,
    gameSlug: slug,
    profileId: profileId,
    levelNumber: levelNumber,
    completed: true,
    correct: true,
    score: 92,
    maxScore: 100,
    starsAwarded: 3,
    feedback: 'Your round is safely saved.',
    progress: GameProgress(
      profileId: profileId,
      highestCompletedLevel: levelNumber,
      currentLevel: levelNumber + 1,
      completedLevels: levelNumber,
      totalLevels: 3,
      bestScore: 92,
      starsEarned: 3,
      maxStars: 9,
      percent: levelNumber / 3,
    ),
    idempotentReplay: true,
  );
}

final class _ControlledRepository implements GameRepository {
  final requests = <_SaveRequest>[];
  int _active = 0;
  int maxConcurrentRequests = 0;

  @override
  Future<List<MiniGame>> fetchGames({required String profileId}) =>
      throw StateError('GamePlayScreen must use its supplied game.');

  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) =>
      throw StateError('GamePlayScreen must use its supplied game.');

  @override
  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
  }) async {
    final request = _SaveRequest(
      slug: slug,
      profileId: profileId,
      levelNumber: levelNumber,
      operationId: operationId,
      result: result,
    );
    requests.add(request);
    _active++;
    if (_active > maxConcurrentRequests) maxConcurrentRequests = _active;
    try {
      return await request.response.future;
    } finally {
      _active--;
    }
  }
}
