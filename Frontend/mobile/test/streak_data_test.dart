import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/streak/data/streak_api.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';

void main() {
  group('HttpStreakApi', () {
    test(
      'a repeat claim retains the saved XP and level transition without a streak page',
      () async {
        final api = HttpStreakApi(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'show': false,
                'profile_id': 'kid-1',
                'xp_awarded': 20,
                'level_milestone': _rewardMilestoneJson,
              }),
              200,
            ),
          ),
        );
        final receipt = await api.claimPresentation(
          accessToken: 'access-token',
          profileId: 'kid-1',
          timezoneOffsetMinutes: 0,
        );
        expect(receipt.presentation, isNull);
        expect(receipt.xpAwarded, 20);
        expect(receipt.levelMilestone?.previousLevel, 7);
        expect(receipt.levelMilestone?.level.number, 8);
      },
    );

    test(
      'all reward receipts require the requested child even without a streak page',
      () async {
        for (final show in [true, false]) {
          for (final profileId in [null, 'kid-2']) {
            final api = HttpStreakApi(
              client: MockClient(
                (_) async => http.Response(
                  jsonEncode({
                    'show': show,
                    'profile_id': profileId,
                    'xp_awarded': 20,
                    'level_milestone': _rewardMilestoneJson,
                    if (show) 'presentation': _presentationJson(),
                  }),
                  200,
                ),
              ),
            );
            await expectLater(
              api.claimPresentation(
                accessToken: 'token',
                profileId: 'kid-1',
                timezoneOffsetMinutes: 0,
              ),
              throwsA(
                isA<AppException>().having(
                  (error) => error.code,
                  'code',
                  'streak_response_mismatch',
                ),
              ),
            );
          }
        }
      },
    );

    test(
      'negative or non-integer XP is rejected instead of displayed',
      () async {
        for (final xp in [-20, '20', 20.5]) {
          final api = HttpStreakApi(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'show': false,
                  'profile_id': 'kid-1',
                  'xp_awarded': xp,
                }),
                200,
              ),
            ),
          );
          await expectLater(
            api.claimPresentation(
              accessToken: 'token',
              profileId: 'kid-1',
              timezoneOffsetMinutes: 0,
            ),
            throwsA(
              isA<AppException>().having(
                (error) => error.code,
                'code',
                'invalid_streak_response',
              ),
            ),
          );
        }
      },
    );

    test(
      'claims today on app open and parses the exact presentation',
      () async {
        late http.Request sentRequest;
        final api = HttpStreakApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response(
              jsonEncode({'show': true, 'presentation': _presentationJson()}),
              200,
            );
          }),
        );

        final receipt = await api.claimPresentation(
          accessToken: 'access-token',
          profileId: ' kid-1 ',
          timezoneOffsetMinutes: 60,
        );

        expect(sentRequest.method, 'POST');
        expect(
          sentRequest.url.path,
          '/api/progress/kid-profiles/kid-1/streak-presentations/claim/',
        );
        expect(sentRequest.headers['authorization'], 'Bearer access-token');
        expect(jsonDecode(sentRequest.body), {'timezone_offset_minutes': 60});
        final presentation = receipt.presentation;
        expect(presentation, isNotNull);
        expect(presentation!.state, StreakPresentationState.continued);
        expect(presentation.currentDays, 4);
        expect(presentation.longestDays, 6);
        expect(presentation.profile.displayName, 'Maya');
        expect(presentation.recentDays, hasLength(7));
      },
    );

    test('returns no page after today has already been claimed', () async {
      final api = HttpStreakApi(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'show': false}), 200),
        ),
      );

      final receipt = await api.claimPresentation(
        accessToken: 'access-token',
        profileId: 'kid-1',
        timezoneOffsetMinutes: 0,
      );

      expect(receipt.presentation, isNull);
      expect(receipt.xpAwarded, 0);
      expect(receipt.levelMilestone, isNull);
    });

    test(
      'rejects streak presentations without the requested profile ID',
      () async {
        for (final returnedProfileId in <String?>[null, 'kid-2']) {
          final api = HttpStreakApi(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'show': true,
                  'presentation': _presentationJson(
                    profileId: returnedProfileId,
                  ),
                }),
                200,
              ),
            ),
          );

          await expectLater(
            api.claimPresentation(
              accessToken: 'access-token',
              profileId: 'kid-1',
              timezoneOffsetMinutes: 0,
            ),
            throwsA(
              isA<AppException>().having(
                (error) => error.code,
                'code',
                'streak_response_mismatch',
              ),
            ),
          );
        }
      },
    );

    test('rejects the retired at-risk page state', () async {
      final api = HttpStreakApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'show': true,
              'presentation': _presentationJson(state: 'at_risk'),
            }),
            200,
          ),
        ),
      );

      await expectLater(
        api.claimPresentation(
          accessToken: 'access-token',
          profileId: 'kid-1',
          timezoneOffsetMinutes: 0,
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'invalid_streak_response',
          ),
        ),
      );
    });

    test('bounds the client timezone offset sent to the backend', () async {
      late http.Request sentRequest;
      final api = HttpStreakApi(
        client: MockClient((request) async {
          sentRequest = request;
          return http.Response(jsonEncode({'show': false}), 200);
        }),
      );

      await api.claimPresentation(
        accessToken: 'access-token',
        profileId: 'kid-1',
        timezoneOffsetMinutes: 2000,
      );

      expect(jsonDecode(sentRequest.body), {'timezone_offset_minutes': 840});
    });
  });
}

Map<String, dynamic> _presentationJson({
  String state = 'continued',
  String? profileId = 'kid-1',
}) => {
  'profile': {
    'id': ?profileId,
    'parent_id': 'parent-1',
    'display_name': 'Maya',
    'avatar_key': 'dove',
  },
  'state': state,
  'current_days': 4,
  'longest_days': 6,
  'local_date': '2026-07-25',
  'recent_days': [
    for (var day = 19; day <= 25; day++)
      {'date': '2026-07-$day', 'active': day >= 22},
  ],
};

const _rewardMilestoneJson = {
  'previous_level': 7,
  'level': {
    'number': 8,
    'title': 'Faithful Adventurer',
    'xp': 2100,
    'next_level_xp': 2400,
  },
};
