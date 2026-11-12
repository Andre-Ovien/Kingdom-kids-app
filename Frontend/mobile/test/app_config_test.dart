import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/config/app_config.dart';

void main() {
  group('AppConfig.resolveApiUri', () {
    test('adds the API prefix when the configured URL is the backend root', () {
      final uri = AppConfig.resolveApiUri(
        'accounts/register/',
        baseUrl: 'http://10.166.184.140:8000',
      );

      expect(
        uri,
        Uri.parse('http://10.166.184.140:8000/api/accounts/register/'),
      );
    });

    test('does not duplicate an explicit API prefix', () {
      final uri = AppConfig.resolveApiUri(
        '/accounts/login/',
        baseUrl: 'http://10.166.184.140:8000/api/',
      );

      expect(uri, Uri.parse('http://10.166.184.140:8000/api/accounts/login/'));
    });

    test('preserves an explicitly configured custom API path and query', () {
      final uri = AppConfig.resolveApiUri(
        'stories/',
        baseUrl: 'https://example.test/backend/v1',
        queryParameters: {'category': 'Big Faith'},
      );

      expect(uri.path, '/backend/v1/stories/');
      expect(uri.queryParameters, {'category': 'Big Faith'});
    });

    test('rejects cleartext and credentialed endpoints for release', () {
      expect(
        () => AppConfig.validateApiBaseUri(
          baseUrl: 'http://api.kingdom-kids.app/api',
          requireHttps: true,
        ),
        throwsA(isA<AppConfigurationException>()),
      );
      expect(
        () => AppConfig.validateApiBaseUri(
          baseUrl: 'https://user:secret@api.kingdom-kids.app/api',
          requireHttps: true,
        ),
        throwsA(isA<AppConfigurationException>()),
      );
    });

    test('accepts an absolute HTTPS release endpoint', () {
      expect(
        AppConfig.validateApiBaseUri(
          baseUrl: 'https://api.kingdom-kids.app/api',
          requireHttps: true,
        ),
        Uri.parse('https://api.kingdom-kids.app/api'),
      );
    });

    test('rejects local and non-public literal hosts for release', () {
      const rejectedUrls = [
        'https://localhost/api',
        'https://api.localhost/api',
        'https://localhost./api',
        'https://host.docker.internal/api',
        'https://10.0.2.2/api',
        'https://10.0.3.2/api',
        'https://0.0.0.0/api',
        'https://127.0.0.1/api',
        'https://127.1/api',
        'https://2130706433/api',
        'https://169.254.10.20/api',
        'https://10.20.30.40/api',
        'https://172.16.0.1/api',
        'https://172.31.255.254/api',
        'https://192.168.1.20/api',
        'https://[::]/api',
        'https://[::1]/api',
        'https://[fe80::1]/api',
        'https://[fc00::1]/api',
        'https://[fd12:3456::1]/api',
        'https://[::ffff:127.0.0.1]/api',
        'https://[::ffff:192.168.1.20]/api',
      ];

      for (final baseUrl in rejectedUrls) {
        expect(
          () => AppConfig.validateApiBaseUri(
            baseUrl: baseUrl,
            requireHttps: true,
          ),
          throwsA(isA<AppConfigurationException>()),
          reason: baseUrl,
        );
      }
    });

    test('accepts public IPv4 and IPv6 literals for release', () {
      expect(
        AppConfig.validateApiBaseUri(
          baseUrl: 'https://8.8.8.8/api',
          requireHttps: true,
        ),
        Uri.parse('https://8.8.8.8/api'),
      );
      expect(
        AppConfig.validateApiBaseUri(
          baseUrl: 'https://[2606:4700:4700::1111]/api',
          requireHttps: true,
        ),
        Uri.parse('https://[2606:4700:4700::1111]/api'),
      );
    });

    test('keeps HTTP loopback and LAN endpoints available for debug', () {
      const debugUrls = [
        'http://localhost:8000/api',
        'http://10.166.184.140:8000/api',
        'http://192.168.1.20:8000/api',
        'http://[fd12:3456::1]:8000/api',
      ];

      for (final baseUrl in debugUrls) {
        expect(
          AppConfig.validateApiBaseUri(baseUrl: baseUrl, requireHttps: false),
          Uri.parse(baseUrl),
          reason: baseUrl,
        );
      }
    });
  });

  group('ContentMediaPolicy', () {
    const releasePolicy = ContentMediaPolicy(
      apiBaseUrl: 'https://api.kingdom-kids.test/api',
      configuredHosts: 'cdn.kingdom-kids.test, audio.kingdom-kids.test',
    );

    test('trusts the API host and configured CDN host', () {
      expect(
        releasePolicy.sanitize(
          'https://api.kingdom-kids.test/media/story.webp',
        ),
        'https://api.kingdom-kids.test/media/story.webp',
      );
      expect(
        releasePolicy.sanitize(
          'https://cdn.kingdom-kids.test/story.webp?token=signed%20value',
        ),
        'https://cdn.kingdom-kids.test/story.webp?token=signed%20value',
      );
    });

    test(
      'rejects cleartext, credentialed, fragmented, and non-default ports',
      () {
        expect(
          releasePolicy.sanitize('http://cdn.kingdom-kids.test/story.webp'),
          isNull,
        );
        expect(
          releasePolicy.sanitize(
            'https://user:secret@cdn.kingdom-kids.test/story.webp',
          ),
          isNull,
        );
        expect(
          releasePolicy.sanitize(
            'https://cdn.kingdom-kids.test/story.webp#chapter',
          ),
          isNull,
        );
        expect(
          releasePolicy.sanitize(
            'https://cdn.kingdom-kids.test:8443/story.webp',
          ),
          isNull,
        );
      },
    );

    test('rejects an HTTPS host outside the exact allowlist', () {
      expect(
        releasePolicy.sanitize('https://tracking.example/story.webp'),
        isNull,
      );
      expect(
        releasePolicy.sanitize(
          'https://cdn.kingdom-kids.test.tracking.example/story.webp',
        ),
        isNull,
      );
    });

    test('permits cleartext only for localhost in a debug policy', () {
      const debugPolicy = ContentMediaPolicy(
        apiBaseUrl: 'http://localhost:8000/api',
        configuredHosts: 'media.example.test',
        requireHttps: false,
      );

      expect(
        debugPolicy.sanitize('http://localhost:8000/media/sample.mp3'),
        'http://localhost:8000/media/sample.mp3',
      );
      expect(
        debugPolicy.sanitize('http://media.example.test/story.webp'),
        isNull,
      );
      expect(
        debugPolicy.sanitize('http://localhost:9000/media/sample.mp3'),
        isNull,
      );
    });

    test('allows a non-default port only when the API declares it', () {
      const explicitApiPort = ContentMediaPolicy(
        apiBaseUrl: 'https://api.kingdom-kids.test:8443/api',
        configuredHosts: 'cdn.kingdom-kids.test',
      );

      expect(
        explicitApiPort.sanitize(
          'https://api.kingdom-kids.test:8443/media/story.webp',
        ),
        'https://api.kingdom-kids.test:8443/media/story.webp',
      );
      expect(
        explicitApiPort.sanitize(
          'https://cdn.kingdom-kids.test:8443/story.webp',
        ),
        isNull,
      );
    });

    test('allows development LAN media only from the exact API origin', () {
      const policy = ContentMediaPolicy(
        apiBaseUrl: 'http://192.168.1.103:8000/api',
        configuredHosts: '192.168.1.104',
        requireHttps: false,
      );
      expect(
        policy.sanitize('http://192.168.1.103:8000/media/story.wav'),
        'http://192.168.1.103:8000/media/story.wav',
      );
      for (final url in const [
        'http://192.168.1.103:9000/media/story.wav',
        'http://192.168.1.103/media/story.wav',
        'http://192.168.1.104:8000/media/story.wav',
        'http://192.168.1.104/media/story.wav',
      ]) {
        expect(policy.sanitize(url), isNull, reason: url);
      }
      const release = ContentMediaPolicy(
        apiBaseUrl: 'http://192.168.1.103:8000/api',
        configuredHosts: '192.168.1.103',
      );
      expect(
        release.sanitize('http://192.168.1.103:8000/media/story.wav'),
        isNull,
      );
      const defaultPort = ContentMediaPolicy(
        apiBaseUrl: 'http://192.168.1.103/api',
        requireHttps: false,
      );
      expect(
        defaultPort.sanitize('http://192.168.1.103:80/media/story.wav'),
        'http://192.168.1.103:80/media/story.wav',
      );
    });

    test('rejects a private release media host even when configured', () {
      const policy = ContentMediaPolicy(
        apiBaseUrl: 'https://api.kingdom-kids.test/api',
        configuredHosts: '192.168.1.20',
      );

      expect(policy.sanitize('https://192.168.1.20/media/story.webp'), isNull);
    });

    test('ignores malformed configured media hostnames', () {
      const policy = ContentMediaPolicy(
        apiBaseUrl: 'https://api.kingdom-kids.test/api',
        configuredHosts:
            'valid.kingdom-kids.test, double..dot.test, _service.test, '
            '-leading.test, trailing-.test, wildcard.*.test, trailing.test.',
      );

      expect(
        policy.sanitize('https://valid.kingdom-kids.test/story.webp'),
        'https://valid.kingdom-kids.test/story.webp',
      );
      for (final host in const [
        'double..dot.test',
        '_service.test',
        '-leading.test',
        'trailing-.test',
        'wildcard.x.test',
        'trailing.test',
      ]) {
        expect(
          policy.sanitize('https://$host/story.webp'),
          isNull,
          reason: host,
        );
      }
    });
  });
}
