import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/errors/app_exception.dart';

void main() {
  group('AppException.userMessage', () {
    test('keeps a friendly service message', () {
      const error = AppException('The story library is taking a little nap.');

      expect(error.userMessage, 'The story library is taking a little nap.');
    });

    test('turns connection and timeout errors into friendly guidance', () {
      const network = AppException(
        'SocketException: Connection refused',
        code: 'network_error',
      );
      const timeout = AppException(
        'TimeoutException after 0:00:15',
        code: 'request_timeout',
      );

      expect(network.userMessage, contains('Check your internet'));
      expect(timeout.userMessage, contains('taking longer'));
    });

    test('never exposes status codes or server failures', () {
      const missing = AppException(
        'HTTP 404 Not Found at /api/stories/nope/',
        statusCode: 404,
      );
      const server = AppException(
        '<html><h1>Internal Server Error</h1></html>',
        statusCode: 500,
      );

      expect(missing.userMessage, isNot(contains('404')));
      expect(missing.userMessage, contains('unavailable'));
      expect(server.userMessage, isNot(contains('500')));
      expect(server.userMessage, contains('try again soon'));
    });

    test('hides technical payloads even without a status code', () {
      const error = AppException(
        '{"detail":"TypeError: null check operator used on a null value"}',
      );

      expect(error.userMessage, 'Something went wrong. Please try again.');
    });

    test('hides backend field names', () {
      const error = AppException(
        'operation_id was already used for a different submission',
        statusCode: 409,
      );

      expect(error.userMessage, 'Something went wrong. Please try again.');
    });

    test('keeps approved sign-in guidance while hiding the raw response', () {
      const error = AppException(
        'No active account found with the given credentials',
        code: 'invalid_credentials',
        statusCode: 401,
      );

      expect(
        error.userMessage,
        'That email or password did not match our records.',
      );
    });
  });
}
