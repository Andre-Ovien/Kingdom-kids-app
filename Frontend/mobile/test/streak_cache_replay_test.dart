import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/data/game_api.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/milestones/domain/level_milestone.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';
import 'package:mobile/features/streak/data/streak_api.dart';
import 'package:mobile/features/streak/data/streak_repository.dart';
import 'package:mobile/features/streak/domain/streak_claim_receipt.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';

const _kid = KidProfile(
  id: 'replay-kid',
  parentId: 'replay-parent',
  displayName: 'Ada',
  avatarKey: 'dove',
);
const _sibling = KidProfile(
  id: 'replay-sibling',
  parentId: 'replay-parent',
  displayName: 'Nia',
  avatarKey: 'lion',
);
const _reward = StreakClaimReceipt(xpAwarded: 20);

void main() {
  setUp(featureReadCache.invalidate);

  test(
    'real HTTP positive daily replay preserves signed game catalogue on Home returns',
    () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(
        const AuthSession(
          parent: ParentAccount(
            id: 'replay-parent',
            email: 'replay@example.test',
          ),
          accessToken: 'test-access',
          refreshToken: 'test-refresh',
          profiles: [_kid],
        ),
      );
      await store.writeSelectedKidId(_kid.id);
      var gameReads = 0;
      var claims = 0;
      final today = DateTime.now();
      final date = _date(today);
      final expiry =
          today.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      final mediaEndpoint =
          AppConfig.contentMediaPolicy.sanitize(
            'https://api.cloudinary.com/v1_1/test/image/download',
          ) ??
          AppConfig.resolveApiUri('v1_1/test/image/download').toString();
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          claims++;
          return http.Response(
            jsonEncode({
              'show': claims == 1,
              'profile_id': _kid.id,
              'xp_awarded': 20,
              'level_milestone': null,
              if (claims == 1)
                'presentation': {
                  'profile': _kid.toJson(),
                  'state': 'first_streak',
                  'current_days': 1,
                  'longest_days': 1,
                  'local_date': date,
                  'recent_days': [
                    {'date': date, 'active': true},
                  ],
                },
            }),
            200,
          );
        }
        gameReads++;
        return http.Response(
          jsonEncode([
            {
              'id': 'game-replay',
              'slug': 'esther-quiz',
              'title': 'Esther',
              'game_type': 'quiz',
              'cover_image_url': Uri.parse(mediaEndpoint)
                  .replace(
                    queryParameters: {
                      'public_id': 'kingdom-kids/media-v1/asset',
                      'type': 'authenticated',
                      'signature': 'signature-$gameReads',
                      'expires_at': '$expiry',
                    },
                  )
                  .toString(),
              'progress': {'profile_id': _kid.id},
            },
          ]),
          200,
        );
      });
      const baseUrl = 'https://streak-replay.test/api';
      final auth = AuthRepository(
        sessionStore: store,
        api: HttpAuthApi(baseUrl: baseUrl, client: client),
      );
      final games = RemoteGameRepository(
        authRepository: auth,
        api: HttpGameApi(baseUrl: baseUrl, client: client),
      );
      final before = await games.fetchGames(profileId: _kid.id);
      final mediaGeneration = featureReadCache.mediaGeneration;
      String? afterRewardUrl;
      for (var visit = 0; visit < 4; visit++) {
        final receipt = await RemoteStreakRepository(
          authRepository: auth,
          api: HttpStreakApi(baseUrl: baseUrl, client: client),
          now: () => today,
        ).claimPresentation(profileId: _kid.id);
        expect(receipt.xpAwarded, 20);
        expect(receipt.presentation != null, visit == 0);
        final catalogue = await games.fetchGames(profileId: _kid.id);
        afterRewardUrl ??= catalogue.single.coverImageUrl;
        expect(catalogue.single.coverImageUrl, afterRewardUrl);
      }
      expect(claims, 4, reason: 'every visit still sends its own live POST');
      expect(gameReads, 2, reason: 'initial read plus one new daily reward');
      expect(afterRewardUrl, isNot(before.single.coverImageUrl));
      expect(featureReadCache.mediaGeneration, mediaGeneration);
    },
  );

  test(
    'lost response recovers on a positive replay, then invalidates once',
    () async {
      final auth = _Auth(scope: 'lost-response');
      final api = _Api((call) async {
        if (call == 1) throw const AppException('Response lost');
        return _reward;
      });
      await expectLater(_claim(auth, api), throwsA(isA<AppException>()));
      expect(auth.invalidations, 0);
      expect((await _claim(auth, api)).xpAwarded, 20);
      await _claim(auth, api);
      expect(api.calls, 3);
      expect(auth.invalidations, 1);
    },
  );

  test(
    'new day, changed reward and changed milestone each refresh once',
    () async {
      final auth = _Auth(scope: 'changing-rewards');
      var now = DateTime(2026, 11, 12);
      var reward = _reward;
      final api = _Api((_) async => reward);
      Future<void> claimTwice() async {
        await _claim(auth, api, now: () => now);
        await _claim(auth, api, now: () => now);
      }

      await claimTwice();
      reward = const StreakClaimReceipt(xpAwarded: 40);
      await claimTwice();
      reward = StreakClaimReceipt(
        xpAwarded: 40,
        levelMilestone: _milestone(300),
      );
      await claimTwice();
      reward = StreakClaimReceipt(
        xpAwarded: 40,
        levelMilestone: _milestone(320),
      );
      await claimTwice();
      now = now.add(const Duration(days: 1));
      await claimTwice();
      expect(auth.invalidations, 5);
      expect(api.calls, 10);
    },
  );

  test(
    'server presentation date takes precedence over device request date',
    () async {
      final auth = _Auth(scope: 'server-date');
      var deviceDay = DateTime(2026, 11, 12);
      final api = _Api(
        (_) async => StreakClaimReceipt(
          xpAwarded: 20,
          presentation: StreakPresentation(
            profile: _kid,
            state: StreakPresentationState.continued,
            currentDays: 2,
            longestDays: 2,
            localDate: DateTime(2026, 11, 11),
            recentDays: const [],
          ),
        ),
      );
      await _claim(auth, api, now: () => deviceDay);
      deviceDay = deviceDay.add(const Duration(days: 1));
      await _claim(auth, api, now: () => deviceDay);
      expect(auth.invalidations, 1);
    },
  );

  test(
    'backend, parent, child, avatar and explicit sign-in have distinct receipts',
    () async {
      final auth = _Auth(scope: ('origin-1', 'parent-1', 'kid-1', 'dove', 1));
      final api = _Api((_) async => _reward);
      for (final scope in [
        ('origin-1', 'parent-1', 'kid-1', 'dove', 1),
        ('origin-2', 'parent-1', 'kid-1', 'dove', 1),
        ('origin-2', 'parent-2', 'kid-1', 'dove', 1),
        ('origin-2', 'parent-2', 'kid-2', 'dove', 1),
        ('origin-2', 'parent-2', 'kid-2', 'lion', 1),
        ('origin-2', 'parent-2', 'kid-2', 'lion', 2),
      ]) {
        auth.scope = scope;
        await _claim(auth, api);
        await _claim(auth, api);
      }
      expect(auth.invalidations, 6);
      expect(api.calls, 12);
    },
  );

  for (final change in ['child', 'same-parent-login', 'scope-restored']) {
    test(
      'committed old $change receipt does not invalidate the new scope',
      () async {
        final initialScope = change == 'scope-restored'
            ? null
            : 'delayed-$change-before';
        final auth = _Auth(scope: initialScope);
        final started = Completer<void>();
        final pending = Completer<StreakClaimReceipt>();
        final api = _Api((call) {
          if (call > 1) return Future.value(_reward);
          started.complete();
          return pending.future;
        });
        final old = _claim(auth, api);
        await started.future;
        auth.scope = 'delayed-$change-after';
        if (change == 'child') auth.kid = _sibling;
        pending.complete(_reward);
        expect((await old).xpAwarded, 20);
        expect(auth.invalidations, 0);
        auth.kid = _kid;
        auth.scope = initialScope;
        await _claim(auth, api);
        expect(
          auth.invalidations,
          1,
          reason: 'old response was never marked seen',
        );
      },
    );
  }

  for (final scopeUnavailable in ['null', 'throws']) {
    test(
      '$scopeUnavailable scope keeps conservative live positive refreshes',
      () async {
        final auth = _Auth(scope: null)
          ..scopeThrows = scopeUnavailable == 'throws';
        final api = _Api((_) async => _reward);
        await _claim(auth, api);
        await _claim(auth, api);
        expect(api.calls, 2);
        expect(auth.invalidations, 2);
      },
    );
  }

  test('zero receipt is not remembered as a reward or invalidated', () async {
    final auth = _Auth(scope: 'zero-then-reward');
    final api = _Api(
      (call) async => call == 1 ? const StreakClaimReceipt() : _reward,
    );
    await _claim(auth, api);
    expect(auth.invalidations, 0);
    await _claim(auth, api);
    await _claim(auth, api);
    expect(auth.invalidations, 1);
  });

  test(
    'remembered rewards stay bounded across distinct signed-in scopes',
    () async {
      final auth = _Auth(scope: ('bounded-rewards', 0));
      final api = _Api((_) async => _reward);
      for (var index = 0; index < 129; index++) {
        auth.scope = ('bounded-rewards', index);
        await _claim(auth, api);
      }
      auth.scope = ('bounded-rewards', 0);
      await _claim(auth, api);
      expect(auth.invalidations, 130, reason: 'the oldest receipt was evicted');
    },
  );

  test(
    'postcommit local read failure preserves receipt without marking it seen',
    () async {
      final auth = _Auth(scope: 'postcommit-storage-failure');
      final api = _Api((call) async {
        auth.kidThrows = call == 1;
        return _reward;
      });
      expect((await _claim(auth, api)).xpAwarded, 20);
      expect(auth.invalidations, 0);
      auth.kidThrows = false;
      await _claim(auth, api);
      expect(auth.invalidations, 1);
    },
  );
}

