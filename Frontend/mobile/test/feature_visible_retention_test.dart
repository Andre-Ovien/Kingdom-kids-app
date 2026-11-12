import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/core/network/feature_view_state_cache.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/game_detail_screen.dart';
import 'package:mobile/features/games/presentation/games_screen.dart';
import 'package:mobile/features/home/presentation/home_screen.dart';
import 'package:mobile/features/milestones/data/level_milestone_store.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/domain/parent_settings.dart';
import 'package:mobile/features/profile/data/profile_repository.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';
import 'package:mobile/features/profile/presentation/profile_screen.dart';
import 'package:mobile/features/stories/data/story_reading_bookmark_store.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/stories_screen.dart';
import 'package:mobile/features/stories/presentation/story_detail_screen.dart';
import 'package:mobile/features/streak/data/streak_reminder_service.dart';
import 'package:mobile/features/streak/data/streak_repository.dart';
import 'package:mobile/features/streak/domain/streak_claim_receipt.dart';
import 'package:mobile/shared/widgets/liquid_navigation_controller.dart';
import 'package:mobile/shared/widgets/persistent_liquid_navigation_host.dart';
import 'package:mobile/shared/widgets/scoped_feature_page.dart';

const _kid = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Ada',
  avatarKey: 'dove',
);
const _sibling = KidProfile(
  id: 'kid-2',
  parentId: 'parent-1',
  displayName: 'Nia',
  avatarKey: 'lion',
);
const _session = AuthSession(
  parent: ParentAccount(id: 'parent-1', email: 'parent@example.test'),
  accessToken: 'test-access',
  refreshToken: 'test-refresh',
  profiles: [_kid, _sibling],
);

StoryDetail _story({String title = 'Retained story', String body = ''}) =>
    StoryDetail.fromJson({
      'id': 'story-1',
      'slug': 'ruth-and-naomi',
      'title': title,
      'category': 'Faith',
      'body': body,
      'summary': 'A story about kindness.',
      'cover_asset_key': 'assets/images/stories/ruth-and-naomi-v2.webp',
    });

MiniGame _game({String title = 'Retained quest', bool detail = false}) =>
    MiniGame.fromJson({
      'id': 'game-1',
      'slug': 'esther-quiz',
      'title': title,
      'game_type': 'quiz',
      'total_levels': 1,
      'progress': {'profile_id': _kid.id},
      if (detail)
        'levels': [
          {
            'id': 'level-1',
            'level_number': 1,
            'title': 'Retained level',
            'max_score': 100,
            'config': {
              'questions': [
                {
                  'id': 'question',
                  'prompt': 'Kind?',
                  'choices': ['Yes', 'No'],
                },
              ],
            },
          },
        ],
    });

ProfileProgressSummary _summary({String title = 'Retained rank'}) =>
    ProfileProgressSummary.fromJson({
      'profile': _kid.toJson(),
      'level': {'number': 2, 'title': title, 'xp': 300, 'next_level_xp': 600},
    });

