import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/data/game_api.dart';
import 'package:mobile/features/games/data/game_repository.dart';

import 'package:mobile/features/progress/data/progress_api.dart';
import 'package:mobile/features/progress/data/progress_repository.dart';
import 'package:mobile/features/progress/domain/story_activity_event.dart';
import 'package:mobile/features/streak/data/streak_api.dart';
import 'package:mobile/features/streak/data/streak_repository.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_api.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/data/parent_settings_store.dart';

void main() {
  test(
    'idempotent profile-create replay keeps one saved child identity',
    () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session.copyWith(profiles: const []));
      final sentOperations = <String>[];
      final repository = _repository(store, (request) async {
        expect(request.url.path, '/api/accounts/kid-profiles/');
        sentOperations.add(
          (jsonDecode(request.body) as Map)['operation_id'] as String,
        );
        return http.Response(
          jsonEncode(_ada.toJson()),
          sentOperations.length == 1 ? 201 : 200,
        );
      });

      await repository.createKidProfile(_create);
      await repository.createKidProfile(_create);

      expect(sentOperations, [_create.operationId, _create.operationId]);
      expect(
        (await store.readSession())!.profiles.map((profile) => profile.id),
        [_ada.id],
      );
      expect((await repository.currentKid())!.id, _ada.id);
    },
  );

  test(
    'profile-create replay repairs only that ID and preserves sibling order',
    () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(
        _session.copyWith(profiles: const [_ada, _sibling, _ada]),
      );
      final repository = _repository(
        store,
        (_) async => http.Response(jsonEncode(_ada.toJson()), 200),
      );

      await repository.createKidProfile(_create);

      final profiles = (await store.readSession())!.profiles;
      expect(profiles.map((profile) => profile.id), [_ada.id, _sibling.id]);
      // Names can legitimately match. Identity, rather than name, is the key.
      expect(profiles.map((profile) => profile.displayName), ['Ada', 'Ada']);
    },
  );

  for (final scenario in [
    'other-parent',
    'same-parent',
    'initially-signed-out',
  ]) {
    test(
      'delayed reset preserves a fresh $scenario sign-in and selection',
      () async {
        final store = MemoryAuthSessionStore();
        if (scenario != 'initially-signed-out') {
          await store.writeSession(_session);
          await store.writeSelectedKidId(_ada.id);
        }
        final started = Completer<void>();
        final release = Completer<void>();
        final resetting = _repository(store, (request) async {
          expect(request.url.path, '/api/accounts/password-reset/confirm/');
          started.complete();
          await release.future;
          return http.Response('', 204);
        });
        final selected = scenario == 'same-parent' ? _ada : _otherChild;
        final parent = scenario == 'same-parent'
            ? _session.parent
            : _otherParent;
        final signingIn = _repository(store, (request) async {
          expect(request.url.path, '/api/accounts/login/');
          return http.Response(
            jsonEncode({
              'user': parent.toJson(),
              'access': 'fresh-access-$scenario',
              'refresh': 'fresh-refresh-$scenario',
              'profiles': [selected.toJson()],
            }),
            200,
          );
        });

        final reset = resetting.confirmPasswordReset(_reset);
        await started.future;
        await signingIn.login(
          LoginRequest(
            email: parent.email,
            password: 'New-strong-parent-password-2026!',
          ),
        );
        await signingIn.selectKid(selected);
        release.complete();
        await reset;

        final active = await store.readSession();
        expect(active?.parent.id, parent.id);
        expect(active?.accessToken, 'fresh-access-$scenario');
        expect(active?.refreshToken, 'fresh-refresh-$scenario');
        expect((await signingIn.currentKid())?.id, selected.id);
      },
    );
  }
  final writes =
      <
        String,
        ({
          String path,
          Future<Object?> Function(AuthRepository, http.Client) save,
        })
      >{
        'game save': (
          path: '/api/games/esther-quiz/submit/',
          save: (auth, client) =>
              RemoteGameRepository(
                authRepository: auth,
                api: HttpGameApi(baseUrl: _baseUrl, client: client),
              ).submitResult(
                slug: 'esther-quiz',
                profileId: _ada.id,
                levelNumber: 1,
                operationId: _create.operationId,
                result: const {'answers': []},
              ),
        ),
        'story activity': (
          path: '/api/progress/kid-profiles/kid-a/activity-events/',
          save: (auth, client) =>
              RemoteProgressRepository(
                authRepository: auth,
                api: HttpProgressApi(baseUrl: _baseUrl, client: client),
              ).recordStoryActivity(
                profileId: _ada.id,
                storyId: 'story-a',
                eventType: StoryActivityType.storyCompleted,
                operationId: _create.operationId,
              ),
        ),
        'streak claim': (
          path: '/api/progress/kid-profiles/kid-a/streak-presentations/claim/',
          save: (auth, client) => RemoteStreakRepository(
            authRepository: auth,
            api: HttpStreakApi(baseUrl: _baseUrl, client: client),
          ).claimPresentation(profileId: _ada.id),
        ),
        'preference update': (
          path: '/api/accounts/kid-profiles/kid-a/preferences/',
          save: (auth, client) => RemoteParentalControlsRepository(
            authRepository: auth,
            api: HttpParentalControlsApi(baseUrl: _baseUrl, client: client),
            settingsStore: MemoryParentSettingsStore(),
          ).updateSettings(profileId: _ada.id, narrationEnabled: false),
        ),
      };
  for (final entry in writes.entries) {
    test(
      'a ${entry.key} is not replayed for the old child after a refresh-time switch',
      () => _rejectStaleWriteReplay(entry.value.path, entry.value.save),
    );
    test(
      'a committed ${entry.key} succeeds after a later child switch',
      () =>
          _acceptCommittedWriteAfterSwitch(entry.value.path, entry.value.save),
    );
  }
  final reads =
      <
        String,
        ({
          String path,
          Future<Object?> Function(AuthRepository, http.Client) load,
        })
      >{
        'game catalogue': (
          path: '/api/games/',
          load: (auth, client) => RemoteGameRepository(
            authRepository: auth,
            api: HttpGameApi(baseUrl: _baseUrl, client: client),
          ).fetchGames(profileId: _ada.id),
        ),
        'game detail': (
          path: '/api/games/esther-quiz/',
          load: (auth, client) => RemoteGameRepository(
            authRepository: auth,
            api: HttpGameApi(baseUrl: _baseUrl, client: client),
          ).fetchGame('esther-quiz', profileId: _ada.id),
        ),
      };
  for (final entry in reads.entries) {
    test(
      'a ${entry.key} read is not replayed for the old child after a refresh-time switch',
      () => _rejectStaleWriteReplay(entry.value.path, entry.value.load),
    );
  }
}

