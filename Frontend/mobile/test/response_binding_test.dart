import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/games/data/game_api.dart';
import 'package:mobile/features/profile/data/profile_api.dart';
import 'package:mobile/features/progress/data/progress_api.dart';
import 'package:mobile/features/progress/domain/story_activity_event.dart';

void main() {
  test('rejects a profile summary bound to a different child', () async {
    final api = HttpProfileApi(
      baseUrl: 'https://api.kingdom-kids.test/api',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'profile': {'id': 'kid-2', 'display_name': 'Other child'},
          }),
          200,
        ),
      ),
    );

    await expectLater(
      api.fetchSummary(
        accessToken: 'access',
        profileId: 'kid-1',
        timezoneOffsetMinutes: 0,
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.code,
          'code',
          'profile_response_mismatch',
        ),
      ),
    );
  });

  test('rejects game detail bound to a different slug', () async {
    final api = HttpGameApi(
      baseUrl: 'https://api.kingdom-kids.test/api',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'id': 'game-2',
            'slug': 'another-game',
            'title': 'Another game',
            'game_type': 'quiz',
            'total_levels': 0,
          }),
          200,
        ),
      ),
    );

    await expectLater(
      api.fetchGame('requested-game', 'access', profileId: 'kid-1'),
      throwsA(
        isA<AppException>().having(
          (error) => error.code,
          'code',
          'game_response_mismatch',
        ),
      ),
    );
  });

  test('rejects a game submission receipt with a changed operation', () async {
    final api = HttpGameApi(
      baseUrl: 'https://api.kingdom-kids.test/api',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'attempt_id': 'attempt-1',
            'operation_id': 'different-operation',
            'game_slug': 'requested-game',
            'profile_id': 'kid-1',
            'level_number': 1,
            'completed': true,
            'score': 1,
            'max_score': 1,
            'stars': 1,
            'progress': {'profile_id': 'kid-1'},
          }),
          201,
        ),
      ),
    );

    await expectLater(
      api.submitResult(
        slug: 'requested-game',
        profileId: 'kid-1',
        levelNumber: 1,
        operationId: 'requested-operation',
        result: const {'answer': 'a'},
        accessToken: 'access',
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.code,
          'code',
          'game_submission_mismatch',
        ),
      ),
    );
  });

  test('rejects a story receipt bound to another story', () async {
    final api = HttpProgressApi(
      baseUrl: 'https://api.kingdom-kids.test/api',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'event_id': 'event-1',
            'operation_id': 'operation-1',
            'profile_id': 'kid-1',
            'event_type': 'story_started',
            'story_id': 'story-2',
            'recorded_at': '2026-08-11T10:00:00Z',
            'idempotent_replay': false,
          }),
          201,
        ),
      ),
    );

    await expectLater(
      api.recordStoryActivity(
        accessToken: 'access',
        profileId: 'kid-1',
        storyId: 'story-1',
        eventType: StoryActivityType.storyStarted,
        operationId: 'operation-1',
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.code,
          'code',
          'progress_response_mismatch',
        ),
      ),
    );
  });
}
