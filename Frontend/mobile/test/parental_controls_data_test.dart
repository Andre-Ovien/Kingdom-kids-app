import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_api.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/data/parent_settings_store.dart';
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

  group('ParentSettingsStore', () {
    test(
      'purges every parent-settings key but preserves unrelated storage',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'unrelated.plugin.value': 'keep-me',
        });
        const storage = FlutterSecureStorage();
        final store = SecureParentSettingsStore(storage: storage);
        await store.writeSettings(_settings(profileId: 'kid-1'));
        await store.writeSettings(_settings(profileId: 'kid-2'));

        await store.purgeAll();

        expect(await store.readSettings(profileId: 'kid-1'), isNull);
        expect(await store.readSettings(profileId: 'kid-2'), isNull);
        expect(await storage.read(key: 'unrelated.plugin.value'), 'keep-me');
      },
    );
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
        final settingsStore = MemoryParentSettingsStore();
        final repository = RemoteParentalControlsRepository(
          authRepository: AuthRepository(sessionStore: store),
          api: api,
          settingsStore: settingsStore,
        );

        final fetched = await repository.fetchSettings(profileId: ' kid-1 ');
        final fetchedCache = await settingsStore.readSettings(
          profileId: 'kid-1',
        );
        final updated = await repository.updateSettings(
          profileId: 'kid-1',
          storyTextScale: StoryTextScale.extraLarge,
          narrationEnabled: false,
        );
        final updatedCache = await settingsStore.readSettings(
          profileId: 'kid-1',
        );

        expect(fetched.profileId, 'kid-1');
        expect(fetchedCache, same(fetched));
        expect(updated.profileId, 'kid-1');
        expect(updatedCache, same(updated));
        expect(api.fetchCalls, 1);
        expect(api.updateCalls, 1);
        expect(api.accessTokens, ['access-token', 'access-token']);
        expect(api.profileIds, ['kid-1', 'kid-1']);
        expect(api.updatedScale, StoryTextScale.extraLarge);
        expect(api.updatedNarration, isFalse);
      },
    );

    test('fails closed when the first settings fetch is offline', () async {
      final api = _RecordingParentalControlsApi()
        ..fetchError = const AppException(
          'No connection.',
          code: 'network_error',
        );
      final repository = await _authenticatedRepository(
        api: api,
        settingsStore: MemoryParentSettingsStore(),
      );

      await expectLater(
        repository.fetchSettings(profileId: 'kid-1'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'network_error',
          ),
        ),
      );
      expect(api.fetchCalls, 1);
    });

    test('returns the last server-confirmed settings while offline', () async {
      final api = _RecordingParentalControlsApi()
        ..fetchResult = _settings(
          storyTextScale: StoryTextScale.large,
          narrationEnabled: true,
        );
      final settingsStore = MemoryParentSettingsStore();
      final repository = await _authenticatedRepository(
        api: api,
        settingsStore: settingsStore,
      );

      final onlineSettings = await repository.fetchSettings(profileId: 'kid-1');
      // Exercise the durable fallback after the short-lived read cache is gone.
      featureReadCache.invalidate();
      api.fetchError = const AppException(
        'No connection.',
        code: 'network_error',
      );
      final offlineSettings = await repository.fetchSettings(
        profileId: 'kid-1',
      );

      expect(offlineSettings, same(onlineSettings));
      expect(offlineSettings.storyTextScale, StoryTextScale.large);
      expect(offlineSettings.narrationEnabled, isTrue);
      expect(api.fetchCalls, 2);
    });

    test('uses the last server-confirmed settings after a timeout', () async {
      final cached = _settings(
        storyTextScale: StoryTextScale.extraLarge,
        narrationEnabled: false,
      );
      final api = _RecordingParentalControlsApi()
        ..fetchError = const AppException(
          'Timed out.',
          code: 'request_timeout',
        );
      final repository = await _authenticatedRepository(
        api: api,
        settingsStore: MemoryParentSettingsStore(
          initialSettings: {'kid-1': cached},
        ),
      );

      final settings = await repository.fetchSettings(profileId: 'kid-1');

      expect(settings, same(cached));
    });

    test(
      'never falls back for permission, validation, or malformed responses',
      () async {
        final cached = _settings();
        final api = _RecordingParentalControlsApi();
        final repository = await _authenticatedRepository(
          api: api,
          settingsStore: MemoryParentSettingsStore(
            initialSettings: {'kid-1': cached},
          ),
        );
        final errors = <AppException>[
          const AppException(
            'A parent needs to help with that.',
            code: 'permission_denied',
            statusCode: 403,
          ),
          const AppException(
            'Choose a valid text size.',
            code: 'invalid_text_scale',
            statusCode: 400,
          ),
          const AppException(
            'The preferences service sent an incomplete response.',
            code: 'invalid_preferences_response',
          ),
        ];

        for (final error in errors) {
          api.fetchError = error;
          await expectLater(
            repository.fetchSettings(profileId: 'kid-1'),
            throwsA(same(error)),
          );
        }
      },
    );

    test('never falls back when there is no active parent session', () async {
      final api = _RecordingParentalControlsApi()
        ..fetchError = const AppException(
          'No connection.',
          code: 'network_error',
        );
      final repository = RemoteParentalControlsRepository(
        authRepository: AuthRepository(sessionStore: MemoryAuthSessionStore()),
        api: api,
        settingsStore: MemoryParentSettingsStore(
          initialSettings: {'kid-1': _settings()},
        ),
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

    test('ignores cached settings belonging to another profile', () async {
      final networkError = const AppException(
        'No connection.',
        code: 'network_error',
      );
      final api = _RecordingParentalControlsApi()..fetchError = networkError;
      final repository = await _authenticatedRepository(
        api: api,
        settingsStore: MemoryParentSettingsStore(
          initialSettings: {'kid-1': _settings(profileId: 'kid-2')},
        ),
      );

      await expectLater(
        repository.fetchSettings(profileId: 'kid-1'),
        throwsA(same(networkError)),
      );
    });

    test('cache read failures preserve the connectivity failure', () async {
      final timeoutError = const AppException(
        'Timed out.',
        code: 'request_timeout',
      );
      final api = _RecordingParentalControlsApi()..fetchError = timeoutError;
      final repository = await _authenticatedRepository(
        api: api,
        settingsStore: _ThrowingParentSettingsStore(throwOnRead: true),
      );

      await expectLater(
        repository.fetchSettings(profileId: 'kid-1'),
        throwsA(same(timeoutError)),
      );
    });

    test('cache write failures never hide a successful fetch', () async {
      final expected = _settings(
        storyTextScale: StoryTextScale.large,
        narrationEnabled: false,
      );
      final api = _RecordingParentalControlsApi()..fetchResult = expected;
      final repository = await _authenticatedRepository(
        api: api,
        settingsStore: _ThrowingParentSettingsStore(throwOnWrite: true),
      );

      final settings = await repository.fetchSettings(profileId: 'kid-1');

      expect(settings, same(expected));
    });

    test(
      'an offline update still fails instead of claiming cached success',
      () async {
        final networkError = const AppException(
          'No connection.',
          code: 'network_error',
        );
        final api = _RecordingParentalControlsApi()..updateError = networkError;
        final cached = _settings();
        final repository = await _authenticatedRepository(
          api: api,
          settingsStore: MemoryParentSettingsStore(
            initialSettings: {'kid-1': cached},
          ),
        );

        await expectLater(
          repository.updateSettings(
            profileId: 'kid-1',
            narrationEnabled: false,
          ),
          throwsA(same(networkError)),
        );
      },
    );

    test(
      'a mismatched network response is rejected and never cached',
      () async {
        final settingsStore = MemoryParentSettingsStore();
        final api = _RecordingParentalControlsApi()
          ..fetchResult = _settings(profileId: 'kid-2');
        final repository = await _authenticatedRepository(
          api: api,
          settingsStore: settingsStore,
        );

        await expectLater(
          repository.fetchSettings(profileId: 'kid-1'),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'preferences_profile_changed',
            ),
          ),
        );
        expect(await settingsStore.readSettings(profileId: 'kid-1'), isNull);
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
  String profileId = 'kid-1',
  StoryTextScale storyTextScale = StoryTextScale.comfortable,
  bool narrationEnabled = true,
}) => ParentSettings(
  profileId: profileId,
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
  ParentSettings fetchResult = _settings();
  Object? fetchError;
  Object? updateError;

  @override
  Future<ParentSettings> fetchSettings({
    required String accessToken,
    required String profileId,
  }) async {
    fetchCalls += 1;
    accessTokens.add(accessToken);
    profileIds.add(profileId);
    if (fetchError case final error?) throw error;
    return fetchResult;
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
    if (updateError case final error?) throw error;
    return _settings(
      storyTextScale: storyTextScale ?? StoryTextScale.comfortable,
      narrationEnabled: narrationEnabled ?? true,
    );
  }
}

Future<RemoteParentalControlsRepository> _authenticatedRepository({
  required ParentalControlsApi api,
  required ParentSettingsStore settingsStore,
}) async {
  final authStore = MemoryAuthSessionStore();
  await authStore.writeSession(_session());
  await authStore.writeSelectedKidId('kid-1');
  return RemoteParentalControlsRepository(
    authRepository: AuthRepository(sessionStore: authStore),
    api: api,
    settingsStore: settingsStore,
  );
}

final class _ThrowingParentSettingsStore implements ParentSettingsStore {
  _ThrowingParentSettingsStore({
    this.throwOnRead = false,
    this.throwOnWrite = false,
  });

  final bool throwOnRead;
  final bool throwOnWrite;

  @override
  Future<void> purgeAll() async {}

  @override
  Future<ParentSettings?> readSettings({required String profileId}) async {
    if (throwOnRead) throw StateError('Secure storage read failed.');
    return null;
  }

  @override
  Future<void> writeSettings(ParentSettings settings) async {
    if (throwOnWrite) throw StateError('Secure storage write failed.');
  }
}
