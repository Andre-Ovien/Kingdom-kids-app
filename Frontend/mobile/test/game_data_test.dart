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
import 'package:mobile/features/auth/domain/email_verification.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/data/game_api.dart';
import 'package:mobile/features/games/data/game_repository.dart';
import 'package:mobile/features/games/domain/mini_game.dart';

void main() {
  group('game domain', () {
    test('recognizes every supported backend game type', () {
      for (final type in GameType.values) {
        expect(GameTypeValue.parse(type.name), type);
        expect(type.wireName, type.name);
        expect(type.label, isNotEmpty);
      }
    });

    test('parses kid progress and ordered detail levels', () {
      final game = MiniGame.fromJson({
        'id': 'game-1',
        'slug': 'esther-quiz',
        'title': 'Esther Brave Quiz',
        'subtitle': 'Choose courage',
        'description': 'A gentle Bible quiz.',
        'game_type': 'quiz',
        'cover_asset_key': 'assets/images/esther.jpeg',
        'accent_color': '#7C4DFF',
        'icon_key': 'crown',
        'total_levels': 2,
        'progress': {
          'highest_completed_level': 1,
          'total_stars': 2,
          'max_stars': 6,
          'completed_levels': 1,
          'total_levels': 2,
          'last_played_at': '2026-07-15T08:00:00Z',
        },
        'levels': [
          {
            'id': 'level-2',
            'level_number': 2,
            'title': 'For such a time',
            'instructions': 'Choose the best answer.',
            'max_score': 100,
            'config': {
              'questions': [
                {
                  'id': 'q1',
                  'prompt': 'Who was brave?',
                  'options': [
                    {'id': 'esther', 'text': 'Esther'},
                  ],
                },
              ],
            },
          },
          {
            'id': 'level-1',
            'level_number': 1,
            'title': 'Meet Esther',
            'instructions': 'Tap an answer.',
            'max_score': 100,
            'config': {'questions': <Object>[]},
          },
        ],
      });

      expect(game.slug, 'esther-quiz');
      expect(game.gameType, GameType.quiz);
      expect(game.type, MiniGameType.quiz);
      expect(game.levels.map((level) => level.number), [1, 2]);
      expect(game.level(2)?.config['questions'], isA<List<Object?>>());
      expect(game.currentLevel, 2);
      expect(game.progress, 0.5);
      expect(game.playerProgress.starsEarned, 2);
      expect(game.playerProgress.maxStars, 6);
      expect(game.playerProgress.lastPlayedAt, isNotNull);
      expect(game.rewardStars, 6);
      expect(
        game.coverAssetKey,
        'assets/images/stories/esther-speaks-up-v2.webp',
      );
    });

    test('keeps a backend cover for games outside the canonical catalogue', () {
      final game = MiniGame.fromJson({
        'id': 'custom-game',
        'slug': 'custom-game',
        'title': 'Custom Game',
        'game_type': 'quiz',
        'cover_asset_key': 'assets/images/custom-game.webp',
        'total_levels': 0,
      });

      expect(game.coverAssetKey, 'assets/images/custom-game.webp');
    });

    test('parses authoritative score, reward, and replay metadata', () {
      final submission = GameSubmission.fromJson({
        'attempt_id': 'attempt-1',
        'operation_id': 'operation-1',
        'game_slug': 'esther-quiz',
        'profile_id': 'kid-1',
        'level_number': 1,
        'completed': true,
        'score': 100,
        'max_score': 100,
        'stars': 3,
        'feedback': 'Amazing! Every answer sparkles!',
        'progress': {
          'highest_completed_level': 1,
          'total_stars': 3,
          'max_stars': 6,
          'completed_levels': 1,
          'total_levels': 2,
        },
        'idempotent_replay': true,
      });

      expect(submission.completed, isTrue);
      expect(submission.correct, isTrue);
      expect(submission.score, 100);
      expect(submission.starsAwarded, 3);
      expect(submission.progress.currentLevel, 2);
      expect(submission.idempotentReplay, isTrue);
    });
  });

  group('HttpGameApi', () {
    test('gets profile-scoped catalogue and ordered detail', () async {
      final requests = <http.Request>[];
      final api = HttpGameApi(
        baseUrl: 'https://kingdom-kids.test',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/esther-quiz/')) {
            return http.Response(jsonEncode(_gameJson(withLevels: true)), 200);
          }
          return http.Response(jsonEncode([_gameJson()]), 200);
        }),
      );

      final games = await api.fetchGames('access-token', profileId: 'kid-1');
      final detail = await api.fetchGame(
        'esther-quiz',
        'access-token',
        profileId: 'kid-1',
      );

      expect(games.single.slug, 'esther-quiz');
      expect(detail.levels.single.number, 1);
      expect(requests.first.url.path, '/api/games/');
      expect(requests.first.url.queryParameters, {'profile_id': 'kid-1'});
      expect(requests.last.url.path, '/api/games/esther-quiz/');
      expect(requests.last.url.queryParameters, {'profile_id': 'kid-1'});
      expect(requests.first.headers['authorization'], 'Bearer access-token');
    });

    test('posts exact idempotent result contract and parses reward', () async {
      late http.Request sentRequest;
      final api = HttpGameApi(
        baseUrl: 'https://kingdom-kids.test/api/',
        client: MockClient((request) async {
          sentRequest = request;
          return http.Response(
            jsonEncode({
              'attempt_id': 'attempt-1',
              'operation_id': '9ca98ed0-1bcd-4ef9-8066-adb88e05aee7',
              'game_slug': 'esther-quiz',
              'profile_id': 'kid-1',
              'level_number': 1,
              'completed': true,
              'score': 80,
              'max_score': 100,
              'stars': 2,
              'feedback': 'Great thinking!',
              'progress': {
                'highest_completed_level': 1,
                'total_stars': 2,
                'max_stars': 3,
                'completed_levels': 1,
                'total_levels': 1,
              },
              'idempotent_replay': false,
            }),
            201,
          );
        }),
      );

      final submission = await api.submitResult(
        slug: 'esther-quiz',
        profileId: 'kid-1',
        levelNumber: 1,
        operationId: '9ca98ed0-1bcd-4ef9-8066-adb88e05aee7',
        result: {
          'answers': [
            {'question_id': 'q1', 'option_id': 'a'},
          ],
        },
        accessToken: 'access-token',
      );

      expect(sentRequest.method, 'POST');
      expect(sentRequest.url.path, '/api/games/esther-quiz/submit/');
      expect(sentRequest.url.query, isEmpty);
      expect(sentRequest.headers['authorization'], 'Bearer access-token');
      expect(jsonDecode(sentRequest.body), {
        'profile_id': 'kid-1',
        'level_number': 1,
        'operation_id': '9ca98ed0-1bcd-4ef9-8066-adb88e05aee7',
        'result': {
          'answers': [
            {'question_id': 'q1', 'option_id': 'a'},
          ],
        },
      });
      expect(submission.starsAwarded, 2);
      expect(submission.feedback, 'Great thinking!');
    });

    test('preserves backend status and conflict detail', () async {
      final api = HttpGameApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'detail':
                  'operation_id was already used for a different submission.',
            }),
            409,
          ),
        ),
      );

      await expectLater(
        api.submitResult(
          slug: 'esther-quiz',
          profileId: 'kid-1',
          levelNumber: 1,
          operationId: 'operation-1',
          result: const {},
          accessToken: 'access-token',
        ),
        throwsA(
          isA<AppException>()
              .having((error) => error.statusCode, 'statusCode', 409)
              .having(
                (error) => error.message,
                'message',
                contains('different submission'),
              ),
        ),
      );
    });

    test('extracts the first nested DRF field error', () async {
      final api = HttpGameApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'result': {
                'answers': [
                  {'option_id': <String>[]},
                  'Choose an answer before continuing.',
                ],
              },
            }),
            400,
          ),
        ),
      );

      await expectLater(
        api.submitResult(
          slug: 'esther-quiz',
          profileId: 'kid-1',
          levelNumber: 1,
          operationId: 'operation-1',
          result: const {},
          accessToken: 'access-token',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            'Choose an answer before continuing.',
          ),
        ),
      );
    });

    test(
      'uses a save-action fallback for an unstructured submit error',
      () async {
        final api = HttpGameApi(
          client: MockClient(
            (_) async =>
                http.Response(jsonEncode({'code': 'service_busy'}), 503),
          ),
        );

        await expectLater(
          api.submitResult(
            slug: 'esther-quiz',
            profileId: 'kid-1',
            levelNumber: 1,
            operationId: 'operation-1',
            result: const {},
            accessToken: 'access-token',
          ),
          throwsA(
            isA<AppException>().having(
              (error) => error.message,
              'message',
              'We could not save this try. Please try again.',
            ),
          ),
        );
      },
    );

    test('maps network failures and timeouts to stable errors', () async {
      final networkApi = HttpGameApi(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      final timeoutApi = HttpGameApi(
        requestTimeout: const Duration(milliseconds: 1),
        client: MockClient((_) => Completer<http.Response>().future),
      );

      await expectLater(
        networkApi.fetchGames('access-token', profileId: 'kid-1'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'network_error',
          ),
        ),
      );
      await expectLater(
        timeoutApi.fetchGames('access-token', profileId: 'kid-1'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'request_timeout',
          ),
        ),
      );
    });
  });

  group('RemoteGameRepository', () {
    test(
      'validates active kid and refreshes one rejected access token',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(
          const AuthSession(
            parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
            accessToken: 'expired-access',
            refreshToken: 'refresh-token',
            profiles: [
              KidProfile(
                id: 'kid-1',
                parentId: 'parent-1',
                displayName: 'Amara',
                avatarKey: 'dove',
              ),
            ],
          ),
        );
        await store.writeSelectedKidId('kid-1');
        final authApi = _RefreshingAuthApi();
        final gameApi = _RefreshAwareGameApi();
        final repository = RemoteGameRepository(
          authRepository: AuthRepository(api: authApi, sessionStore: store),
          api: gameApi,
        );

        final games = await repository.fetchGames(profileId: 'kid-1');

        expect(games.single.slug, 'esther-quiz');
        expect(gameApi.accessTokens, ['expired-access', 'fresh-access']);
        expect(gameApi.profileIds, ['kid-1', 'kid-1']);
        expect(authApi.refreshCalls, 1);
        expect((await store.readSession())?.accessToken, 'fresh-access');
      },
    );

    test('rejects a stale profile before making a game request', () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(
        const AuthSession(
          parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
          accessToken: 'access-token',
          profiles: [
            KidProfile(
              id: 'kid-1',
              parentId: 'parent-1',
              displayName: 'Amara',
              avatarKey: 'dove',
            ),
          ],
        ),
      );
      await store.writeSelectedKidId('kid-1');
      final gameApi = _RefreshAwareGameApi();
      final repository = RemoteGameRepository(
        authRepository: AuthRepository(sessionStore: store),
        api: gameApi,
      );

      await expectLater(
        repository.fetchGames(profileId: 'kid-2'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'active_kid_changed',
          ),
        ),
      );
      expect(gameApi.accessTokens, isEmpty);
    });
  });
}

