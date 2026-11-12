import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/data/game_api.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/presentation/games_screen.dart';
import 'package:mobile/features/profile/data/profile_api.dart';
import 'package:mobile/features/profile/data/profile_repository.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_api.dart';
import 'package:mobile/features/parental_controls/data/parent_settings_store.dart';
import 'package:mobile/features/stories/data/story_api.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
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
  accessToken: 'access-one',
  refreshToken: 'refresh-one',
  profiles: [_kid, _sibling],
);

void main() {
  setUp(featureReadCache.invalidate);

  test(
    'read cache coalesces requests, expires and bounds retained entries',
    () async {
      var now = DateTime.utc(2026, 11, 12);
      final cache = FeatureReadCache(maxEntries: 2, now: () => now);
      final pending = Completer<String>();
      var calls = 0;
      Future<String> load() {
        calls++;
        return pending.future;
      }

      final one = cache.read('one', load);
      final overlapping = cache.read('one', load);
      pending.complete('value');
      expect(await one, 'value');
      expect(await overlapping, 'value');
      await cache.read('one', load);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      await cache.read('one', load);
      expect(calls, 2);
      await cache.read('two', () async => '2');
      await cache.read('three', () async => '3');
      await cache.read('one', load);
      expect(calls, 3);
    },
  );

  test('errors and invalidated in-flight results are never retained', () async {
    final cache = FeatureReadCache();
    await expectLater(
      cache.read(
        'key',
        () async => throw const AppException('Denied', statusCode: 403),
      ),
      throwsException,
    );
    expect(await cache.read('key', () async => 'allowed'), 'allowed');
    final pending = Completer<String>();
    final old = cache.read('pending', () => pending.future);
    cache.invalidate();
    pending.complete('old');
    await old;
    expect(await cache.read('pending', () async => 'fresh'), 'fresh');
  });

  test(
    'signed metadata expires before the URL and unknown query credentials bypass retention',
    () async {
      var now = DateTime.utc(2026, 11, 12);
      final cache = FeatureReadCache(now: () => now);
      final expires =
          now.add(const Duration(seconds: 20)).millisecondsSinceEpoch ~/ 1000;
      final url =
          'https://api.cloudinary.com/v1_1/test/image/download?signature=private&expires_at=$expires';
      var calls = 0;
      Future<String> load() async {
        calls++;
        return url;
      }

      await cache.read(
        'media',
        load,
        expiresAt: (url) => featureMediaExpiry([url]),
      );
      await cache.read(
        'media',
        load,
        expiresAt: (url) => featureMediaExpiry([url]),
      );
      expect(calls, 1);
      now = now.add(const Duration(seconds: 10));
      await cache.read(
        'media',
        load,
        expiresAt: (url) => featureMediaExpiry([url]),
      );
      expect(calls, 2);
      expect(
        featureMediaExpiry([
          'https://cdn.test/audio?token=private',
        ])!.isBefore(now),
        isTrue,
      );
    },
  );

  test(
    'recreated feature repositories share validated HTTP reads; mutation refreshes games and profile',
    () async {
      final store = await _store();
      final auth = AuthRepository(sessionStore: store);
      final requests = <String, int>{};
      var completed = false;
      final client = MockClient((request) async {
        final key = '${request.method} ${request.url.path}';
        requests.update(key, (count) => count + 1, ifAbsent: () => 1);
        final child = request.url.queryParameters['profile_id'] ?? 'kid-1';
        if (request.method == 'POST') {
          completed = true;
          return http.Response(
            jsonEncode({
              'attempt_id': 'attempt-1',
              'operation_id': 'operation-1',
              'game_slug': 'esther-quiz',
              'profile_id': 'kid-1',
              'level_number': 1,
              'completed': true,
              'progress': {'profile_id': 'kid-1'},
            }),
            200,
          );
        }
        if (request.url.path.contains('/games/')) {
          final game = _game(child, completed: completed);
          return http.Response(
            jsonEncode(request.url.path.endsWith('/games/') ? [game] : game),
            200,
          );
        }
        if (request.url.path.contains('/summary/')) {
          return http.Response(
            jsonEncode({
              'profile': _kid.toJson(),
              'level': {'xp': completed ? 20 : 0},
            }),
            200,
          );
        }
        final story = {
          'id': 'story-1',
          'slug': 'ruth-and-naomi',
          'title': 'Ruth',
          'body': 'A story.',
        };
        return http.Response(
          jsonEncode(request.url.path.endsWith('/stories/') ? [story] : story),
          200,
        );
      });
      final gameApi = HttpGameApi(
        client: client,
        baseUrl: 'https://first.test/api',
      );
      final storyApi = HttpStoryApi(
        client: client,
        baseUrl: 'https://first.test/api',
      );
      final profileApi = HttpProfileApi(
        client: client,
        baseUrl: 'https://first.test/api',
      );
      for (var visit = 0; visit < 3; visit++) {
        await RemoteStoryRepository(
          authRepository: auth,
          api: storyApi,
        ).fetchStories();
        await RemoteStoryRepository(
          authRepository: auth,
          api: storyApi,
        ).fetchStory('ruth-and-naomi');
        await RemoteGameRepository(
          authRepository: auth,
          api: gameApi,
        ).fetchGames(profileId: _kid.id);
        await RemoteGameRepository(
          authRepository: auth,
          api: gameApi,
        ).fetchGame('esther-quiz', profileId: _kid.id);
        await RemoteProfileRepository(
          authRepository: auth,
          api: profileApi,
        ).fetchSummary(profileId: _kid.id);
      }
      expect(requests.values, everyElement(1));
      await RemoteGameRepository(
        authRepository: auth,
        api: gameApi,
      ).submitResult(
        slug: 'esther-quiz',
        profileId: _kid.id,
        levelNumber: 1,
        operationId: 'operation-1',
        result: {'answer': 'yes'},
      );
      await RemoteGameRepository(
        authRepository: auth,
        api: gameApi,
      ).fetchGames(profileId: _kid.id);
      final summary = await RemoteProfileRepository(
        authRepository: auth,
        api: profileApi,
      ).fetchSummary(profileId: _kid.id);
      expect(summary.level.xp, 20);
      expect(requests['GET /api/games/'], 2);
      expect(requests['GET /api/progress/kid-profiles/kid-1/summary/'], 2);
    },
  );

  test(
    'token rotation preserves reuse; child, parent, backend and explicit sign-in do not share',
    () async {
      final store = await _store();
      final auth = AuthRepository(
        sessionStore: store,
        api: HttpAuthApi(
          client: MockClient(
            (_) async => http.Response(jsonEncode(_session.toJson()), 200),
          ),
          baseUrl: 'https://one.test/api',
        ),
      );
      var calls = 0;
      Future<int> read() =>
          auth.withCachedFeatureRead('feature', (_) async => ++calls);
      expect(await read(), 1);
      await store.writeSession(
        _session.copyWith(
          accessToken: 'rotated',
          refreshToken: 'rotated-refresh',
        ),
      );
      expect(await read(), 1);
      await auth.selectKid(_sibling);
      expect(await read(), 2);
      await store.writeSession(
        _session.copyWith(
          parent: const ParentAccount(
            id: 'parent-2',
            email: 'other@test.example',
          ),
        ),
      );
      expect(await read(), 3);
      final otherBackend = AuthRepository(
        sessionStore: store,
        api: HttpAuthApi(baseUrl: 'https://two.test/api'),
      );
      expect(
        await otherBackend.withCachedFeatureRead(
          'feature',
          (_) async => ++calls,
        ),
        4,
      );
      await auth.login(
        const LoginRequest(email: 'parent@example.test', password: 'test'),
      );
      expect(await read(), 5);
      await auth.logout();
      expect(await store.readSession(), isNull);
      await expectLater(
        read(),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'authentication_required',
          ),
        ),
      );
    },
  );

  test(
    'authorized media metadata recovery bypasses stale models without invalidating active audio',
    () async {
      final store = await _store();
      final auth = AuthRepository(sessionStore: store);
      var reads = 0;
      final repository = RemoteStoryRepository(
        authRepository: auth,
        api: HttpStoryApi(
          baseUrl: 'https://first.test/api',
          client: MockClient((_) async {
            reads++;
            return http.Response(
              jsonEncode({
                'id': 'story-1',
                'slug': 'ruth-and-naomi',
                'title': 'Edition $reads',
                'body': 'Same story.',
              }),
              200,
            );
          }),
        ),
      );
      await repository.fetchStory('ruth-and-naomi');
      await repository.fetchStory('ruth-and-naomi');
      expect(reads, 1);
      final generation = featureReadCache.mediaGeneration;
      final fresh = await repository.fetchFreshStory('ruth-and-naomi');
      expect(fresh.title, 'Edition 2');
      expect(reads, 2);
      expect(featureReadCache.mediaGeneration, generation);
    },
  );

  test(
    'delayed reads cannot publish to another child or survive a mutation as current',
    () async {
      final store = await _store();
      final auth = AuthRepository(sessionStore: store);
      final started = Completer<void>();
      final pending = Completer<String>();
      final result = auth.withCachedFeatureRead('read', (_) {
        started.complete();
        return pending.future;
      });
      await started.future;
      await auth.selectKid(_sibling);
      final failure = expectLater(result, throwsException);
      pending.complete('old child');
      await failure;
      final first = Completer<String>();
      final requested = Completer<void>();
      var calls = 0;
      final mutationRead = auth.withCachedFeatureRead('mutation', (_) {
        calls++;
        if (calls == 1) {
          requested.complete();
          return first.future;
        }
        return Future.value('fresh progress');
      });
      await requested.future;
      auth.invalidateFeatureReads();
      first.complete('old progress');
      expect(await mutationRead, 'fresh progress');
      expect(calls, 2);
    },
  );

  test(
    'profile and preference requests cannot bind a previously selected child to a new cache scope',
    () async {
      for (final preferences in [false, true]) {
        final store = await _store();
        final auth = _SwitchBeforeCacheAuth(store);
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        });
        final Future<Object> request = preferences
            ? RemoteParentalControlsRepository(
                authRepository: auth,
                api: HttpParentalControlsApi(client: client),
                settingsStore: MemoryParentSettingsStore(),
              ).fetchSettings(profileId: _kid.id)
            : RemoteProfileRepository(
                authRepository: auth,
                api: HttpProfileApi(client: client),
              ).fetchSummary(profileId: _kid.id);
        await expectLater(
          request,
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'active_kid_changed',
            ),
          ),
        );
        expect(calls, 0);
      }
    },
  );

  testWidgets(
    'Games replacement restores scroll and filter state without another catalogue request',
    (tester) async {
      final store = await _store();
      final auth = AuthRepository(sessionStore: store);
      var requests = 0;
      final api = HttpGameApi(
        baseUrl: 'https://test.example/api',
        client: MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode(
              List.generate(
                12,
                (i) => {
                  ..._game(_kid.id, slug: 'quest-$i'),
                  'game_type': ['quiz', 'puzzle', 'matching', 'aim'][i % 4],
                },
              ),
            ),
            200,
          );
        }),
      );
      final memory = <String, Object?>{};
      Widget page() => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: FeatureViewMemory(
          values: memory,
          child: GamesScreen(
            repository: RemoteGameRepository(authRepository: auth, api: api),
            authRepository: auth,
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final scroll = find.byKey(const Key('games-scroll'));
      final controller = tester.widget<CustomScrollView>(scroll).controller!;
      await tester.ensureVisible(find.byKey(const Key('game-search-toggle')));
      await tester.tap(find.byKey(const Key('game-search-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('game-search-field')),
        'Esther',
      );
      await tester.pumpAndSettle();
      controller.jumpTo(1400);
      await tester.pump();
      expect(controller.offset, 1400);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(memory['scroll'], 1400.0);
      expect(memory['query'], 'Esther');
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(tester.widget<CustomScrollView>(scroll).controller!.offset, 1400);
      await tester.scrollUntilVisible(
        find.byKey(const Key('game-search-field')),
        -250,
        scrollable: find
            .descendant(of: scroll, matching: find.byType(Scrollable))
            .first,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('game-search-field')))
            .controller!
            .text,
        'Esther',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _SwitchBeforeCacheAuth extends AuthRepository {
  _SwitchBeforeCacheAuth(AuthSessionStore store) : super(sessionStore: store);
  bool _switch = true;
  @override
  Future<T> withCachedFeatureRead<T>(
    Object key,
    Future<T> Function(String token) operation, {
    Duration maxAge = const Duration(minutes: 1),
    DateTime? Function(T value)? expiresAt,
    bool progressIndependent = false,
  }) async {
    if (_switch) {
      _switch = false;
      await selectKid(_sibling);
    }
    return super.withCachedFeatureRead(
      key,
      operation,
      maxAge: maxAge,
      expiresAt: expiresAt,
      progressIndependent: progressIndependent,
    );
  }
}

Future<MemoryAuthSessionStore> _store() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(_session);
  await store.writeSelectedKidId(_kid.id);
  return store;
}

Map<String, Object?> _game(
  String child, {
  String slug = 'esther-quiz',
  bool completed = false,
}) => {
  'id': slug,
  'slug': slug,
  'title': 'Esther quiz',
  'game_type': 'quiz',
  'total_levels': 1,
  'progress': {'profile_id': child, 'completed_levels': completed ? 1 : 0},
};
