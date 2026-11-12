import 'package:flutter_test/flutter_test.dart';

import '../tool/validate_release_config.dart' as release_tool;

void main() {
  test('release tool accepts public API and media hosts', () {
    expect(
      () => release_tool.validateReleaseConfiguration(const [
        'https://api.kingdom-kids.app/api',
        'media.kingdom-kids.app,audio.kingdom-kids.app',
      ]),
      returnsNormally,
    );
  });

  test('release tool permits API-host-only media configuration', () {
    expect(
      () => release_tool.validateReleaseConfiguration(const [
        'https://api.kingdom-kids.app/api',
        '',
      ]),
      returnsNormally,
    );
  });

  test('release tool rejects local and non-public API endpoints', () {
    const rejectedUrls = [
      'https://localhost/api',
      'https://api.localhost/api',
      'https://host.docker.internal/api',
      'https://10.0.2.2/api',
      'https://0.0.0.0/api',
      'https://127.0.0.1/api',
      'https://169.254.1.2/api',
      'https://10.1.2.3/api',
      'https://172.20.1.2/api',
      'https://192.168.1.2/api',
      'https://[::]/api',
      'https://[::1]/api',
      'https://[fe80::1]/api',
      'https://[fc00::1]/api',
      'https://[::ffff:10.1.2.3]/api',
    ];

    for (final apiUrl in rejectedUrls) {
      expect(
        () => release_tool.validateReleaseConfiguration([
          apiUrl,
          'media.kingdom-kids.app',
        ]),
        throwsA(isA<release_tool.ReleaseConfigurationException>()),
        reason: apiUrl,
      );
    }
  });

  test('release tool rejects non-public configured media hosts', () {
    for (final mediaHost in const [
      'localhost',
      'assets.localhost',
      'host.docker.internal',
      '10.0.2.2',
      '169.254.1.2',
      '172.16.1.2',
      '192.168.1.2',
    ]) {
      expect(
        () => release_tool.validateReleaseConfiguration([
          'https://api.kingdom-kids.app/api',
          mediaHost,
        ]),
        throwsA(isA<release_tool.ReleaseConfigurationException>()),
        reason: mediaHost,
      );
    }
  });

  test('release tool rejects malformed configured media hostnames', () {
    for (final mediaHost in const [
      'double..dot.test',
      '_service.test',
      '-leading.test',
      'trailing-.test',
      '*.kingdom-kids.app',
      'media.kingdom-kids.app.',
      'https://media.kingdom-kids.app',
      'media.kingdom-kids.app:443',
    ]) {
      expect(
        () => release_tool.validateReleaseConfiguration([
          'https://api.kingdom-kids.app/api',
          mediaHost,
        ]),
        throwsA(isA<release_tool.ReleaseConfigurationException>()),
        reason: mediaHost,
      );
    }
  });
}