Map<String, dynamic> _gameJson({bool withLevels = false}) => {
  'id': 'game-1',
  'slug': 'esther-quiz',
  'title': 'Esther Brave Quiz',
  'subtitle': 'Choose courage',
  'description': 'A gentle Bible quiz.',
  'game_type': 'quiz',
  'cover_asset_key': 'assets/images/esther.jpeg',
  'accent_color': '#7C4DFF',
  'icon_key': 'crown',
  'total_levels': 1,
  'progress': {
    'highest_completed_level': 0,
    'total_stars': 0,
    'max_stars': 3,
    'completed_levels': 0,
    'total_levels': 1,
    'last_played_at': null,
  },
  if (withLevels)
    'levels': [
      {
        'id': 'level-1',
        'level_number': 1,
        'title': 'Meet Esther',
        'instructions': 'Choose an answer.',
        'max_score': 100,
        'config': {
          'questions': [
            {
              'id': 'q1',
              'prompt': 'Who was brave?',
              'options': [
                {'id': 'a', 'text': 'Esther'},
              ],
            },
          ],
        },
      },
    ],
};

final class _RefreshAwareGameApi implements GameApi {
  final accessTokens = <String>[];
  final profileIds = <String>[];

  @override
  Future<List<MiniGame>> fetchGames(
    String accessToken, {
    required String profileId,
  }) async {
    accessTokens.add(accessToken);
    profileIds.add(profileId);
    if (accessToken == 'expired-access') {
      throw const AppException('Expired.', statusCode: 401);
    }
    return [MiniGame.fromJson(_gameJson())];
  }