void main() {
  setUp(() {
    featureReadCache.invalidate();
    featureViewStateCache.clearIdentity();
  });

  testWidgets(
    'all four tabs paint previous items on the first return frame while refresh is pending',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = await _Harness.create();
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      for (final route in [
        AppRoutes.games,
        AppRoutes.stories,
        AppRoutes.profile,
      ]) {
        await _select(tester, harness, route);
      }
      // Force genuine pending reads rather than relying on an immediate cache hit.
      // Display state remains separate from network TTL and progress invalidation.
      featureReadCache.invalidate();
      harness.stories.pendingList = Completer<List<StoryDetail>>();
      harness.games.pendingList = Completer<List<MiniGame>>();
      harness.profile.pending = Completer<ProfileProgressSummary>();
      for (final route in [
        AppRoutes.home,
        AppRoutes.games,
        AppRoutes.stories,
        AppRoutes.profile,
      ]) {
        expect(harness.controller.select(route), isTrue);
        await tester.pump();
        await tester.pump();
        _expectVisible(route);
        await tester.pump(const Duration(milliseconds: 400));
        _expectVisible(route);
      }
      expect(harness.stories.listCalls, greaterThan(2));
      expect(harness.games.listCalls, greaterThan(1));
      expect(harness.profile.calls, greaterThan(1));
      harness.stories.pendingList!.complete([_story(title: 'Fresh story')]);
      harness.games.pendingList!.complete([_game(title: 'Fresh quest')]);
      harness.profile.pending!.complete(_summary(title: 'Fresh rank'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Fresh rank'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a detail return keeps Games cards and hero visible while saved progress refreshes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = await _Harness.create();
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      await _select(tester, harness, AppRoutes.games);
      await tester.tap(find.byKey(const Key('game-week-play')));
      await tester.pumpAndSettle();
      expect(find.byType(GameDetailScreen), findsOneWidget);
      harness.games.pendingList = Completer<List<MiniGame>>();
      harness.navigator.currentState!.pop(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _expectVisible(AppRoutes.games);
      expect(harness.games.listCalls, 2);
      harness.games.pendingList!.complete([_game(title: 'Updated quest')]);
      await tester.pumpAndSettle();
      expect(find.text('Updated quest'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reopened story details keep the loaded body visible during revalidation',
    (tester) async {
      final harness = await _Harness.create();
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      await _select(tester, harness, AppRoutes.stories);
      unawaited(
        harness.navigator.currentState!.pushNamed(AppRoutes.storyDetail),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Retained full story body'), findsWidgets);
      harness.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      harness.stories.pendingDetail = Completer<StoryDetail>();
      unawaited(
        harness.navigator.currentState!.pushNamed(AppRoutes.storyDetail),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Retained full story body'), findsWidgets);
      harness.stories.pendingDetail!.complete(
        _story(body: 'Fresh full story body.'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Fresh full story body'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'child identity invalidation clears displayed snapshots before pending reads finish',
    (tester) async {
      final harness = await _Harness.create();
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      await _select(tester, harness, AppRoutes.games);
      _expectVisible(AppRoutes.games);
      harness.games.pendingList = Completer<List<MiniGame>>();
      await harness.auth.selectKid(_sibling);
      await tester.pump();
      await tester.pump();
      expect(find.text('Retained quest'), findsNothing);
      expect(
        featureViewStateCache
            .knownPreparation(AppRoutes.games)
            ?.memory['games'],
        isNull,
      );
      harness.games.pendingList!.complete([_game(title: 'New child quest')]);
      await tester.pumpAndSettle();
      expect(find.text('New child quest'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an older pending tab preparation cannot unlock a newer tab request',
    (tester) async {
      final harness = await _Harness.create();
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      final old = Completer<FeaturePagePreparation>();
      final latest = Completer<FeaturePagePreparation>();
      harness.tabBarriers[AppRoutes.games] = old;
      harness.tabBarriers[AppRoutes.stories] = latest;
      expect(harness.controller.select(AppRoutes.games), isTrue);
      await tester.pump();
      expect(find.byType(HomeScreen), findsOneWidget);
      unawaited(
        harness.navigator.currentState!.push<void>(
          MaterialPageRoute(
            settings: const RouteSettings(name: '/probe'),
            builder: (_) => const Scaffold(body: Text('Detail')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      harness.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(harness.controller.select(AppRoutes.stories), isTrue);
      await tester.pump();
      old.complete(
        await ScopedFeaturePage.prepare(
          AppRoutes.games,
          authRepository: harness.auth,
        ),
      );
      await tester.pump();
      expect(harness.controller.select(AppRoutes.profile), isFalse);
      latest.complete(
        await ScopedFeaturePage.prepare(
          AppRoutes.stories,
          authRepository: harness.auth,
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.selectedRoute, AppRoutes.stories);
      expect(find.byType(StoriesScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a display seed restores its deep scroll before refresh finishes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = await _Harness.create();
      addTearDown(harness.controller.dispose);
      final memory = featureViewStateCache.knownPreparation(AppRoutes.games)!;
      memory.memory.addAll({
        'games': List.generate(
          12,
          (i) => MiniGame.fromJson({
            'id': 'game-$i',
            'slug': 'quest-$i',
            'title': 'Retained quest $i',
            'game_type': ['quiz', 'puzzle', 'matching', 'aim'][i % 4],
            'progress': {'profile_id': _kid.id},
          }),
        ),
        'profile': _kid,
        'scroll': 1400.0,
      });
      harness.games.pendingList = Completer<List<MiniGame>>();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: ScopedFeaturePage(
            route: AppRoutes.games,
            preparation: memory,
            child: GamesScreen(
              repository: harness.games,
              authRepository: harness.auth,
            ),
          ),
        ),
      );
      await tester.pump();
      final scroll = tester
          .widget<CustomScrollView>(find.byKey(const Key('games-scroll')))
          .controller!;
      expect(scroll.offset, 1400);
      expect(harness.games.pendingList!.isCompleted, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      harness.games.pendingList!.complete([_game()]);
    },
  );
}

void _expectVisible(String route) {
  switch (route) {
    case AppRoutes.home:
      expect(find.text('Retained story'), findsWidgets);
      expect(find.byKey(const Key('home-stories-loading')), findsNothing);
    case AppRoutes.games:
      expect(find.text('Retained quest'), findsWidgets);
      expect(find.byKey(const Key('games-week-carousel')), findsOneWidget);
    case AppRoutes.stories:
      expect(find.text('Retained story'), findsWidgets);
    case AppRoutes.profile:
      expect(find.textContaining('Retained rank'), findsOneWidget);
      expect(find.byKey(const Key('profile-loading')), findsNothing);
  }
}

Future<void> _select(
  WidgetTester tester,
  _Harness harness,
  String route,
) async {
  expect(harness.controller.select(route), isTrue);
  await tester.pumpAndSettle();
}

class _Harness {
  _Harness(this.auth) {
    controller = LiquidNavigationController(
      navigatorKey: navigator,
      onAcceptedSelection: () {},
      loadProfile: auth.currentKid,
      prepareTab: (route) async {
        final preparation = await ScopedFeaturePage.prepare(
          route,
          authRepository: auth,
        );
        return tabBarriers[route]?.future ?? preparation;
      },
    );
  }
  static Future<_Harness> create() async {
    final store = MemoryAuthSessionStore();
    await store.writeSession(_session);
    await store.writeSelectedKidId(_kid.id);
    final harness = _Harness(AuthRepository(sessionStore: store));
    await ScopedFeaturePage.prepare(
      AppRoutes.home,
      authRepository: harness.auth,
    );
    return harness;
  }

  final navigator = GlobalKey<NavigatorState>();
  final AuthRepository auth;
  late final LiquidNavigationController controller;
  final stories = _Stories();
  final games = _Games();
  final profile = _Profile();
  final bookmarks = MemoryStoryReadingBookmarkStore();
  final tabBarriers = <String, Completer<FeaturePagePreparation>>{};

  Widget app() => MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [
      appRouteObserver,
      LiquidNavigationObserver(controller),
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: true, accessibleNavigation: true),
      child: PersistentLiquidNavigationHost(
        controller: controller,
        child: child!,
      ),
    ),
    onGenerateInitialRoutes: (_) => [
      _route(const RouteSettings(name: AppRoutes.home)),
    ],
    onGenerateRoute: _route,
  );

  Route<dynamic> _route(RouteSettings settings) {
    final Widget destination = switch (settings.name) {
      AppRoutes.games => GamesScreen(repository: games, authRepository: auth),
      AppRoutes.stories => StoriesScreen(
        repository: stories,
        authRepository: auth,
      ),
      AppRoutes.profile => ProfileScreen(
        authRepository: auth,
        profileRepository: profile,
      ),
      AppRoutes.storyDetail => StoryDetailScreen(
        story: _story(),
        repository: stories,
        authRepository: auth,
        settingsRepository: _Settings(),
        bookmarkStore: bookmarks,
      ),
      _ => HomeScreen(
        authRepository: auth,
        storyRepository: stories,
        profileRepository: profile,
        streakRepository: _Streak(),
        streakReminderService: _Reminder(),
        bookmarkStore: bookmarks,
        milestoneStore: MemoryLevelMilestoneStore(),
        streakPresentationDelay: Duration.zero,
      ),
    };
    final transition = settings.arguments is TabRouteTransition
        ? settings.arguments! as TabRouteTransition
        : null;
    final child = ScopedFeaturePage(
      route: settings.name == AppRoutes.storyDetail
          ? '${AppRoutes.storyDetail}/ruth-and-naomi'
          : settings.name!,
      preparation: transition?.preparation,
      authRepository: auth,
      identityBound: settings.name == AppRoutes.storyDetail,
      child: destination,
    );
    return transition == null
        ? MaterialPageRoute<void>(settings: settings, builder: (_) => child)
        : TabGlideRoute(
            settings: settings,
            fromRoute: transition.fromRoute,
            builder: (_) => child,
          );
  }
}

class _Stories implements StoryRepository {
  int listCalls = 0;
  Completer<List<StoryDetail>>? pendingList;
  Completer<StoryDetail>? pendingDetail;
  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async {
    listCalls++;
    return pendingList?.future ?? [_story()];
  }

  @override
  Future<StoryDetail> fetchStory(String slug) async =>
      pendingDetail?.future ?? _story(body: 'Retained full story body.');
}

class _Games implements GameRepository {
  int listCalls = 0;
  Completer<List<MiniGame>>? pendingList;
  @override
  Future<List<MiniGame>> fetchGames({required String profileId}) async {
    listCalls++;
    return pendingList?.future ?? [_game()];
  }

  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) async =>
      _game(detail: true);
  @override
  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
  }) => throw UnimplementedError();
}

class _Profile implements ProfileRepository {
  int calls = 0;
  Completer<ProfileProgressSummary>? pending;
  @override
  Future<ProfileProgressSummary> fetchSummary({
    required String profileId,
  }) async {
    calls++;
    return pending?.future ?? _summary();
  }
}

class _Streak implements StreakRepository {
  @override
  Future<StreakClaimReceipt> claimPresentation({
    required String profileId,
  }) async => const StreakClaimReceipt();
}

class _Reminder implements StreakReminderService {
  @override
  Future<bool> isEnabled() async => false;
  @override
  Future<bool> enable({required KidProfile profile}) async => true;
  @override
  Future<void> disable() async {}
  @override
  Future<void> refreshAfterAppOpen({required KidProfile profile}) async {}
}

class _Settings implements ParentalControlsRepository {
  @override
  Future<ParentSettings> fetchSettings({required String profileId}) async =>
      ParentSettings(
        profileId: profileId,
        storyTextScale: StoryTextScale.comfortable,
        narrationEnabled: true,
        updatedAt: DateTime.utc(2026),
      );
  @override
  Future<ParentSettings> updateSettings({
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  }) => throw UnimplementedError();
}
