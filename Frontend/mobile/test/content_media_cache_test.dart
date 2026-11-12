import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';

const _policy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.test/api',
  configuredHosts: 'cdn.test',
);

void main() {
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
