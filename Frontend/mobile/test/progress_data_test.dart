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
import 'package:mobile/features/progress/data/progress_api.dart';
import 'package:mobile/features/progress/data/progress_repository.dart';
import 'package:mobile/features/progress/domain/story_activity_event.dart';

void main() {
  group('HttpProgressApi', () {
    test(
      'posts the exact profile event contract and parses a new event',
      () async {
        late http.Request sentRequest;
        final api = HttpProgressApi(
          baseUrl: 'https://kingdom-kids.test',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response(jsonEncode(_eventJson()), 201);
          }),
        );

        final event = await api.recordStoryActivity(
          accessToken: 'access-token',
          profileId: ' kid-1 ',
          storyId: ' story-1 ',
          eventType: StoryActivityType.storyStarted,
          operationId: ' 00000000-0000-4000-8000-000000000001 ',
        );

        expect(sentRequest.method, 'POST');
        expect(
          sentRequest.url.path,
          '/api/progress/kid-profiles/kid-1/activity-events/',
        );
        expect(sentRequest.headers['accept'], 'application/json');
        expect(sentRequest.headers['authorization'], 'Bearer access-token');
        expect(sentRequest.headers['content-type'], 'application/json');
        expect(jsonDecode(sentRequest.body), {
          'operation_id': '00000000-0000-4000-8000-000000000001',
          'event_type': 'story_started',
          'story_id': 'story-1',
        });
        expect(event.eventId, 'event-1');
        expect(event.profileId, 'kid-1');
        expect(event.storyId, 'story-1');
        expect(event.type, StoryActivityType.storyStarted);
        expect(event.isIdempotentReplay, isFalse);
        expect(event.recordedAt, DateTime.parse('2026-07-17T10:00:00Z'));
      },
    );

    test('accepts an idempotent replay returned with 200', () async {
      final api = HttpProgressApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(_eventJson(idempotentReplay: true)),
            200,
          ),
        ),
      );

      final event = await api.recordStoryActivity(
        accessToken: 'access-token',
        profileId: 'kid-1',
        storyId: 'story-1',
        eventType: StoryActivityType.storyStarted,
        operationId: '00000000-0000-4000-8000-000000000001',
      );

      expect(event.isIdempotentReplay, isTrue);
    });

    test('preserves a conflict status, code, details, and message', () async {
      final api = HttpProgressApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'detail': 'That operation ID already belongs to another event.',
              'code': 'operation_conflict',
            }),
            409,
          ),
        ),
      );

      await expectLater(
        api.recordStoryActivity(
          accessToken: 'access-token',
          profileId: 'kid-1',
          storyId: 'story-1',
          eventType: StoryActivityType.storyCompleted,
          operationId: '00000000-0000-4000-8000-000000000001',
        ),
        throwsA(
          isA<AppException>()
              .having((error) => error.statusCode, 'statusCode', 409)
              .having((error) => error.code, 'code', 'operation_conflict')
              .having(
                (error) => error.message,
                'message',
                'That operation ID already belongs to another event.',
              )
              .having(
                (error) => error.details['detail'],
                'details',
                'That operation ID already belongs to another event.',
              ),
        ),
      );
    });

    test('rejects a missing story id before making a request', () async {
      var calls = 0;
      final api = HttpProgressApi(
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        api.recordStoryActivity(
          accessToken: 'access-token',
          profileId: 'kid-1',
          storyId: '  ',
          eventType: StoryActivityType.storyStarted,
          operationId: '00000000-0000-4000-8000-000000000001',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'invalid_story_id',
          ),
        ),
      );
      expect(calls, 0);
    });
  });

  group('RemoteProgressRepository', () {
    test('guards a missing active profile before calling the API', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session());
      final api = _RecordingProgressApi();
      final repository = RemoteProgressRepository(
        authRepository: AuthRepository(sessionStore: store),
        api: api,
      );

      await expectLater(
        repository.recordStoryActivity(
          profileId: 'kid-1',
          storyId: 'story-1',
          eventType: StoryActivityType.storyStarted,
          operationId: 'operation-1',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'active_kid_required',
          ),
        ),
      );
      expect(api.calls, 0);
    });

    test('guards a changed active profile before calling the API', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session());
      await store.writeSelectedKidId('kid-1');
      final api = _RecordingProgressApi();
      final repository = RemoteProgressRepository(
        authRepository: AuthRepository(sessionStore: store),
        api: api,
      );

      await expectLater(
        repository.recordStoryActivity(
          profileId: 'kid-2',
          storyId: 'story-1',
          eventType: StoryActivityType.storyStarted,
          operationId: 'operation-1',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'active_kid_changed',
          ),
        ),
      );
      expect(api.calls, 0);
    });

    test('delegates with the active profile and access token', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session());
      await store.writeSelectedKidId('kid-1');
      final api = _RecordingProgressApi();
      final repository = RemoteProgressRepository(
        authRepository: AuthRepository(sessionStore: store),
        api: api,
      );

      final event = await repository.recordStoryActivity(
        profileId: ' kid-1 ',
        storyId: 'story-1',
        eventType: StoryActivityType.storyCompleted,
        operationId: 'operation-1',
      );

      expect(api.calls, 1);
      expect(api.accessToken, 'access-token');
      expect(api.profileId, 'kid-1');
      expect(api.storyId, 'story-1');
      expect(api.eventType, StoryActivityType.storyCompleted);
      expect(api.operationId, 'operation-1');
      expect(event.eventId, 'event-1');
    });
  });
}

Map<String, dynamic> _eventJson({bool idempotentReplay = false}) => {
  'event_id': 'event-1',
  'operation_id': '00000000-0000-4000-8000-000000000001',
  'profile_id': 'kid-1',
  'event_type': 'story_started',
  'story_id': 'story-1',
  'recorded_at': '2026-07-17T10:00:00Z',
  'idempotent_replay': idempotentReplay,
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

final class _RecordingProgressApi implements ProgressApi {
  int calls = 0;
  String? accessToken;
  String? profileId;
  String? storyId;
  StoryActivityType? eventType;
  String? operationId;

  @override
  Future<StoryActivityEvent> recordStoryActivity({
    required String accessToken,
    required String profileId,
    required String storyId,
    required StoryActivityType eventType,
    required String operationId,
  }) async {
    calls++;
    this.accessToken = accessToken;
    this.profileId = profileId;
    this.storyId = storyId;
    this.eventType = eventType;
    this.operationId = operationId;
    return StoryActivityEvent.fromJson(_eventJson());
  }
}
