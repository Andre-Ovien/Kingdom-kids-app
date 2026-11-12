import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/game_cover_image.dart';
import 'package:mobile/features/games/presentation/game_detail_screen.dart';
import 'package:mobile/features/games/presentation/games_course_widgets.dart';
import 'package:mobile/features/games/presentation/games_screen.dart';
import 'package:mobile/features/games/presentation/games_week_carousel.dart';

final _catalogue = [
  _game('a'),
  _game('b', featured: true),
  _game('c'),
  _game('d'),
  _game('e'),
  _game('f', featured: true),
  _game('g'),
];
const _expected = ['week-b', 'week-f', 'week-a', 'week-c', 'week-d'];

void main() {
  test(
    'weekly pool keeps five real unique games with flagged entries first',
    () {
      final games = [..._catalogue, _catalogue[1]];
      final pool = buildGamesWeekPool(games);
      expect(pool.map((game) => game.slug), _expected);
      expect(pool.every(games.contains), isTrue);
      expect(buildGamesWeekPool([]), isEmpty);
      expect(buildGamesWeekPool([_catalogue[1], _catalogue[1]]), [
        _catalogue[1],
      ]);
    },
  );

  testWidgets(
    'seven-second pill clock drives the real midway cover and title glide',
    (tester) async {
      await _withHarness(tester, (h) async {
        final initialCover = tester.getRect(_paintedCover('week-b'));
        expect(_current(tester).slug, 'week-b');
        await _frames(tester, const Duration(milliseconds: 3500));
        expect(_progress(tester), closeTo(0.5, 0.01));
        h.change(() {});
        await tester.pump();
        expect(_progress(tester), closeTo(0.5, 0.01));
        await _frames(tester, const Duration(milliseconds: 3499));
        expect(_progress(tester), greaterThan(0.998));
        expect(_current(tester).slug, 'week-b');
        await _frames(tester, const Duration(milliseconds: 3));
        await _frames(tester, const Duration(milliseconds: 150));
        expect(_current(tester).slug, 'week-f');
        expect(
          find.byKey(const Key('games-week-previous-cover-week-b')),
          findsOneWidget,
        );
        final midwayCover = tester.getRect(_paintedCover('week-f'));
        final midwayTitle = tester.getTopLeft(_paintedTitle('week-f'));
        expect(
          (midwayCover.topLeft - initialCover.topLeft).distance,
          greaterThan(0.1),
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('game-week-play')))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const Key('game-week-play')));
        expect(h.opened, isEmpty);
        await _frames(tester, const Duration(milliseconds: 300));
        expect(tester.getRect(_paintedCover('week-f')), initialCover);
        expect(
          (tester.getTopLeft(_paintedTitle('week-f')) - midwayTitle).distance,
          greaterThan(0.1),
        );
        await tester.tap(find.byKey(const Key('game-week-play')));
        expect(h.opened.single.slug, 'week-f');

        final paint = tester.widget<CustomPaint>(
          find.byKey(const Key('games-week-countdown')),
        );
        final painter =
            (paint.foregroundPainter ?? paint.painter)! as GamesWeekPillPainter;
        final size = tester.getSize(
          find.byKey(const Key('games-week-countdown')),
        );
        final outline = painter.outlineFor(size);
        final bounds = outline.getBounds();
        expect(bounds.width, greaterThan(size.width - 6));
        expect(bounds.height, greaterThan(size.height - 6));
        expect(bounds.width, greaterThan(bounds.height * 2));
        final contour = outline.computeMetrics().single;
        expect(contour.isClosed, isTrue);
        final fullPillPerimeter =
            2 * (bounds.width - bounds.height) +
            3.141592653589793 * bounds.height;
        expect(contour.length, closeTo(fullPillPerimeter, 3));
      });
    },
  );

  testWidgets(
    'five visible games have correct Play targets before forward wrap',
    (tester) async {
      await _withHarness(tester, (h) async {
        final seen = <String>[];
        for (var step = 0; step <= 5; step++) {
          final current = _current(tester);
          seen.add(current.slug);
          await tester.tap(find.byKey(const Key('game-week-play')));
          expect(identical(h.opened.last, current), isTrue);
          expect(h.opened.last.slug, _expected[step % 5]);
          if (step < 5) {
            await _frames(tester, const Duration(milliseconds: 7500));
          }
        }
        expect(seen, [..._expected, _expected.first]);
      });
    },
  );

  testWidgets(
    'clock pauses under pointer, covered route, background and hidden scroll',
    (tester) async {
      await _withHarness(tester, (h) async {
        await _frames(tester, const Duration(seconds: 2));
        final held = _progress(tester);
        final pointer = await tester.startGesture(
          tester.getCenter(_cover('week-b')),
        );
        await _frames(tester, const Duration(seconds: 9));
        expect(_progress(tester), held);
        expect(_current(tester).slug, 'week-b');
        await pointer.cancel();
        await tester.pump();
        h.change(() => h.active = false);
        await _frames(tester, const Duration(seconds: 9));
        expect(_progress(tester), closeTo(held, 0.01));
        h.change(() => h.active = true);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await _frames(tester, const Duration(seconds: 9));
        expect(_progress(tester), closeTo(held, 0.01));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        h.navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Cover')),
          ),
        );
        await _frames(tester, const Duration(seconds: 9));
        expect(_progress(tester, offstage: true), closeTo(held, 0.01));
        h.navigator.currentState!.pop();
        await _frames(tester, const Duration(milliseconds: 400));
        h.scroll.jumpTo(650);
        await _frames(tester, const Duration(milliseconds: 100));
        final hidden = _progress(tester);
        await _frames(tester, const Duration(seconds: 9));
        expect(_progress(tester), hidden);
        expect(_current(tester).slug, 'week-b');
        h.scroll.jumpTo(0);
        await _frames(tester, const Duration(seconds: 1));
        expect(_progress(tester), greaterThan(hidden));
      });
    },
  );

  for (final accessible in [false, true]) {
    testWidgets(
      'reduced motion/accessibility keeps a manual Play target $accessible',
      (tester) async {
        await _withHarness(tester, (h) async {
          h.change(() {
            h.reduceMotion = !accessible;
            h.accessible = accessible;
          });
          await tester.pump();
          final held = _progress(tester);
          await _frames(tester, const Duration(seconds: 21));
          expect(_progress(tester), held);
          expect(_current(tester).slug, 'week-b');
          await tester.tap(find.byKey(const Key('game-week-play')));
          expect(h.opened.single.slug, 'week-b');
          final semantics = tester.ensureSemantics();
          try {
            final node = tester.getSemantics(
              find.byKey(const Key('games-week-carousel')),
            );
            expect(
              node.getSemanticsData().hasAction(ui.SemanticsAction.increase),
              isTrue,
            );
            node.owner!.performAction(node.id, ui.SemanticsAction.increase);
            await tester.pump();
            expect(_current(tester).slug, 'week-f');
            await tester.tap(find.byKey(const Key('game-week-play')));
            expect(h.opened.last.slug, 'week-f');
          } finally {
            semantics.dispose();
          }
        });
      },
    );
  }

  testWidgets('zero and one unique game stay honest and static', (
    tester,
  ) async {
    for (final games in <List<MiniGame>>[
      [],
      [_catalogue[1], _catalogue[1]],
    ]) {
      await _withHarness(tester, (h) async {
        final held = _progress(tester);
        await _frames(tester, const Duration(seconds: 21));
        expect(_progress(tester), held);
        expect(tester.binding.transientCallbackCount, 0);
        final play = tester.widget<FilledButton>(
          find.byKey(const Key('game-week-play')),
        );
        if (games.isEmpty) {
          expect(find.byKey(const Key('games-featured-cover')), findsNothing);
          expect(play.onPressed, isNull);
          expect(h.opened, isEmpty);
        } else {
          expect(_current(tester).slug, 'week-b');
          await tester.tap(find.byKey(const Key('game-week-play')));
          expect(h.opened.single.slug, 'week-b');
        }
      }, games: games);
    }
  });

  testWidgets(
    'pool and child changes retire a pending old transition and reset scope',
    (tester) async {
      await _withHarness(tester, (h) async {
        await _frames(tester, const Duration(milliseconds: 7100));
        expect(_current(tester).slug, 'week-f');
        final replacement = [_game('new-a'), _game('new-b')];
        h.change(() {
          h.games = replacement;
          h.scope = 'parent:child-b';
        });
        await _frames(tester, const Duration(milliseconds: 600));
        expect(_current(tester).slug, 'week-new-a');
        expect(_progress(tester), lessThan(0.12));
        await tester.tap(find.byKey(const Key('game-week-play')));
        expect(identical(h.opened.last, replacement.first), isTrue);
        await _frames(tester, const Duration(seconds: 3));
        expect(_progress(tester), greaterThan(0.4));
        h.change(() => h.scope = 'parent:child-c');
        await tester.pump();
        expect(_current(tester).slug, 'week-new-a');
        expect(_progress(tester), closeTo(0, 0.01));
      });
    },
  );

  testWidgets('disposal retires the running clock and scroll observer', (
    tester,
  ) async {
    await _withHarness(tester, (h) async {
      await _frames(tester, const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester, const Duration(seconds: 21));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'real Games refresh gates stale Play and passes the new child scope',
    (tester) async {
      _phone(tester);
      final auth = _RotationAuth();
      final repository = _RotationRepository(_catalogue);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [appRouteObserver],
          home: GamesScreen(repository: repository, authRepository: auth),
        ),
      );
      try {
        await tester.pump();
        await tester.pump();
        await _frames(tester, const Duration(milliseconds: 7600));
        expect(_current(tester).slug, 'week-f');
        auth.profile = _childB;
        final barrier = Completer<List<MiniGame>>();
        repository.pending = barrier.future;
        unawaited(
          tester
              .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
              .show(),
        );
        await _frames(tester, const Duration(milliseconds: 500));
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('game-week-play')))
              .onPressed,
          isNull,
        );
        barrier.complete(_catalogue);
        repository.pending = null;
        await _frames(tester, const Duration(milliseconds: 600));
        expect(_current(tester).slug, 'week-b');
        expect(_progress(tester), lessThan(0.15));
        await tester.tap(find.byKey(const Key('game-week-play')));
        await tester.pumpAndSettle();
        expect(find.byType(GameDetailScreen), findsOneWidget);
        expect(repository.details.last, ('week-b', 'child-b'));
        expect(repository.profiles, ['child-a', 'child-b']);
        expect(repository.submissions, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}

Finder _cover(String slug) => find.byKey(Key('games-week-current-cover-$slug'));
Finder _title(String slug) => find.byKey(Key('games-week-current-title-$slug'));
Finder _paintedCover(String slug) => find
    .descendant(of: _cover(slug), matching: find.byType(GameCoverImage))
    .first;
Finder _paintedTitle(String slug) =>
    find.descendant(of: _title(slug), matching: find.byType(Text)).first;
MiniGame _current(WidgetTester tester) => tester
    .widget<GameCoverImage>(
      find.byKey(const Key('games-featured-cover'), skipOffstage: false),
    )
    .game;
double _progress(WidgetTester tester, {bool offstage = false}) {
  final finder = find.byKey(
    const Key('games-week-countdown'),
    skipOffstage: !offstage,
  );
  if (finder.evaluate().isEmpty) {
    return 0; // Static0/1/ReduceMotion states omit it.
  }
  final paint = tester.widget<CustomPaint>(finder);
  return ((paint.foregroundPainter ?? paint.painter)! as GamesWeekPillPainter)
      .progress;
}

Future<void> _frames(WidgetTester tester, Duration duration) async {
  await tester.pump();
  var remaining = duration;
  const frame = Duration(milliseconds: 100);
  while (remaining > Duration.zero) {
    final step = remaining < frame ? remaining : frame;
    await tester.pump(step);
    remaining -= step;
  }
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(393, 852);
  addTearDown(tester.view.reset);
}

Future<void> _withHarness(
  WidgetTester tester,
  Future<void> Function(_Harness) body, {
  List<MiniGame>? games,
}) async {
  _phone(tester);
  final h = _Harness(games ?? [..._catalogue, _catalogue[1]]);
  await tester.pumpWidget(h.app());
  await tester.pump();
  try {
    await body(h);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    h.scroll.dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

class _Harness {
  _Harness(this.games);
  List<MiniGame> games;
  String scope = 'parent:child-a';
  bool active = true, reduceMotion = false, accessible = false;
  final scroll = ScrollController();
  final navigator = GlobalKey<NavigatorState>();
  final opened = <MiniGame>[];
  late StateSetter change;

  Widget app() => MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [appRouteObserver],
    home: StatefulBuilder(
      builder: (context, setState) {
        change = setState;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            accessibleNavigation: accessible,
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  GamesWeekCarousel(
                    games: games,
                    scopeId: scope,
                    scrollController: scroll,
                    loading: false,
                    isActive: active,
                    onOpen: opened.add,
                  ),
                  const SizedBox(height: 1800),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

MiniGame _game(String letter, {bool featured = false}) => MiniGame.fromJson({
  'id': 'week-$letter',
  'slug': 'week-$letter',
  'title': 'Story $letter',
  'game_type': 'quiz',
  'total_levels': 1,
  'is_featured': featured,
  'cover_asset_key': 'assets/images/esther.jpeg',
});
const _childA = KidProfile(
  id: 'child-a',
  parentId: 'parent',
  displayName: 'Ada',
  avatarKey: 'dove',
);
const _childB = KidProfile(
  id: 'child-b',
  parentId: 'parent',
  displayName: 'Nia',
  avatarKey: 'nia',
);

class _RotationAuth extends AuthRepository {
  _RotationAuth() : super(sessionStore: MemoryAuthSessionStore());
  KidProfile profile = _childA;
  @override
  Future<KidProfile?> currentKid() async => profile;
}

class _RotationRepository implements GameRepository {
  _RotationRepository(this.games);
  final List<MiniGame> games;
  Future<List<MiniGame>>? pending;
  final profiles = <String>[];
  final details = <(String, String)>[];
  int submissions = 0;
  @override
  Future<List<MiniGame>> fetchGames({required String profileId}) async {
    profiles.add(profileId);
    return pending ?? games;
  }

  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) async {
    details.add((slug, profileId));
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
    submissions++;
    throw StateError('Rotation must never submit game progress');
  }
}
