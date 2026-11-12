import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/profile/data/profile_api.dart';
import 'package:mobile/features/profile/data/profile_repository.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';

void main() {
  group('profile summary domain', () {
    test('parses identity, progression, badges, streak, and activity', () {
      final summary = ProfileProgressSummary.fromJson(_summaryJson());

      expect(summary.profile.id, 'kid-1');
      expect(summary.profile.displayName, 'Amara');
      expect(summary.profile.avatarKey, 'star');
      expect(summary.level.number, 2);
      expect(summary.level.title, 'Little Explorer');
      expect(summary.level.xp, 500);
      expect(summary.level.nextLevelXp, 600);
      expect(summary.level.maxLevel, 15);
      expect(summary.level.isMaxLevel, isFalse);
      expect(summary.level.progress, closeTo(2 / 3, 0.0001));
      expect(summary.stats.completedGameLevels, 3);
      expect(summary.stats.totalGameLevels, 24);
      expect(summary.stats.gameStars, 10);
      expect(summary.stats.maxGameStars, 72);
      expect(summary.stats.gamesStarted, 2);
      expect(summary.stats.gamesCompleted, 1);
      expect(summary.stats.earnedBadges, 1);
      expect(summary.stats.totalStories, 8);
      expect(summary.stats.storiesStarted, 3);
      expect(summary.stats.storiesCompleted, 2);
      expect(summary.badges, hasLength(1));
      expect(summary.badges.single.key, 'first-play');
      expect(summary.badges.single.earned, isTrue);
      expect(summary.badges.single.completion, 1);
      expect(summary.activityStreak.currentDays, 2);
      expect(summary.activityStreak.longestDays, 4);
      expect(summary.weeklyActivity, hasLength(2));
      expect(summary.weeklyActivity.last.label, 'Jul 13');
      expect(summary.weeklyActivity.last.attempts, 4);
      expect(summary.weeklyActivity.last.storyCompletions, 2);
      expect(summary.weeklyActivity.last.activities, 6);
      expect(
        summary.weeklyActivity.last.weekStart,
        DateTime.parse('2026-07-13'),
      );
      expect(summary.lastActivityAt, DateTime.parse('2026-07-15T08:00:00Z'));
    });

    test('keeps older game-only summary responses compatible', () {
      final json = _summaryJson();
      final stats =
          Map<String, dynamic>.from(json['stats']! as Map<String, dynamic>)
            ..removeWhere(
              (key, _) => key.startsWith('stor') || key == 'total_stories',
            );
      final oldWeeks = [
        {'week_start': '2026-07-13', 'label': 'Jul 13', 'attempts': 4},
      ];
      final summary = ProfileProgressSummary.fromJson({
        ...json,
        'stats': stats,
        'weekly_activity': oldWeeks,
      });

      expect(summary.stats.totalStories, 0);
      expect(summary.stats.storiesStarted, 0);
      expect(summary.stats.storiesCompleted, 0);
      expect(summary.xpBreakdown, isNull);
      expect(summary.weeklyActivity.single.storyCompletions, 0);
      expect(summary.weeklyActivity.single.activities, 4);
      expect(summary.streakWeek, isNull);
    });

    test(
      'parses real weekday history without inventing consecutive visits',
      () {
        final summary = ProfileProgressSummary.fromJson({
          ..._summaryJson(),
          'streak_week': {
            'local_date': '2026-07-15',
            'days': [
              for (var day = 13; day <= 19; day++)
                {'date': '2026-07-$day', 'active': day == 13 || day == 15},
            ],
          },
        });
        final week = summary.streakWeek!;
        expect(week.localDate, DateTime(2026, 7, 15));
        expect(week.days.map((day) => day.active), [
          true,
          false,
          true,
          false,
          false,
          false,
          false,
        ]);
        expect(week.days.first.date.weekday, DateTime.monday);
        expect(week.days.last.date.weekday, DateTime.sunday);
        expect(() => week.days.clear(), throwsUnsupportedError);
        expect(summary.activityStreak.currentDays, 2);
      },
    );

    test('malformed optional weekday history never breaks the summary', () {
      final valid = {
        'local_date': '2026-07-15',
        'days': [
          for (var day = 13; day <= 19; day++)
            {'date': '2026-07-$day', 'active': day == 13 || day == 15},
        ],
      };
      for (final malformed in <Object?>[
        null,
        'not a week',
        {},
        {...valid, 'local_date': '2026-02-31'},
        {...valid, 'days': []},
        {
          ...valid,
          'days': [
            for (var i = 0; i < 7; i++) {'date': '2026-07-13', 'active': true},
          ],
        },
        {
          ...valid,
          'days': [
            for (var day = 13; day <= 19; day++)
              {'date': '2026-07-$day', 'active': true},
          ],
        },
      ]) {
        final summary = ProfileProgressSummary.fromJson({
          ..._summaryJson(),
          'streak_week': malformed,
        });
        expect(summary.streakWeek, isNull);
        expect(summary.profile.id, 'kid-1');
        expect(summary.activityStreak.currentDays, 2);
      }
    });

    test(
      'keeps combined quest, completed-story and streak XP authoritative',
      () {
        final summary = ProfileProgressSummary.fromJson({
          ..._summaryJson(),
          'xp_breakdown': {'quests': 260, 'stories': 200, 'streaks': 40},
        });

        final sources = summary.xpBreakdown!;
        expect(sources.quests, 260);
        expect(sources.stories, 200);
        expect(sources.streaks, 40);
        expect(sources.total, 500);
        expect(sources.total, summary.level.xp);
        expect(summary.level.number, 2);
        expect(summary.level.nextLevelXp, 600);
        expect(summary.level.progress, closeTo(2 / 3, 0.0001));
      },
    );

    test('keeps level 14 progress on the existing 300 XP interval', () {
      final level = ProfileLevel.fromJson({
        'number': 14,
        'title': 'Kingdom Guardian',
        'xp': 4199,
        'next_level_xp': 4200,
        'max_level': 15,
        'is_max_level': false,
      });

      expect(level.isMaxLevel, isFalse);
      expect(level.progress, closeTo(299 / 300, 0.0001));
    });

    test('final rank is complete while lifetime XP keeps growing', () {
      for (final xp in [4200, 9000]) {
        final level = ProfileLevel.fromJson({
          'number': 15,
          'title': 'Kingdom Champion',
          'xp': xp,
          'next_level_xp': 4200,
          'max_level': 15,
          'is_max_level': true,
        });

        expect(level.number, 15);
        expect(level.maxLevel, 15);
        expect(level.isMaxLevel, isTrue);
        expect(level.progress, 1);
        expect(level.xp, xp);
      }
    });

    test('older level responses cannot create progress beyond level 15', () {
      for (final number in [15, 31]) {
        final level = ProfileLevel.fromJson({
          'number': number,
          'title': 'Kingdom Champion',
          'xp': 9000,
          'next_level_xp': 9300,
        });

        expect(level.number, 15);
        expect(level.maxLevel, 15);
        expect(level.isMaxLevel, isTrue);
        expect(level.progress, 1);
        expect(level.xp, 9000);
      }
    });
  });

  group('HttpProfileApi', () {
    test(
      'sends the exact summary path, timezone query, and bearer token',
      () async {
        late http.Request sentRequest;
        final api = HttpProfileApi(
          baseUrl: 'https://kingdom-kids.test',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response(jsonEncode(_summaryJson()), 200);
          }),
        );

        final summary = await api.fetchSummary(
          accessToken: 'access-token',
          profileId: 'kid-1',
          timezoneOffsetMinutes: 60,
        );

        expect(sentRequest.method, 'GET');
        expect(
          sentRequest.url.path,
          '/api/progress/kid-profiles/kid-1/summary/',
        );
        expect(sentRequest.url.queryParameters, {
          'timezone_offset_minutes': '60',
        });
        expect(sentRequest.headers['accept'], 'application/json');
        expect(sentRequest.headers['authorization'], 'Bearer access-token');
        expect(summary.profile.id, 'kid-1');
        expect(summary.stats.gameStars, 10);
      },
    );

    test(
      'preserves status, code, details, and nested backend message',
      () async {
        final api = HttpProfileApi(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'timezone_offset_minutes': ['Enter a whole number.'],
                'code': 'invalid_timezone',
              }),
              400,
            ),
          ),
        );

        await expectLater(
          api.fetchSummary(
            accessToken: 'access-token',
            profileId: 'kid-1',
            timezoneOffsetMinutes: 60,
          ),
          throwsA(
            isA<AppException>()
                .having(
                  (error) => error.message,
                  'message',
                  'Enter a whole number.',
                )
                .having((error) => error.statusCode, 'statusCode', 400)
                .having((error) => error.code, 'code', 'invalid_timezone')
                .having(
                  (error) => error.details['timezone_offset_minutes'],
                  'details',
                  ['Enter a whole number.'],
                ),
          ),
        );
      },
    );
  });

  group('RemoteProfileRepository', () {
    test(
      'guards against a missing active profile before calling the API',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session());
        final api = _RecordingProfileApi();
        final repository = RemoteProfileRepository(
          authRepository: AuthRepository(sessionStore: store),
          api: api,
        );

        await expectLater(
          repository.fetchSummary(profileId: 'kid-1'),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'active_kid_required',
            ),
          ),
        );
        expect(api.calls, 0);
      },
    );

    test(
      'guards against a changed active profile before calling the API',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session());
        await store.writeSelectedKidId('kid-1');
        final api = _RecordingProfileApi();
        final repository = RemoteProfileRepository(
          authRepository: AuthRepository(sessionStore: store),
          api: api,
        );

        await expectLater(
          repository.fetchSummary(profileId: 'kid-2'),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'active_kid_changed',
            ),
          ),
        );
        expect(api.calls, 0);
      },
    );

    test(
      'delegates with the active profile and current access token',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session());
        await store.writeSelectedKidId('kid-1');
        final api = _RecordingProfileApi();
        final repository = RemoteProfileRepository(
          authRepository: AuthRepository(sessionStore: store),
          api: api,
        );

        final summary = await repository.fetchSummary(profileId: '  kid-1  ');

        expect(api.calls, 1);
        expect(api.accessToken, 'access-token');
        expect(api.profileId, 'kid-1');
        expect(api.timezoneOffsetMinutes, inInclusiveRange(-840, 840));
        expect(summary.profile.id, 'kid-1');
      },
    );
  });
}

