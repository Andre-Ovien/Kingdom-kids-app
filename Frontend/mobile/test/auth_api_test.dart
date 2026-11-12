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

void main() {
  group('HttpAuthApi', () {
    test(
      'registers a parent and reads the pending verification challenge',
      () async {
        late http.Request sentRequest;
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response(
              jsonEncode({
                'verification': {
                  'challenge_id': 'challenge-1',
                  'email': 'parent@example.com',
                  'destination_hint': 'pa••••@example.com',
                  'expires_in': 600,
                  'resend_after': 60,
                },
              }),
              202,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );

        final pending = await api.register(
          const RegisterParentRequest(
            email: 'PARENT@EXAMPLE.COM',
            password: 'Correct-Horse-Battery-Staple-2026!',
          ),
        );

        expect(sentRequest.method, 'POST');
        expect(
          sentRequest.url,
          Uri.parse('https://kingdom-kids.test/api/accounts/register/'),
        );
        expect(jsonDecode(sentRequest.body), {
          'email': 'parent@example.com',
          'password': 'Correct-Horse-Battery-Staple-2026!',
          'password_confirmation': 'Correct-Horse-Battery-Staple-2026!',
        });
        expect(pending.challengeId, 'challenge-1');
        expect(pending.email, 'parent@example.com');
        expect(pending.destinationHint, 'pa••••@example.com');
        expect(pending.expiresInSeconds, 600);
      },
    );

    test('keeps a delayed email challenge recoverable', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'code': 'verification_delivery_delayed',
              'verification_delivery_delayed': true,
              'verification': {
                'challenge_id': 'replacement-challenge',
                'email': 'parent@example.com',
                'destination_hint': 'pa••••@example.com',
                'expires_in': 600,
                'resend_after': 0,
              },
            }),
            202,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );

      final pending = await api.register(
        const RegisterParentRequest(
          email: 'parent@example.com',
          password: 'Correct-Horse-Battery-Staple-2026!',
        ),
      );

      expect(pending.challengeId, 'replacement-challenge');
      expect(pending.resendAfterSeconds, 0);
      expect(pending.deliveryDelayed, isTrue);
    });

    test('maps a raw login rejection to approved family-facing copy', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'detail':
                  'No active account found with the given credentials: HTTP 401',
            }),
            401,
          ),
        ),
      );

      await expectLater(
        api.login(
          const LoginRequest(
            email: 'parent@example.com',
            password: 'not-the-password',
          ),
        ),
        throwsA(
          isA<AppException>()
              .having((error) => error.code, 'code', 'invalid_credentials')
              .having(
                (error) => error.userMessage,
                'userMessage',
                'That email or password did not match our records.',
              ),
        ),
      );
    });

    test('confirms and resends an email verification challenge', () async {
      final requests = <http.Request>[];
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('confirm/')) {
            return http.Response(
              jsonEncode({
                'user': {
                  'id': 42,
                  'email': 'parent@example.com',
                  'kid_profiles': [],
                },
                'access': 'access-token',
                'refresh': 'refresh-token',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'verification': {
                'challenge_id': 'challenge-2',
                'email': 'parent@example.com',
                'destination_hint': 'pa••••@example.com',
                'expires_in': 600,
                'resend_after': 60,
              },
            }),
            202,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final session = await api.verifyEmail(
        const VerifyEmailRequest(challengeId: 'challenge-1', code: '123456'),
      );
      final pending = await api.resendEmailVerification('challenge-1');

      expect(session.accessToken, 'access-token');
      expect(pending.challengeId, 'challenge-2');
      expect(jsonDecode(requests.first.body), {
        'challenge_id': 'challenge-1',
        'code': '123456',
      });
      expect(jsonDecode(requests.last.body), {'challenge_id': 'challenge-1'});
    });

    test(
      'requests password recovery at the exact destination with normalized email',
      () async {
        late http.Request sentRequest;
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response(
              jsonEncode({
                'detail':
                    'If an eligible account exists for that email, a password reset code has been sent.',
                'challenge_id': '11111111-1111-4111-8111-111111111111',
                'expires_in': 600,
              }),
              202,
            );
          }),
        );

        final pending = await api.requestPasswordReset(
          const PasswordResetRequest(email: '  PARENT@EXAMPLE.COM  '),
        );

        expect(sentRequest.method, 'POST');
        expect(
          sentRequest.url,
          Uri.parse(
            'https://kingdom-kids.test/api/accounts/password-reset/request/',
          ),
        );
        expect(sentRequest.headers.containsKey('authorization'), isFalse);
        expect(jsonDecode(sentRequest.body), {'email': 'parent@example.com'});
        expect(pending.challengeId, '11111111-1111-4111-8111-111111111111');
        expect(pending.expiresInSeconds, 600);
      },
    );

    test(
      'confirms password recovery with every backend field and accepts 204',
      () async {
        late http.Request sentRequest;
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response('', 204);
          }),
        );

        await api.confirmPasswordReset(
          const PasswordResetConfirmRequest(
            challengeId: '11111111-1111-4111-8111-111111111111',
            code: ' 123456 ',
            newPassword: 'New-Correct-Horse-Battery-Staple-2026!',
            newPasswordConfirmation: 'New-Correct-Horse-Battery-Staple-2026!',
          ),
        );

        expect(sentRequest.method, 'POST');
        expect(
          sentRequest.url,
          Uri.parse(
            'https://kingdom-kids.test/api/accounts/password-reset/confirm/',
          ),
        );
        expect(sentRequest.headers.containsKey('authorization'), isFalse);
        expect(jsonDecode(sentRequest.body), {
          'challenge_id': '11111111-1111-4111-8111-111111111111',
          'code': '123456',
          'new_password': 'New-Correct-Horse-Battery-Staple-2026!',
          'new_password_confirmation': 'New-Correct-Horse-Battery-Staple-2026!',
        });
      },
    );

    test('preserves the safe invalid-or-expired reset response', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'code': 'invalid_or_expired_password_reset',
              'detail': 'That password reset code is incorrect or has expired.',
            }),
            400,
          ),
        ),
      );

      await expectLater(
        api.confirmPasswordReset(
          const PasswordResetConfirmRequest(
            challengeId: '11111111-1111-4111-8111-111111111111',
            code: '000000',
            newPassword: 'New-Correct-Horse-Battery-Staple-2026!',
            newPasswordConfirmation: 'New-Correct-Horse-Battery-Staple-2026!',
          ),
        ),
        throwsA(
          isA<AppException>()
              .having(
                (error) => error.code,
                'code',
                'invalid_or_expired_password_reset',
              )
              .having((error) => error.statusCode, 'statusCode', 400)
              .having(
                (error) => error.userMessage,
                'userMessage',
                'That password reset code is incorrect or has expired.',
              ),
        ),
      );
    });

    test(
      'code verification sends no password and preserves local sign-in',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        await store.writeSelectedKidId('kid-1');
        late http.Request sent;
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((request) async {
              sent = request;
              return http.Response('', 204);
            }),
          ),
          sessionStore: store,
        );
        await repository.verifyPasswordResetCode(
          const PasswordResetVerifyRequest(
            challengeId: '11111111-1111-4111-8111-111111111111',
            code: ' 123456 ',
          ),
        );
        expect(sent.method, 'POST');
        expect(sent.url.path, '/api/accounts/password-reset/verify/');
        expect(sent.headers['authorization'], isNull);
        expect(jsonDecode(sent.body), {
          'challenge_id': '11111111-1111-4111-8111-111111111111',
          'code': '123456',
        });
        expect(
          (await store.readSession())?.accessToken,
          _oldSession.accessToken,
        );
        expect(await store.readSelectedKidId(), 'kid-1');
      },
    );

    test(
      'an incorrect verification code stays a retryable recovery error',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        await store.writeSelectedKidId('kid-1');
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'code': 'invalid_or_expired_password_reset',
                  'detail':
                      'That password reset code is incorrect or has expired.',
                }),
                400,
              ),
            ),
          ),
          sessionStore: store,
        );
        await expectLater(
          repository.verifyPasswordResetCode(
            const PasswordResetVerifyRequest(
              challengeId: '11111111-1111-4111-8111-111111111111',
              code: '000000',
            ),
          ),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'invalid_or_expired_password_reset',
            ),
          ),
        );
        expect(
          (await store.readSession())?.accessToken,
          _oldSession.accessToken,
        );
        expect(await store.readSelectedKidId(), 'kid-1');
      },
    );

    test(
      'successful password recovery clears stale local auth state',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        await store.writeSelectedKidId('kid-1');
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((_) async => http.Response('', 204)),
          ),
          sessionStore: store,
        );

        await repository.confirmPasswordReset(
          const PasswordResetConfirmRequest(
            challengeId: '11111111-1111-4111-8111-111111111111',
            code: '123456',
            newPassword: 'New-Correct-Horse-Battery-Staple-2026!',
            newPasswordConfirmation: 'New-Correct-Horse-Battery-Staple-2026!',
          ),
        );

        expect(await store.readSession(), isNull);
        expect(await store.readSelectedKidId(), isNull);
      },
    );

    test(
      'reads the bare profile list returned by the Django viewset',
      () async {
        late http.Request sentRequest;
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api/',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response(
              jsonEncode([
                {
                  'id': 'kid-1',
                  'display_name': 'Ada Grace',
                  'avatar_key': 'rainbow',
                },
              ]),
              200,
            );
          }),
        );

        final profiles = await api.fetchKidProfiles(
          'access-token',
          expectedParentId: 'parent-1',
        );

        expect(
          sentRequest.url,
          Uri.parse('https://kingdom-kids.test/api/accounts/kid-profiles/'),
        );
        expect(sentRequest.headers['authorization'], 'Bearer access-token');
        expect(profiles.single.displayName, 'Ada Grace');
        expect(profiles.single.avatarKey, 'rainbow');
        expect(profiles.single.parentId, 'parent-1');
      },
    );

    test(
      'rejects malformed or unidentified entries in a profile list',
      () async {
        final responseBodies = [
          jsonEncode([
            {'id': 'kid-1', 'display_name': 'Ada', 'avatar_key': 'dove'},
            'not-a-profile',
          ]),
          jsonEncode([
            {'display_name': 'Ada', 'avatar_key': 'dove'},
          ]),
        ];

        for (final responseBody in responseBodies) {
          final api = HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((_) async => http.Response(responseBody, 200)),
          );

          await expectLater(
            api.fetchKidProfiles('access-token', expectedParentId: 'parent-1'),
            throwsA(
              isA<AppException>().having(
                (error) => error.code,
                'code',
                'invalid_profile_list_response',
              ),
            ),
          );
        }
      },
    );

    test('rejects a profile list entry owned by another parent', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {
                'id': 'kid-1',
                'parent_id': 'parent-2',
                'display_name': 'Ada',
                'avatar_key': 'dove',
              },
            ]),
            200,
          ),
        ),
      );

      await expectLater(
        api.fetchKidProfiles('access-token', expectedParentId: 'parent-1'),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'profile_owner_mismatch',
          ),
        ),
      );
    });

    test('sends the profile creation operation ID to Django', () async {
      late http.Request sentRequest;
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          sentRequest = request;
          return http.Response(
            jsonEncode({
              'id': 'kid-1',
              'display_name': 'Ada',
              'avatar_key': 'dove',
            }),
            201,
          );
        }),
      );

      final profile = await api.createKidProfile(
        const CreateKidProfileRequest(
          displayName: ' Ada ',
          avatarKey: 'dove',
          operationId: '0b44df58-58fa-4a49-9a08-7dcb63a58f6b',
        ),
        'access-token',
      );

      expect(sentRequest.method, 'POST');
      expect(sentRequest.headers['authorization'], 'Bearer access-token');
      expect(jsonDecode(sentRequest.body), {
        'display_name': 'Ada',
        'avatar_key': 'dove',
        'operation_id': '0b44df58-58fa-4a49-9a08-7dcb63a58f6b',
      });
      expect(profile.id, 'kid-1');
    });

    test('rejects a created profile response without an ID', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'display_name': 'Ada', 'avatar_key': 'dove'}),
            201,
          ),
        ),
      );

      await expectLater(
        api.createKidProfile(
          const CreateKidProfileRequest(
            displayName: 'Ada',
            avatarKey: 'dove',
            operationId: '0b44df58-58fa-4a49-9a08-7dcb63a58f6b',
          ),
          'access-token',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'invalid_profile_response',
          ),
        ),
      );
    });

    test(
      'retrieves one owned child profile from the detail endpoint',
      () async {
        late http.Request sentRequest;
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response(
              jsonEncode({
                'id': 'kid-1',
                'display_name': 'Ada',
                'avatar_key': 'dove',
                'created_at': '2026-07-14T10:00:00Z',
                'updated_at': '2026-07-15T11:30:00Z',
              }),
              200,
            );
          }),
        );

        final profile = await api.retrieveKidProfile('kid-1', 'access-token');

        expect(sentRequest.method, 'GET');
        expect(
          sentRequest.url,
          Uri.parse(
            'https://kingdom-kids.test/api/accounts/kid-profiles/kid-1/',
          ),
        );
        expect(sentRequest.headers['authorization'], 'Bearer access-token');
        expect(profile.createdAt, DateTime.utc(2026, 7, 14, 10));
        expect(profile.updatedAt, DateTime.utc(2026, 7, 15, 11, 30));
      },
    );

    test('PATCHes only editable profile identity fields', () async {
      late http.Request sentRequest;
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          sentRequest = request;
          return http.Response(
            jsonEncode({
              'id': 'kid-1',
              'display_name': 'Ada Grace',
              'avatar_key': 'star',
              'created_at': '2026-07-14T10:00:00Z',
              'updated_at': '2026-07-15T12:00:00Z',
            }),
            200,
          );
        }),
      );

      final profile = await api.updateKidProfile(
        profileId: 'kid-1',
        displayName: '  Ada   Grace  ',
        avatarKey: ' star ',
        accessToken: 'access-token',
      );

      expect(sentRequest.method, 'PATCH');
      expect(
        sentRequest.url,
        Uri.parse('https://kingdom-kids.test/api/accounts/kid-profiles/kid-1/'),
      );
      expect(sentRequest.headers['authorization'], 'Bearer access-token');
      expect(sentRequest.headers['content-type'], 'application/json');
      expect(jsonDecode(sentRequest.body), {
        'display_name': 'Ada Grace',
        'avatar_key': 'star',
      });
      expect(profile.displayName, 'Ada Grace');
      expect(profile.updatedAt, DateTime.utc(2026, 7, 15, 12));
    });

    test('preserves PATCH validation errors from Django', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'display_name': ['Display name cannot be blank.'],
            }),
            400,
          ),
        ),
      );

      await expectLater(
        api.updateKidProfile(
          profileId: 'kid-1',
          displayName: ' ',
          avatarKey: 'star',
          accessToken: 'access-token',
        ),
        throwsA(
          isA<AppException>()
              .having((error) => error.statusCode, 'statusCode', 400)
              .having(
                (error) => error.message,
                'message',
                'Display name cannot be blank.',
              ),
        ),
      );
    });

    test('maps a stalled PATCH to a retryable timeout error', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((_) async => throw TimeoutException('stalled')),
      );

      await expectLater(
        api.updateKidProfile(
          profileId: 'kid-1',
          displayName: 'Ada',
          avatarKey: 'star',
          accessToken: 'access-token',
        ),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'request_timeout',
          ),
        ),
      );
    });

    test(
      'refreshCurrentKid refreshes a 401 and resolves the fresh selection',
      () async {
        final requests = <http.Request>[];
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('token/refresh/')) {
              return http.Response(
                jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
                200,
              );
            }
            if (request.headers['authorization'] == 'Bearer old-access') {
              return http.Response(
                jsonEncode({'detail': 'Token has expired.'}),
                401,
              );
            }
            return http.Response(
              jsonEncode([
                {
                  'id': 'kid-1',
                  'display_name': 'Fresh Ada',
                  'avatar_key': 'star',
                  'updated_at': '2026-07-15T12:00:00Z',
                },
              ]),
              200,
            );
          }),
        );
        final store = MemoryAuthSessionStore();
        await store.writeSession(
          const AuthSession(
            parent: ParentAccount(id: '42', email: 'parent@example.com'),
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            profiles: [
              KidProfile(
                id: 'kid-1',
                parentId: '42',
                displayName: 'Cached Ada',
                avatarKey: 'dove',
              ),
            ],
          ),
        );
        await store.writeSelectedKidId('kid-1');
        final repository = AuthRepository(api: api, sessionStore: store);

        final profile = await repository.refreshCurrentKid();

        expect(profile?.displayName, 'Fresh Ada');
        expect(profile?.parentId, '42');
        expect(
          (await store.readSession())?.profiles.single.displayName,
          'Fresh Ada',
        );
        expect((await store.readSession())?.accessToken, 'new-access');
        expect(await store.readSelectedKidId(), 'kid-1');
        expect(
          requests.map((request) => request.url.path),
          containsAllInOrder([
            '/api/accounts/kid-profiles/',
            '/api/accounts/token/refresh/',
            '/api/accounts/kid-profiles/',
          ]),
        );
      },
    );

    test(
      'profile update replaces the cached selected child atomically',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(
          const AuthSession(
            parent: ParentAccount(id: '42', email: 'parent@example.com'),
            accessToken: 'access-token',
            refreshToken: 'refresh-token',
            profiles: [
              KidProfile(
                id: 'kid-1',
                parentId: '42',
                displayName: 'Ada',
                avatarKey: 'dove',
              ),
            ],
          ),
        );
        await store.writeSelectedKidId('kid-1');
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'id': 'kid-1',
                  'display_name': 'Ada Grace',
                  'avatar_key': 'star',
                  'updated_at': '2026-07-15T12:00:00Z',
                }),
                200,
              ),
            ),
          ),
          sessionStore: store,
        );

        final updated = await repository.updateKidProfile(
          profileId: 'kid-1',
          displayName: 'Ada Grace',
          avatarKey: 'star',
        );

        expect(updated.parentId, '42');
        expect(updated.updatedAt, DateTime.utc(2026, 7, 15, 12));
        expect((await repository.currentKid())?.displayName, 'Ada Grace');
        expect((await repository.currentKid())?.avatarKey, 'star');
        expect(await store.readSelectedKidId(), 'kid-1');
        expect((await store.readSession())?.profiles, hasLength(1));
      },
    );

    test(
      'a stale selected child is cleared after a fresh profile list',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(
          const AuthSession(
            parent: ParentAccount(id: '42', email: 'parent@example.com'),
            accessToken: 'access-token',
            refreshToken: 'refresh-token',
          ),
        );
        await store.writeSelectedKidId('deleted-kid');
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode([
                  {'id': 'kid-2', 'display_name': 'Maya', 'avatar_key': 'lion'},
                ]),
                200,
              ),
            ),
          ),
          sessionStore: store,
        );

        expect(await repository.refreshCurrentKid(), isNull);
        expect(await store.readSelectedKidId(), isNull);
        expect((await store.readSession())?.profiles.single.id, 'kid-2');
      },
    );

    test('refreshes and logs out with the rotated refresh token', () async {
      final requests = <http.Request>[];
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('token/refresh/')) {
            return http.Response(
              jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
              200,
            );
          }
          return http.Response('', 204);
        }),
      );
      const session = AuthSession(
        parent: ParentAccount(id: '42', email: 'parent@example.com'),
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );

      final refreshed = await api.refresh(session);
      await api.logout(
        accessToken: refreshed.accessToken,
        refreshToken: refreshed.refreshToken!,
      );

      expect(refreshed.accessToken, 'new-access');
      expect(refreshed.refreshToken, 'new-refresh');
      expect(jsonDecode(requests.first.body), {'refresh': 'old-refresh'});
      expect(jsonDecode(requests.last.body), {'refresh': 'new-refresh'});
      expect(requests.last.headers['authorization'], 'Bearer new-access');
    });

    test(
      'deletes the current account with bearer auth and an exact password',
      () async {
        late http.Request sentRequest;
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            sentRequest = request;
            return http.Response('', 204);
          }),
        );

        await api.deleteAccount(
          password: '  exact current password  ',
          accessToken: 'access-token',
        );

        expect(sentRequest.method, 'DELETE');
        expect(
          sentRequest.url,
          Uri.parse('https://kingdom-kids.test/api/accounts/me/'),
        );
        expect(sentRequest.headers['authorization'], 'Bearer access-token');
        expect(sentRequest.headers['content-type'], 'application/json');
        expect(jsonDecode(sentRequest.body), {
          'password': '  exact current password  ',
        });
      },
    );

    test(
      'failed account deletion preserves session and selected child',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        await store.writeSelectedKidId('kid-1');
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'password': ['The password is incorrect.'],
                }),
                400,
              ),
            ),
          ),
          sessionStore: store,
        );

        await expectLater(
          repository.deleteAccount(password: 'wrong-password'),
          throwsA(
            isA<AppException>()
                .having(
                  (error) => error.message,
                  'message',
                  'The password is incorrect.',
                )
                .having((error) => error.statusCode, 'statusCode', 400),
          ),
        );

        expect(await store.readSession(), _oldSession);
        expect(await store.readSelectedKidId(), 'kid-1');
      },
    );

    test(
      'account deletion refreshes, retries, then purges the session',
      () async {
        final requests = <http.Request>[];
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        await store.writeSelectedKidId('kid-1');
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('token/refresh/')) {
                return http.Response(
                  jsonEncode({
                    'access': 'new-access',
                    'refresh': 'new-refresh',
                  }),
                  200,
                );
              }
              if (request.headers['authorization'] == 'Bearer old-access') {
                return http.Response(
                  jsonEncode({'detail': 'Token has expired.'}),
                  401,
                );
              }
              return http.Response('', 204);
            }),
          ),
          sessionStore: store,
        );

        await repository.deleteAccount(password: 'current-password');

        expect(
          requests.map((request) => request.url.path),
          containsAllInOrder([
            '/api/accounts/me/',
            '/api/accounts/token/refresh/',
            '/api/accounts/me/',
          ]),
        );
        final deletes = requests
            .where((request) => request.method == 'DELETE')
            .toList(growable: false);
        expect(deletes, hasLength(2));
        expect(deletes.last.headers['authorization'], 'Bearer new-access');
        expect(
          deletes.every((request) => request.body == deletes.first.body),
          isTrue,
        );
        expect(await store.readSession(), isNull);
        expect(await store.readSelectedKidId(), isNull);
      },
    );

    test(
      'account deletion reports session expiry and clears stale auth',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        await store.writeSelectedKidId('kid-1');
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((request) async {
              if (request.url.path.endsWith('token/refresh/')) {
                return http.Response(
                  jsonEncode({
                    'code': 'token_not_valid',
                    'detail': 'Token is invalid or expired.',
                  }),
                  401,
                );
              }
              return http.Response(
                jsonEncode({'detail': 'Token has expired.'}),
                401,
              );
            }),
          ),
          sessionStore: store,
        );

        await expectLater(
          repository.deleteAccount(password: 'current-password'),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'session_expired',
            ),
          ),
        );

        expect(await store.readSession(), isNull);
        expect(await store.readSelectedKidId(), isNull);
      },
    );

    test(
      'repository refreshes an expired access token and retries once',
      () async {
        final requests = <http.Request>[];
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('token/refresh/')) {
              return http.Response(
                jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
                200,
              );
            }
            if (request.headers['authorization'] == 'Bearer old-access') {
              return http.Response(
                jsonEncode({'detail': 'Token has expired.'}),
                401,
              );
            }
            return http.Response(
              jsonEncode([
                {'id': 'kid-1', 'display_name': 'Ada', 'avatar_key': 'dove'},
              ]),
              200,
            );
          }),
        );
        final store = MemoryAuthSessionStore();
        await store.writeSession(
          const AuthSession(
            parent: ParentAccount(id: '42', email: 'parent@example.com'),
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
          ),
        );
        final repository = AuthRepository(api: api, sessionStore: store);

        final profiles = await repository.fetchKidProfiles();

        expect(profiles.single.displayName, 'Ada');
        expect((await store.readSession())?.accessToken, 'new-access');
        expect((await store.readSession())?.refreshToken, 'new-refresh');
        expect(
          requests.map((request) => request.url.path),
          containsAllInOrder([
            '/api/accounts/kid-profiles/',
            '/api/accounts/token/refresh/',
            '/api/accounts/kid-profiles/',
          ]),
        );
      },
    );

    test('temporary refresh failure preserves the stored session', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          if (request.url.path.endsWith('token/refresh/')) {
            return http.Response(
              jsonEncode({'detail': 'The service is temporarily unavailable.'}),
              503,
            );
          }
          return http.Response(
            jsonEncode({'detail': 'Token has expired.'}),
            401,
          );
        }),
      );
      final store = MemoryAuthSessionStore();
      await store.writeSession(_oldSession);
      final repository = AuthRepository(api: api, sessionStore: store);

      await expectLater(
        repository.fetchKidProfiles(),
        throwsA(
          isA<AppException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having((error) => error.code, 'code', isNot('session_expired')),
        ),
      );

      final preserved = await store.readSession();
      expect(preserved?.accessToken, 'old-access');
      expect(preserved?.refreshToken, 'old-refresh');
    });

    test('refresh timeout preserves the stored session for retry', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((request) async {
          if (request.url.path.endsWith('token/refresh/')) {
            throw TimeoutException('stalled refresh');
          }
          return http.Response(
            jsonEncode({'detail': 'Token has expired.'}),
            401,
          );
        }),
      );
      final store = MemoryAuthSessionStore();
      await store.writeSession(_oldSession);
      final repository = AuthRepository(api: api, sessionStore: store);

      await expectLater(
        repository.fetchKidProfiles(),
        throwsA(
          isA<AppException>().having(
            (error) => error.code,
            'code',
            'request_timeout',
          ),
        ),
      );

      final preserved = await store.readSession();
      expect(preserved?.accessToken, 'old-access');
      expect(preserved?.refreshToken, 'old-refresh');
    });

    test(
      'an invalid refresh response expires and clears the session',
      () async {
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            if (request.url.path.endsWith('token/refresh/')) {
              return http.Response(
                jsonEncode({
                  'code': 'token_not_valid',
                  'detail': 'Token is invalid or expired.',
                }),
                401,
              );
            }
            return http.Response(
              jsonEncode({'detail': 'Token has expired.'}),
              401,
            );
          }),
        );
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final repository = AuthRepository(api: api, sessionStore: store);

        await expectLater(
          repository.fetchKidProfiles(),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'session_expired',
            ),
          ),
        );

        expect(await store.readSession(), isNull);
      },
    );

    test(
      'a token refresh keeps profile edits completed while it was pending',
      () async {
        final refreshStarted = Completer<void>();
        final releaseRefresh = Completer<void>();
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            if (request.url.path.endsWith('token/refresh/')) {
              refreshStarted.complete();
              await releaseRefresh.future;
              return http.Response(
                jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'id': 'kid-1',
                'display_name': 'Ada Grace',
                'avatar_key': 'dove',
              }),
              200,
            );
          }),
        );
        final refreshing = AuthRepository(api: api, sessionStore: store);
        final editing = AuthRepository(api: api, sessionStore: store);
        final refresh = refreshing.refreshSession();
        await refreshStarted.future;
        final edited = await editing.updateKidProfile(
          profileId: 'kid-1',
          displayName: 'Ada Grace',
          avatarKey: 'dove',
        );
        await editing.selectKid(edited);
        releaseRefresh.complete();
        await refresh;
        expect((await store.readSession())?.accessToken, 'new-access');
        expect((await refreshing.currentKid())?.displayName, 'Ada Grace');
        expect((await store.readSession())?.profiles.single.id, 'kid-1');
      },
    );

    test('a delayed logout cannot clear a newly logged-in parent', () async {
      final logoutStarted = Completer<void>();
      final releaseLogout = Completer<void>();
      final store = MemoryAuthSessionStore();
      await store.writeSession(_oldSession);
      final loggingOut = AuthRepository(
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            logoutStarted.complete();
            await releaseLogout.future;
            return http.Response('', 204);
          }),
        ),
        sessionStore: store,
      );
      final loggingIn = AuthRepository(
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient(
            (_) async => http.Response(jsonEncode(_newParentPayload), 200),
          ),
        ),
        sessionStore: store,
      );
      final logout = loggingOut.logout();
      await logoutStarted.future;
      await loggingIn.login(_newParentLogin);
      releaseLogout.complete();
      await logout;
      expect((await store.readSession())?.parent.id, '99');
      expect((await store.readSession())?.accessToken, 'other-access');
    });

    test(
      'a delayed logout preserves a fresh sign-in by the same parent',
      () async {
        final logoutStarted = Completer<void>();
        final releaseLogout = Completer<void>();
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final loggingOut = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((request) async {
              logoutStarted.complete();
              await releaseLogout.future;
              return http.Response('', 204);
            }),
          ),
          sessionStore: store,
        );
        final loggingIn = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'user': {
                    'id': 42,
                    'email': 'parent@example.com',
                    'kid_profiles': <Object>[],
                  },
                  'access': 'fresh-login-access',
                  'refresh': 'fresh-login-refresh',
                }),
                200,
              ),
            ),
          ),
          sessionStore: store,
        );
        final logout = loggingOut.logout();
        await logoutStarted.future;
        await loggingIn.login(
          const LoginRequest(
            email: 'parent@example.com',
            password: 'Correct-Horse-Battery-Staple-2026!',
          ),
        );
        releaseLogout.complete();
        await logout;
        expect((await store.readSession())?.parent.id, '42');
        expect((await store.readSession())?.accessToken, 'fresh-login-access');
      },
    );

    test(
      'logout still clears its original session after a token rotation',
      () async {
        final requests = <http.Request>[];
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final repository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('token/refresh/')) {
                return http.Response(
                  jsonEncode({
                    'access': 'rotated-access',
                    'refresh': 'rotated-refresh',
                  }),
                  200,
                );
              }
              if (request.headers['authorization'] == 'Bearer old-access') {
                return http.Response(
                  jsonEncode({'detail': 'Token expired.'}),
                  401,
                );
              }
              return http.Response('', 204);
            }),
          ),
          sessionStore: store,
        );
        await repository.logout();
        expect(await store.readSession(), isNull);
        expect(requests.last.headers['authorization'], 'Bearer rotated-access');
        expect(jsonDecode(requests.last.body), {'refresh': 'rotated-refresh'});
      },
    );

    test('repository instances share one in-flight token refresh', () async {
      final refreshStarted = Completer<void>();
      final releaseRefresh = Completer<void>();
      final bothOldRequestsCompleted = Completer<void>();
      var refreshCalls = 0;
      var oldProfileCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('token/refresh/')) {
          refreshCalls += 1;
          if (!refreshStarted.isCompleted) {
            refreshStarted.complete();
          }
          await releaseRefresh.future;
          return http.Response(
            jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
            200,
          );
        }
        if (request.headers['authorization'] == 'Bearer old-access') {
          oldProfileCalls += 1;
          if (oldProfileCalls == 2) {
            bothOldRequestsCompleted.complete();
          }
          return http.Response(
            jsonEncode({'detail': 'Token has expired.'}),
            401,
          );
        }
        return http.Response(
          jsonEncode([
            {'id': 'kid-1', 'display_name': 'Ada', 'avatar_key': 'dove'},
          ]),
          200,
        );
      });
      final store = MemoryAuthSessionStore();
      await store.writeSession(_oldSession);
      final firstRepository = AuthRepository(
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: client,
        ),
        sessionStore: store,
      );
      final secondRepository = AuthRepository(
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: client,
        ),
        sessionStore: store,
      );

      final firstProfiles = firstRepository.fetchKidProfiles();
      await refreshStarted.future;
      final secondProfiles = secondRepository.fetchKidProfiles();
      await bothOldRequestsCompleted.future;
      await Future<void>.delayed(Duration.zero);

      expect(refreshCalls, 1);
      releaseRefresh.complete();
      final results = await Future.wait([firstProfiles, secondProfiles]);

      expect(
        results.every((profiles) => profiles.single.displayName == 'Ada'),
        isTrue,
      );
      expect(refreshCalls, 1);
      expect((await store.readSession())?.accessToken, 'new-access');
      expect((await store.readSession())?.refreshToken, 'new-refresh');
    });

    test(
      'a stale 401 reuses the session rotated by another repository',
      () async {
        final staleRequestStarted = Completer<void>();
        final releaseStaleResponse = Completer<void>();
        var staleRepositoryRefreshCalls = 0;
        final staleApi = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            if (request.url.path.endsWith('token/refresh/')) {
              staleRepositoryRefreshCalls += 1;
              return http.Response('', 500);
            }
            if (request.headers['authorization'] == 'Bearer old-access') {
              staleRequestStarted.complete();
              await releaseStaleResponse.future;
              return http.Response(
                jsonEncode({'detail': 'Token has expired.'}),
                401,
              );
            }
            return http.Response(
              jsonEncode([
                {'id': 'kid-1', 'display_name': 'Ada', 'avatar_key': 'dove'},
              ]),
              200,
            );
          }),
        );
        final rotatingApi = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            if (request.url.path.endsWith('token/refresh/')) {
              return http.Response(
                jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
                200,
              );
            }
            if (request.headers['authorization'] == 'Bearer old-access') {
              return http.Response(
                jsonEncode({'detail': 'Token has expired.'}),
                401,
              );
            }
            return http.Response(
              jsonEncode([
                {'id': 'kid-1', 'display_name': 'Ada', 'avatar_key': 'dove'},
              ]),
              200,
            );
          }),
        );
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final staleRepository = AuthRepository(
          api: staleApi,
          sessionStore: store,
        );
        final rotatingRepository = AuthRepository(
          api: rotatingApi,
          sessionStore: store,
        );

        final staleProfiles = staleRepository.fetchKidProfiles();
        await staleRequestStarted.future;
        await rotatingRepository.fetchKidProfiles();
        releaseStaleResponse.complete();
        final profiles = await staleProfiles;

        expect(profiles.single.displayName, 'Ada');
        expect(staleRepositoryRefreshCalls, 0);
        expect((await store.readSession())?.accessToken, 'new-access');
        expect((await store.readSession())?.refreshToken, 'new-refresh');
      },
    );

    test(
      'a protected retry 401 clears the unchanged session as expired',
      () async {
        var profileCalls = 0;
        final api = HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            if (request.url.path.endsWith('token/refresh/')) {
              return http.Response(
                jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
                200,
              );
            }
            profileCalls += 1;
            return http.Response(
              jsonEncode({'detail': 'Authentication failed.'}),
              401,
            );
          }),
        );
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final repository = AuthRepository(api: api, sessionStore: store);

        await expectLater(
          repository.fetchKidProfiles(),
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'session_expired',
            ),
          ),
        );

        expect(profileCalls, 2);
        expect(await store.readSession(), isNull);
      },
    );

    test(
      'a protected retry reuses credentials rotated by another repository',
      () async {
        final retryStarted = Completer<void>();
        final releaseRetry = Completer<void>();
        var refreshCalls = 0;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('token/refresh/')) {
            refreshCalls += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['refresh'] == 'old-refresh') {
              return http.Response(
                jsonEncode({'access': 'mid-access', 'refresh': 'mid-refresh'}),
                200,
              );
            }
            return http.Response(
              jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
              200,
            );
          }
          final authorization = request.headers['authorization'];
          if (authorization == 'Bearer old-access') {
            return http.Response(
              jsonEncode({'detail': 'Token has expired.'}),
              401,
            );
          }
          if (authorization == 'Bearer mid-access') {
            retryStarted.complete();
            await releaseRetry.future;
            return http.Response(
              jsonEncode({'detail': 'Token was superseded.'}),
              401,
            );
          }
          return http.Response(
            jsonEncode([
              {'id': 'kid-1', 'display_name': 'Ada', 'avatar_key': 'dove'},
            ]),
            200,
          );
        });
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final firstRepository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: client,
          ),
          sessionStore: store,
        );
        final rotatingRepository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: client,
          ),
          sessionStore: store,
        );

        final profilesFuture = firstRepository.fetchKidProfiles();
        await retryStarted.future;
        final rotated = await rotatingRepository.refreshSession();
        releaseRetry.complete();
        final profiles = await profilesFuture;

        expect(rotated.accessToken, 'new-access');
        expect(profiles.single.displayName, 'Ada');
        expect(refreshCalls, 2);
        expect((await store.readSession())?.accessToken, 'new-access');
        expect((await store.readSession())?.refreshToken, 'new-refresh');
      },
    );

    test(
      'a late profile fetch cannot update a newly logged-in parent',
      () async {
        final fetchStarted = Completer<void>();
        final releaseFetch = Completer<void>();
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final fetchingRepository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((_) async {
              fetchStarted.complete();
              await releaseFetch.future;
              return http.Response(
                jsonEncode([
                  {
                    'id': 'old-kid',
                    'display_name': 'Ada',
                    'avatar_key': 'dove',
                  },
                ]),
                200,
              );
            }),
          ),
          sessionStore: store,
        );
        final loginRepository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(jsonEncode(_newParentPayload), 200),
            ),
          ),
          sessionStore: store,
        );

        final fetchFuture = fetchingRepository.fetchKidProfiles();
        final fetchExpectation = expectLater(
          fetchFuture,
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'session_account_changed',
            ),
          ),
        );
        await fetchStarted.future;
        await loginRepository.login(_newParentLogin);
        releaseFetch.complete();
        await fetchExpectation;

        final active = await store.readSession();
        expect(active?.parent.id, '99');
        expect(active?.accessToken, 'other-access');
        expect(active?.profiles, isEmpty);
      },
    );

    test(
      'a late profile create cannot update a newly logged-in parent',
      () async {
        final createStarted = Completer<void>();
        final releaseCreate = Completer<void>();
        final store = MemoryAuthSessionStore();
        await store.writeSession(_oldSession);
        final creatingRepository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient((_) async {
              createStarted.complete();
              await releaseCreate.future;
              return http.Response(
                jsonEncode({
                  'id': 'old-kid',
                  'display_name': 'Ada',
                  'avatar_key': 'dove',
                }),
                201,
              );
            }),
          ),
          sessionStore: store,
        );
        final loginRepository = AuthRepository(
          api: HttpAuthApi(
            baseUrl: 'https://kingdom-kids.test/api',
            client: MockClient(
              (_) async => http.Response(jsonEncode(_newParentPayload), 200),
            ),
          ),
          sessionStore: store,
        );

        final createFuture = creatingRepository.createKidProfile(
          const CreateKidProfileRequest(
            displayName: 'Ada',
            avatarKey: 'dove',
            operationId: '00000000-0000-4000-8000-000000000001',
          ),
        );
        final createExpectation = expectLater(
          createFuture,
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'session_account_changed',
            ),
          ),
        );
        await createStarted.future;
        await loginRepository.login(_newParentLogin);
        releaseCreate.complete();
        await createExpectation;

        final active = await store.readSession();
        expect(active?.parent.id, '99');
        expect(active?.accessToken, 'other-access');
        expect(active?.profiles, isEmpty);
        expect(await store.readSelectedKidId(), isNull);
      },
    );

    test('maps a stalled request to a retryable timeout error', () async {
      final api = HttpAuthApi(
        baseUrl: 'https://kingdom-kids.test/api',
        client: MockClient((_) async {
          throw TimeoutException('stalled');
        }),
      );

      await expectLater(
        api.login(
          const LoginRequest(
            email: 'parent@example.com',
            password: 'Correct-Horse-Battery-Staple-2026!',
          ),
        ),
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
}

const _oldSession = AuthSession(
  parent: ParentAccount(id: '42', email: 'parent@example.com'),
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
);

const _newParentLogin = LoginRequest(
  email: 'other@example.com',
  password: 'Correct-Horse-Battery-Staple-2026!',
);

const _newParentPayload = {
  'user': {'id': 99, 'email': 'other@example.com', 'kid_profiles': <Object>[]},
  'access': 'other-access',
  'refresh': 'other-refresh',
};