  @override
  Future<MiniGame> fetchGame(
    String slug,
    String accessToken, {
    required String profileId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
    required String accessToken,
  }) {
    throw UnimplementedError();
  }
}

final class _RefreshingAuthApi implements AuthApi {
  int refreshCalls = 0;

  @override
  Future<AuthSession> refresh(AuthSession session) async {
    refreshCalls++;
    return session.copyWith(
      accessToken: 'fresh-access',
      refreshToken: 'fresh-refresh',
    );
  }

  @override
  Future<KidProfile> createKidProfile(
    CreateKidProfileRequest request,
    String accessToken,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<ParentAccount> currentParent(String accessToken) {
    throw UnimplementedError();
  }

  @override
  Future<List<KidProfile>> fetchKidProfiles(String accessToken) {
    throw UnimplementedError();
  }

  @override
  Future<KidProfile> retrieveKidProfile(String profileId, String accessToken) {
    throw UnimplementedError();
  }

  @override
  Future<KidProfile> updateKidProfile({
    required String profileId,
    required String displayName,
    required String avatarKey,
    required String accessToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> login(LoginRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PendingEmailVerification> register(RegisterParentRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<PendingEmailVerification> resendEmailVerification(String challengeId) {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> verifyEmail(VerifyEmailRequest request) {
    throw UnimplementedError();
  }
}