Map<String, dynamic> _summaryJson() => {
  'profile': {'id': 'kid-1', 'display_name': 'Amara', 'avatar_key': 'star'},
  'level': {
    'number': 2,
    'title': 'Little Explorer',
    'xp': 500,
    'next_level_xp': 600,
  },
  'stats': {
    'completed_game_levels': 3,
    'total_game_levels': 24,
    'game_stars': 10,
    'max_game_stars': 72,
    'games_started': 2,
    'games_completed': 1,
    'earned_badges': 1,
    'total_stories': 8,
    'stories_started': 3,
    'stories_completed': 2,
  },
  'badges': [
    {
      'key': 'first-play',
      'title': 'First Play',
      'description': 'Finish your first game attempt.',
      'icon_key': 'play-spark',
      'target': 1,
      'earned': true,
      'progress': 1,
    },
  ],
  'activity_streak': {'current_days': 2, 'longest_days': 4},
  'weekly_activity': [
    {
      'week_start': '2026-07-06',
      'label': 'Jul 6',
      'attempts': 2,
      'story_completions': 1,
      'activities': 3,
    },
    {
      'week_start': '2026-07-13',
      'label': 'Jul 13',
      'attempts': 4,
      'story_completions': 2,
      'activities': 6,
    },
  ],
  'last_activity_at': '2026-07-15T08:00:00Z',
};

AuthSession _session() => const AuthSession(
  parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  profiles: [
    KidProfile(
      id: 'kid-1',
      parentId: 'parent-1',
      displayName: 'Amara',
      avatarKey: 'star',
    ),
  ],
);

final class _RecordingProfileApi implements ProfileApi {
  int calls = 0;
  String? accessToken;
  String? profileId;
  int? timezoneOffsetMinutes;

  @override
  Future<ProfileProgressSummary> fetchSummary({
    required String accessToken,
    required String profileId,
    required int timezoneOffsetMinutes,
  }) async {
    calls++;
    this.accessToken = accessToken;
    this.profileId = profileId;
    this.timezoneOffsetMinutes = timezoneOffsetMinutes;
    return ProfileProgressSummary.fromJson(_summaryJson());
  }
}