Future<StreakClaimReceipt> _claim(
  _Auth auth,
  _Api api, {
  DateTime Function()? now,
}) => RemoteStreakRepository(
  authRepository: auth,
  api: api,
  now: now ?? () => DateTime(2026, 11, 12),
).claimPresentation(profileId: _kid.id);

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

LevelMilestone _milestone(int xp) => LevelMilestone(
  previousLevel: 1,
  level: ProfileLevel(number: 2, title: 'Explorer', xp: xp, nextLevelXp: 600),
);

class _Api implements StreakApi {
  _Api(this.respond);

  final Future<StreakClaimReceipt> Function(int call) respond;
  int calls = 0;

  @override
  Future<StreakClaimReceipt> claimPresentation({
    required String accessToken,
    required String profileId,
    required int timezoneOffsetMinutes,
  }) => respond(++calls);
}

class _Auth extends AuthRepository {
  _Auth({required this.scope});

  Object? scope;
  bool scopeThrows = false;
  bool kidThrows = false;
  KidProfile kid = _kid;
  int invalidations = 0;

  @override
  Future<KidProfile?> currentKid() async {
    if (kidThrows) throw StateError('Local storage temporarily unavailable');
    return kid;
  }

  @override
  Future<Object?> featureCacheScope() async {
    if (scopeThrows) throw StateError('Scope temporarily unavailable');
    return scope;
  }

  @override
  Future<T> withAccessToken<T>(Future<T> Function(String) operation) =>
      operation('test-access');

  @override
  void invalidateFeatureReads({bool includeMedia = true}) {
    expect(includeMedia, isFalse);
    invalidations++;
    super.invalidateFeatureReads(includeMedia: includeMedia);
  }
}
