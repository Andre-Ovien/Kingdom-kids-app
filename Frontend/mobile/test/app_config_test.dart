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
  });
}
