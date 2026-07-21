import 'dart:async';
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
import 'package:mobile/features/parental_controls/data/parental_controls_api.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/domain/parent_settings.dart';

void main() {
  group('ParentSettings', () {
    test('parses and serializes the exact typed preferences contract', () {
      final settings = ParentSettings.fromJson(_settingsJson());

      expect(settings.profileId, 'kid-1');
      expect(settings.storyTextScale, StoryTextScale.extraLarge);
      expect(settings.storyTextScale.wireValue, 'extra_large');
      expect(settings.storyTextScale.label, 'Extra large');
      expect(settings.narrationEnabled, isFalse);
      expect(settings.updatedAt, DateTime.parse('2026-07-15T14:30:00Z'));
      expect(settings.toJson(), _settingsJson());
      expect(StoryTextScale.values.map((scale) => scale.wireValue), [
        'comfortable',
        'large',
        'extra_large',
      ]);
    });

    test('rejects unknown backend text scale values', () {
      expect(
        () => ParentSettings.fromJson({
          ..._settingsJson(),
          'story_text_scale': 'enormous',
        }),
        throwsFormatException,
      );
    });
  });

  group('HttpParentalControlsApi', () {
    test('GET uses the exact profile URL and bearer token', () async {
      late http.Request sentRequest;
      final api = HttpParentalControlsApi(
        baseUrl: 'https://kingdom-kids.test',
        client: MockClient((request) async {
          sentRequest = request;
          return http.Response(jsonEncode(_settingsJson()), 200);
        }),
      );

      final settings = await api.fetchSettings(
        accessToken: 'access-token',
        profileId: 'kid-1',
      );

      expect(sentRequest.method, 'GET');
      expect(
        sentRequest.url,
        Uri.parse(
          'https://kingdom-kids.test/api/accounts/kid-profiles/kid-1/preferences/',
        ),
      );
      expect(sentRequest.headers['accept'], 'application/json');
      expect(sentRequest.headers['authorization'], 'Bearer access-token');
      expect(sentRequest.headers.containsKey('content-type'), isFalse);
      expect(settings.storyTextScale, StoryTextScale.extraLarge);
    });

    test('PATCH sends only the optional fields provided', () async {
      final requests = <http.Request>[];
      final api = HttpParentalControlsApi(
        baseUrl: 'https://kingdom-kids.test/api/',
        client: MockClient((request) async {
          requests.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              ..._settingsJson(),
              if (body['story_text_scale'] != null)
                'story_text_scale': body['story_text_scale'],
              if (body['narration_enabled'] != null)
                'narration_enabled': body['narration_enabled'],
            }),
            200,
          );
        }),
      );

      await api.updateSettings(
        accessToken: 'access-token',
        profileId: 'kid-1',
        storyTextScale: StoryTextScale.large,
      );
      await api.updateSettings(
        accessToken: 'access-token',
        profileId: 'kid-1',
        narrationEnabled: false,
      );

      expect(requests, hasLength(2));
      expect(requests.every((request) => request.method == 'PATCH'), isTrue);
      expect(
        requests.every(
          (request) =>
              request.url.path ==
              '/api/accounts/kid-profiles/kid-1/preferences/',
        ),
        isTrue,
      );
      expect(
        requests.every(
          (request) =>
              request.headers['authorization'] == 'Bearer access-token' &&
              request.headers['content-type'] == 'application/json',
        ),
        isTrue,
      );
      expect(jsonDecode(requests.first.body), {'story_text_scale': 'large'});
      expect(jsonDecode(requests.last.body), {'narration_enabled': false});
    });

    test('rejects an empty PATCH without touching the network', () async {
      var calls = 0;
      final api = HttpParentalControlsApi(
        client: MockClient((_) async {
          calls += 1;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        api.updateSettings(accessToken: 'access-token', profileId: 'kid-1'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'empty_preferences_update',
          ),
        ),
      );
      expect(calls, 0);
    });

    test('preserves nested backend validation details and status', () async {
      final api = HttpParentalControlsApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'story_text_scale': ['Choose a valid text size.'],
              'code': 'invalid_text_scale',
            }),
            400,
          ),
        ),
      );

      await expectLater(
        api.updateSettings(
          accessToken: 'access-token',
          profileId: 'kid-1',
          storyTextScale: StoryTextScale.large,
        ),
        throwsA(
          isA<AppException>()
              .having(
                (error) => error.message,
                'message',
                'Choose a valid text size.',
              )
              .having((error) => error.statusCode, 'statusCode', 400)
              .having((error) => error.code, 'code', 'invalid_text_scale')
              .having((error) => error.details['story_text_scale'], 'details', [
                'Choose a valid text size.',
              ]),
        ),
      );
    });

    test('maps incomplete responses, timeouts, and network failures', () async {
      final incompleteApi = HttpParentalControlsApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({..._settingsJson(), 'story_text_scale': 'gigantic'}),
            200,
          ),
        ),
      );
      final timeoutApi = HttpParentalControlsApi(
        requestTimeout: const Duration(milliseconds: 1),
        client: MockClient((_) => Completer<http.Response>().future),
      );
      final networkApi = HttpParentalControlsApi(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );

      await expectLater(
        incompleteApi.fetchSettings(
          accessToken: 'access-token',
          profileId: 'kid-1',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'invalid_preferences_response',
          ),
        ),
      );
      await expectLater(
        timeoutApi.fetchSettings(
          accessToken: 'access-token',
          profileId: 'kid-1',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'request_timeout',
          ),
        ),
      );
      await expectLater(
        networkApi.fetchSettings(
          accessToken: 'access-token',
          profileId: 'kid-1',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'network_error',
          ),
        ),
      );
    });
  });

  group('RemoteParentalControlsRepository', () {
    test('requires a selected child before calling the API', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session());
      final api = _RecordingParentalControlsApi();
      final repository = RemoteParentalControlsRepository(
        authRepository: AuthRepository(sessionStore: store),
        api: api,
      );

      await expectLater(
        repository.fetchSettings(profileId: 'kid-1'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'active_kid_required',
          ),
        ),
      );
      expect(api.fetchCalls, 0);
    });

    test('rejects a stale profile ID before calling the API', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session());
      await store.writeSelectedKidId('kid-1');
      final api = _RecordingParentalControlsApi();
      final repository = RemoteParentalControlsRepository(
        authRepository: AuthRepository(sessionStore: store),
        api: api,
      );

      await expectLater(
        repository.updateSettings(profileId: 'kid-2', narrationEnabled: false),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'active_kid_changed',
          ),
        ),
      );
      expect(api.updateCalls, 0);
    });

    test(
      'delegates GET and PATCH with the current authenticated child',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session());
        await store.writeSelectedKidId('kid-1');
        final api = _RecordingParentalControlsApi();
        final repository = RemoteParentalControlsRepository(
          authRepository: AuthRepository(sessionStore: store),
          api: api,
        );

        final fetched = await repository.fetchSettings(profileId: ' kid-1 ');
        final updated = await repository.updateSettings(
          profileId: 'kid-1',
          storyTextScale: StoryTextScale.extraLarge,
          narrationEnabled: false,
        );

        expect(fetched.profileId, 'kid-1');
        expect(updated.profileId, 'kid-1');
        expect(api.fetchCalls, 1);
        expect(api.updateCalls, 1);
        expect(api.accessTokens, ['access-token', 'access-token']);
        expect(api.profileIds, ['kid-1', 'kid-1']);
        expect(api.updatedScale, StoryTextScale.extraLarge);
        expect(api.updatedNarration, isFalse);
      },
    );
  });
}

