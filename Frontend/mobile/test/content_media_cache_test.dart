import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/data/media_access_scope.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';

const _policy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.test/api',
  configuredHosts: 'cdn.test,api.cloudinary.com',
);

void main() {
  setUp(featureReadCache.invalidate);
  tearDown(featureReadCache.invalidate);

  test('simultaneous and repeated covers share a validated download', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    final cache = CachedContentMediaFetcher(
      policy: _policy,
      fetcher: HttpContentMediaFetcher(
        policy: _policy,
        client: MockClient((_) {
          requests++;
          return response.future;
        }),
      ),
    );
    final first = cache.fetch('https://cdn.test/cover.webp');
    final second = cache.fetch('https://cdn.test/cover.webp');
    response.complete(
      http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'image/webp'},
      ),
    );
    await Future.wait([first, second]);
    await cache.fetch('https://cdn.test/cover.webp');
    expect(requests, 1);
  });

  test(
    'private query URLs never share in-flight or repeated downloads',
    () async {
      final response = Completer<http.Response>();
      var requests = 0;
      final cache = CachedContentMediaFetcher(
        policy: _policy,
        fetcher: HttpContentMediaFetcher(
          policy: _policy,
          client: MockClient((_) {
            requests++;
            return response.future;
          }),
        ),
      );
      const source =
          'https://cdn.test/cover.webp?signature=private&expires_at=2000000000';
      final first = cache.fetch(source);
      final second = cache.fetch(source);
      response.complete(
        http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/webp'},
        ),
      );
      await Future.wait([first, second]);
      expect(requests, 2);
      await cache.fetch(source);
      expect(requests, 3);
    },
  );

  for (final source in [
    'https://api.cloudinary.com/v1_1/test/image/download?type=authenticated&signature=private&expires_at=1794477660',
    'https://cdn.test/cover.webp?X-Amz-Signature=private&X-Amz-Expires=60',
  ]) {
    test(
      'provider expiration cannot reuse downloaded bytes: $source',
      () async {
        var now = DateTime.utc(2026, 11, 12, 10);
        final expiresAt = now.add(const Duration(minutes: 1));
        var requests = 0;
        final cache = CachedContentMediaFetcher(
          policy: _policy,
          now: () => now,
          fetcher: HttpContentMediaFetcher(
            policy: _policy,
            client: MockClient((_) async {
              requests++;
              return http.Response.bytes(
                [1, 2, 3],
                now.isBefore(expiresAt) ? 200 : 403,
                headers: {'content-type': 'image/webp'},
              );
            }),
          ),
        );
        await cache.fetch(source);
        now = expiresAt;
        await expectLater(
          cache.fetch(source),
          throwsA(isA<ContentMediaFetchException>()),
        );
        now = expiresAt.add(const Duration(seconds: 1));
        await expectLater(
          cache.fetch(source),
          throwsA(isA<ContentMediaFetchException>()),
        );
        expect(requests, 3);
      },
    );
  }

  test('a public redirect to a private query URL is never retained', () async {
    var requests = 0;
    final cache = CachedContentMediaFetcher(
      policy: _policy,
      fetcher: HttpContentMediaFetcher(
        policy: _policy,
        client: MockClient((request) async {
          requests++;
          if (!request.url.hasQuery) {
            return http.Response(
              '',
              302,
              headers: {'location': '/cover.webp?signature=private'},
            );
          }
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/webp'},
          );
        }),
      ),
    );
    await cache.fetch('https://cdn.test/cover.webp');
    await cache.fetch('https://cdn.test/cover.webp');
    expect(requests, 4);
  });

  test(
    'signed covers reuse only their explicit scope, URL and media generation',
    () async {
      var requests = 0;
      final cache = _cache(() => requests++);
      const source =
          'https://cdn.test/cover.webp?signature=private&expires_at=9999999999';
      await cache.fetchScoped(source, scope: ('parent', 'child', 'lion', 1));
      await cache.fetchScoped(source, scope: ('parent', 'child', 'lion', 1));
      expect(requests, 1);
      featureReadCache.invalidate(includeMedia: false);
      await cache.fetchScoped(source, scope: ('parent', 'child', 'lion', 1));
      expect(requests, 1);
      await cache.fetchScoped(source, scope: ('parent', 'sibling', 'lion', 1));
      await cache.fetchScoped(
        '$source&issued=2',
        scope: ('parent', 'child', 'lion', 1),
      );
      expect(requests, 3);
      await cache.fetch(source);
      expect(requests, 4);
      featureReadCache.invalidate();
      await cache.fetchScoped(source, scope: ('parent', 'child', 'lion', 1));
      expect(requests, 5);
    },
  );

  test(
    'scoped images expire before the signed URL and share the public byte budget',
    () async {
      var now = DateTime.utc(2026, 11, 12, 10);
      final expiry = now.add(const Duration(seconds: 30));
      var requests = 0;
      final cache = _cache(() => requests++, maxBytes: 5, now: () => now);
      final source =
          'https://cdn.test/cover.webp?signature=private&expires_at=${expiry.millisecondsSinceEpoch ~/ 1000}';
      await cache.fetchScoped(source, scope: 'family-child-avatar');
      await cache.fetchScoped(source, scope: 'family-child-avatar');
      expect(requests, 1);
      now = expiry.subtract(const Duration(seconds: 10));
      await cache.fetchScoped(source, scope: 'family-child-avatar');
      expect(requests, 2);
      await cache.fetch('https://cdn.test/public.webp');
      await cache.fetchScoped(
        'https://cdn.test/other.webp',
        scope: 'family-child-avatar',
      );
      await cache.fetch('https://cdn.test/public.webp');
      expect(requests, 5);
    },
  );

  test(
    'scoped wrapper rejects a child switch during download before publishing bytes',
    () async {
      const child = KidProfile(
        id: 'child',
        parentId: 'parent',
        displayName: 'Kid',
        avatarKey: 'lion',
      );
      const sibling = KidProfile(
        id: 'sibling',
        parentId: 'parent',
        displayName: 'Sibling',
        avatarKey: 'dove',
      );
      final store = MemoryAuthSessionStore();
      await store.writeSession(
        const AuthSession(
          parent: ParentAccount(id: 'parent', email: 'parent@example.test'),
          accessToken: 'synthetic-token',
          profiles: [child, sibling],
        ),
      );
      await store.writeSelectedKidId(child.id);
      final auth = AuthRepository(sessionStore: store);
      final requested = Completer<void>(),
          response = Completer<http.Response>();
      var requests = 0;
      final cache = CachedContentMediaFetcher(
        policy: _policy,
        fetcher: HttpContentMediaFetcher(
          policy: _policy,
          client: MockClient((_) {
            requests++;
            requested.complete();
            return response.future;
          }),
        ),
      );
      final fetcher = ScopedContentMediaFetcher(
        authRepository: auth,
        cache: cache,
      );
      final result = fetcher.fetch(
        'https://cdn.test/cover.webp?signature=private&expires_at=9999999999',
      );
      await requested.future;
      await auth.selectKid(sibling);
      final expectation = expectLater(result, throwsException);
      response.complete(
        http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/webp'},
        ),
      );
      await expectation;
      expect(requests, 1);
    },
  );

  test('byte budget and expiry release old cover entries', () async {
    var now = DateTime(2026);
    var requests = 0;
    final cache = CachedContentMediaFetcher(
      policy: _policy,
      maxBytes: 5,
      now: () => now,
      fetcher: HttpContentMediaFetcher(
        policy: _policy,
        client: MockClient((_) async {
          requests++;
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/webp'},
          );
        }),
      ),
    );
    await cache.fetch('https://cdn.test/a.webp');
    await cache.fetch('https://cdn.test/b.webp');
    await cache.fetch('https://cdn.test/a.webp');
    expect(requests, 3);
    now = now.add(const Duration(minutes: 6));
    await cache.fetch('https://cdn.test/a.webp');
    expect(requests, 4);
  });

  test(
    'audio and failed responses are not retained, untrusted URLs never load',
    () async {
      var requests = 0;
      final cache = CachedContentMediaFetcher(
        policy: _policy,
        fetcher: HttpContentMediaFetcher(
          policy: _policy,
          client: MockClient((_) async {
            requests++;
            return http.Response.bytes(
              [1, 2, 3],
              requests == 1 ? 503 : 200,
              headers: {'content-type': 'audio/mpeg'},
            );
          }),
        ),
      );
      await expectLater(
        cache.fetch('https://cdn.test/track.mp3'),
        throwsA(isA<ContentMediaFetchException>()),
      );
      await cache.fetch('https://cdn.test/track.mp3');
      await cache.fetch('https://cdn.test/track.mp3');
      expect(requests, 3);
      await expectLater(
        cache.fetch('https://untrusted.test/pixel'),
        throwsA(isA<ContentMediaFetchException>()),
      );
      expect(requests, 3);
    },
  );
}

CachedContentMediaFetcher _cache(
  void Function() onRequest, {
  int maxBytes = 16 * 1024 * 1024,
  DateTime Function()? now,
}) => CachedContentMediaFetcher(
  policy: _policy,
  maxBytes: maxBytes,
  now: now,
  fetcher: HttpContentMediaFetcher(
    policy: _policy,
    client: MockClient((_) async {
      onRequest();
      return http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'image/webp'},
      );
    }),
  ),
);
