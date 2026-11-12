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
  test(
    'fetches direct bytes without automatic redirects or query changes',
    () async {
      late http.Request sentRequest;
      final fetcher = HttpContentMediaFetcher(
        policy: _policy,
        client: MockClient((request) async {
          sentRequest = request;
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/webp'},
          );
        }),
      );

      final media = await fetcher.fetch(
        'https://cdn.test/cover.webp?signature=a%2Fb%2Bc&expires=123',
      );

      expect(sentRequest.followRedirects, isFalse);
      expect(sentRequest.maxRedirects, 0);
      expect(
        sentRequest.url.toString(),
        'https://cdn.test/cover.webp?signature=a%2Fb%2Bc&expires=123',
      );
      expect(media.bytes, orderedEquals([1, 2, 3]));
      expect(media.finalUri, sentRequest.url);
      expect(media.contentType, 'image/webp');
    },
  );

  test(
    'follows an allowed redirect only after validating the next URI',
    () async {
      final requested = <String>[];
      final fetcher = HttpContentMediaFetcher(
        policy: _policy,
        client: MockClient((request) async {
          requested.add(request.url.toString());
          expect(request.followRedirects, isFalse);
          if (requested.length == 1) {
            return http.Response(
              '',
              302,
              headers: {
                'location':
                    'https://api.test/media/final.webp?signature=redirect%2Bsig',
              },
            );
          }
          return http.Response.bytes([4, 5, 6], 200);
        }),
      );

      final media = await fetcher.fetch('https://cdn.test/start');

      expect(requested, [
        'https://cdn.test/start',
        'https://api.test/media/final.webp?signature=redirect%2Bsig',
      ]);
      expect(media.bytes, orderedEquals([4, 5, 6]));
      expect(
        media.finalUri.toString(),
        'https://api.test/media/final.webp?signature=redirect%2Bsig',
      );
    },
  );

  test('rejects an unowned redirect before requesting that host', () async {
    final requested = <Uri>[];
    final fetcher = HttpContentMediaFetcher(
      policy: _policy,
      client: MockClient((request) async {
        requested.add(request.url);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://tracking.example/pixel'},
        );
      }),
    );

    await expectLater(
      fetcher.fetch('https://cdn.test/start'),
      throwsA(
        isA<ContentMediaFetchException>().having(
          (error) => error.code,
          'code',
          'untrusted_redirect',
        ),
      ),
    );
    expect(requested, [Uri.parse('https://cdn.test/start')]);
  });

  test('detects a trusted-host redirect loop', () async {
    final requested = <String>[];
    final fetcher = HttpContentMediaFetcher(
      policy: _policy,
      client: MockClient((request) async {
        requested.add(request.url.toString());
        return request.url.path == '/one'
            ? http.Response('', 302, headers: {'location': '/two'})
            : http.Response('', 302, headers: {'location': '/one'});
      }),
    );

    await expectLater(
      fetcher.fetch('https://cdn.test/one'),
      throwsA(
        isA<ContentMediaFetchException>().having(
          (error) => error.code,
          'code',
          'redirect_loop',
        ),
      ),
    );
    expect(requested, ['https://cdn.test/one', 'https://cdn.test/two']);
  });

  test('caps redirect chains even when every hop is trusted', () async {
    var requestCount = 0;
    final fetcher = HttpContentMediaFetcher(
      policy: _policy,
      maxRedirects: 2,
      client: MockClient((request) async {
        requestCount += 1;
        return http.Response(
          '',
          302,
          headers: {'location': '/hop-$requestCount'},
        );
      }),
    );

    await expectLater(
      fetcher.fetch('https://cdn.test/start'),
      throwsA(
        isA<ContentMediaFetchException>().having(
          (error) => error.code,
          'code',
          'too_many_redirects',
        ),
      ),
    );
    expect(requestCount, 3);
  });

  test('cancels media that exceeds the byte limit', () async {
    final fetcher = HttpContentMediaFetcher(
      policy: _policy,
      maxBytes: 3,
      client: MockClient((_) async => http.Response.bytes([1, 2, 3, 4], 200)),
    );

    await expectLater(
      fetcher.fetch('https://cdn.test/large.webp'),
      throwsA(
        isA<ContentMediaFetchException>().having(
          (error) => error.code,
          'code',
          'media_too_large',
        ),
      ),
    );
  });
}