Future<void> _rejectStaleWriteReplay(
  String path,
  Future<Object?> Function(AuthRepository, http.Client) save,
) async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(_session.copyWith(profiles: const [_ada, _sibling]));
  await store.writeSelectedKidId(_ada.id);
  final refreshStarted = Completer<void>();
  final releaseRefresh = Completer<void>();
  final auth = _repository(store, (request) async {
    expect(request.url.path, '/api/accounts/token/refresh/');
    refreshStarted.complete();
    await releaseRefresh.future;
    return http.Response(
      jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
      200,
    );
  });
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    expect(request.url.path, path);
    requests.add(request);
    if (request.headers['authorization'] == 'Bearer old-access') {
      return http.Response(jsonEncode({'detail': 'Expired access.'}), 401);
    }
    return http.Response(
      jsonEncode({
        'code': 'stale_profile_posted',
        'detail': 'Old child must not be posted again.',
      }),
      400,
    );
  });
  Object? failure;
  final saving = save(auth, client).then<void>(
    (_) {},
    onError: (Object error) {
      failure = error;
    },
  );
  await refreshStarted.future;
  await auth.selectKid(_sibling);
  releaseRefresh.complete();
  await saving;

  expect(
    requests,
    hasLength(1),
    reason:
        'The rejected original request must not be dispatched again after the child changes.',
  );
  expect(
    failure,
    isA<AppException>().having(
      (error) => error.code,
      'code',
      'active_kid_changed',
    ),
  );
  expect((await auth.currentKid())!.id, _sibling.id);
}

