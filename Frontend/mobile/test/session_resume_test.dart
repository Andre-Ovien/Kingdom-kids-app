import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/splash/data/first_launch_store.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'fresh storage and repository instances resume the selected child locally',
    () async {
      final signIn = AuthRepository(
        sessionStore: SecureAuthSessionStore(),
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((request) async {
            expect(request.url.path, '/api/accounts/login/');
            return http.Response(
              jsonEncode({
                'parent': {'id': 'parent-1', 'email': 'parent@example.test'},
                'access': 'test-access',
                'refresh': 'test-refresh',
                'profiles': [
                  {
                    'id': 'kid-1',
                    'parent_id': 'parent-1',
                    'display_name': 'First child',
                    'avatar_key': 'lion',
                  },
                  {
                    'id': 'kid-2',
                    'parent_id': 'parent-1',
                    'display_name': 'Selected child',
                    'avatar_key': 'dove',
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );

      final signedIn = await signIn.login(
        const LoginRequest(
          email: 'parent@example.test',
          password: 'Local-test-password',
        ),
      );
      await signIn.selectKid(signedIn.profiles.last);

      var startupNetworkRequests = 0;
      final returning = AuthRepository(
        sessionStore: SecureAuthSessionStore(),
        api: HttpAuthApi(
          baseUrl: 'https://kingdom-kids.test/api',
          client: MockClient((_) async {
            startupNetworkRequests++;
            throw StateError('Restoring the saved session must remain local.');
          }),
        ),
      );
      // Use a fresh launch-store wrapper too. A preserved account must take
      // precedence even if this installation's welcome flag is absent.
      final destination = await StartupDestinationResolver(
        authRepository: returning,
        firstLaunchStore: SecureFirstLaunchStore(),
      ).resolve();

      expect(destination.route, AppRoutes.home);
      expect((await returning.currentKid())?.id, 'kid-2');
      final restored = await returning.restoreSession();
      expect(restored?.accessToken, 'test-access');
      expect(restored?.refreshToken, 'test-refresh');
      expect(restored?.profiles.length, 2);
      expect(startupNetworkRequests, 0);
    },
  );
}