Map<String, dynamic> _settingsJson() => {
  'profile_id': 'kid-1',
  'story_text_scale': 'extra_large',
  'narration_enabled': false,
  'updated_at': '2026-07-15T14:30:00.000Z',
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
      avatarKey: 'dove',
    ),
  ],
);

ParentSettings _settings({
  StoryTextScale storyTextScale = StoryTextScale.comfortable,
  bool narrationEnabled = true,
}) => ParentSettings(
  profileId: 'kid-1',
  storyTextScale: storyTextScale,
  narrationEnabled: narrationEnabled,
  updatedAt: DateTime.utc(2026, 7, 15, 14, 30),
);

final class _RecordingParentalControlsApi implements ParentalControlsApi {
  int fetchCalls = 0;
  int updateCalls = 0;
  final List<String> accessTokens = [];
  final List<String> profileIds = [];
  StoryTextScale? updatedScale;
  bool? updatedNarration;

  @override
  Future<ParentSettings> fetchSettings({
    required String accessToken,
    required String profileId,
  }) async {
    fetchCalls += 1;
    accessTokens.add(accessToken);
    profileIds.add(profileId);
    return _settings();
  }

  @override
  Future<ParentSettings> updateSettings({
    required String accessToken,
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  }) async {
    updateCalls += 1;
    accessTokens.add(accessToken);
    profileIds.add(profileId);
    updatedScale = storyTextScale;
    updatedNarration = narrationEnabled;
    return _settings(
      storyTextScale: storyTextScale ?? StoryTextScale.comfortable,
      narrationEnabled: narrationEnabled ?? true,
    );
  }
}