const _baseUrl = 'https://kingdom-kids.test/api';

Future<void> _acceptCommittedWriteAfterSwitch(
  String path,
  Future<Object?> Function(AuthRepository, http.Client) save,
) async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(_session.copyWith(profiles: const [_ada, _sibling]));
  await store.writeSelectedKidId(_ada.id);
  final auth = _repository(
    store,
    (_) async => throw StateError('A successful write needs no refresh.'),
  );
  final started = Completer<void>();
  final release = Completer<void>();
  var requests = 0;
  final client = MockClient((request) async {
    expect(request.url.path, path);
    requests++;
    started.complete();
    await release.future;
    return http.Response(jsonEncode(_committedResponse(path)), 200);
  });
  final saving = save(auth, client);
  await started.future;
  await auth.selectKid(_sibling);
  release.complete();

  expect(await saving, isNotNull);
  expect(requests, 1);
  expect((await auth.currentKid())!.id, _sibling.id);
}

Map<String, Object?> _committedResponse(String path) {
  if (path.contains('/games/')) {
    return {
      'attempt_id': 'attempt-a',
      'operation_id': _create.operationId,
      'game_slug': 'esther-quiz',
      'profile_id': _ada.id,
      'level_number': 1,
      'completed': true,
      'score': 10,
      'max_score': 10,
      'stars': 3,
      'progress': {
        'profile_id': _ada.id,
        'total_levels': 1,
        'completed_levels': 1,
      },
    };
  }
  if (path.endsWith('/activity-events/')) {
    return {
      'event_id': 'event-a',
      'operation_id': _create.operationId,
      'profile_id': _ada.id,
      'story_id': 'story-a',
      'event_type': 'story_completed',
      'recorded_at': '2026-11-11T12:00:00Z',
      'idempotent_replay': false,
    };
  }
  if (path.endsWith('/claim/')) return {'show': false};
  return {
    'profile_id': _ada.id,
    'story_text_scale': 'comfortable',
    'narration_enabled': false,
    'updated_at': '2026-11-11T12:00:00Z',
  };
}

AuthRepository _repository(
  MemoryAuthSessionStore store,
  MockClientHandler handler,
) => AuthRepository(
  sessionStore: store,
  api: HttpAuthApi(
    baseUrl: 'https://kingdom-kids.test/api',
    client: MockClient(handler),
  ),
);

const _ada = KidProfile(
  id: 'kid-a',
  parentId: 'parent-a',
  displayName: 'Ada',
  avatarKey: 'lion',
);
const _sibling = KidProfile(
  id: 'kid-a-sibling',
  parentId: 'parent-a',
  displayName: 'Ada',
  avatarKey: 'dove',
);
const _otherParent = ParentAccount(id: 'parent-b', email: 'other@example.test');
const _otherChild = KidProfile(
  id: 'kid-b',
  parentId: 'parent-b',
  displayName: 'Grace',
  avatarKey: 'dove',
);
const _session = AuthSession(
  parent: ParentAccount(id: 'parent-a', email: 'parent@example.test'),
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
  profiles: [_ada],
);
const _create = CreateKidProfileRequest(
  displayName: 'Ada',
  avatarKey: 'lion',
  operationId: '00000000-0000-4000-8000-000000000001',
);
const _reset = PasswordResetConfirmRequest(
  challengeId: '11111111-1111-4111-8111-111111111111',
  code: '123456',
  newPassword: 'New-strong-parent-password-2026!',
  newPasswordConfirmation: 'New-strong-parent-password-2026!',
);
