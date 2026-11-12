import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';

const hosted = 'https://kingdom-kids-checkout-staging.onrender.com/api';
const local = 'http://192.168.1.114:8100/api';
const session = AuthSession(
  parent: ParentAccount(id: 'hosted-parent', email: 'parent@example.test'),
  accessToken: 'synthetic-hosted-access',
  refreshToken: 'synthetic-hosted-refresh',
  profiles: [
    KidProfile(
      id: 'hosted-child',
      parentId: 'hosted-parent',
      displayName: 'Child',
      avatarKey: 'lion',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'unbound local credentials and child remain untouched and never restore on hosted origin',
    () async {
      final legacy = jsonEncode(session.toJson());
      FlutterSecureStorage.setMockInitialValues({
        'kingdom_kids.auth_session': legacy,
        'kingdom_kids.selected_kid_id': 'legacy-child',
        'kingdom_kids.has_launched': '1',
        'kingdom_kids.unrelated_progress': 'synthetic-progress',
      });
      const secure = FlutterSecureStorage();
      final store = SecureAuthSessionStore(apiBaseUrl: hosted);
      expect(await store.readSession(), isNull);
      expect(await store.readSelectedKidId(), isNull);
      await store.writeSession(session);
      await store.writeSelectedKidId('hosted-child');
      await store.clear();
      expect(await secure.read(key: 'kingdom_kids.auth_session'), legacy);
      expect(
        await secure.read(key: 'kingdom_kids.selected_kid_id'),
        'legacy-child',
      );
      expect(await secure.read(key: 'kingdom_kids.has_launched'), '1');
      expect(
        await secure.read(key: 'kingdom_kids.unrelated_progress'),
        'synthetic-progress',
      );
    },
  );

  test(
    'sessions and selected children stay isolated across host, scheme, port and API prefix',
    () async {
      final original = SecureAuthSessionStore(apiBaseUrl: hosted);
      await original.writeSession(session);
      await original.writeSelectedKidId('hosted-child');
      for (final base in [
        local,
        'http://kingdom-kids-checkout-staging.onrender.com/api',
        'https://kingdom-kids-checkout-staging.onrender.com:8443/api',
        'https://kingdom-kids-checkout-staging.onrender.com/api/v2',
        'https://different.example.test/api',
      ]) {
        final other = SecureAuthSessionStore(apiBaseUrl: base);
        expect(await other.readSession(), isNull, reason: base);
        expect(await other.readSelectedKidId(), isNull, reason: base);
        await other.clear();
      }
      expect((await original.readSession())?.accessToken, session.accessToken);
      expect(await original.readSelectedKidId(), 'hosted-child');
    },
  );

  test(
    'equivalent root, slash, hostname case and default-port configurations resume same hosted session',
    () async {
      final first = SecureAuthSessionStore(apiBaseUrl: hosted);
      await first.writeSession(session);
      await first.writeSelectedKidId('hosted-child');
      for (final base in [
        '$hosted/',
        'https://KINGDOM-KIDS-CHECKOUT-STAGING.ONRENDER.COM:443/api',
        'https://kingdom-kids-checkout-staging.onrender.com',
      ]) {
        final returning = SecureAuthSessionStore(apiBaseUrl: base);
        expect((await returning.readSession())?.parent.id, 'hosted-parent');
        expect(await returning.readSelectedKidId(), 'hosted-child');
      }
    },
  );

  test(
    'default configured API cannot dispatch legacy tokens and signs in only at its configured endpoint',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'kingdom_kids.auth_session': jsonEncode(session.toJson()),
        'kingdom_kids.selected_kid_id': 'legacy-child',
      });
      var calls = 0;
      final repository = AuthRepository(
        api: HttpAuthApi(
          client: MockClient((request) async {
            calls++;
            expect(request.url, AppConfig.resolveApiUri('accounts/login/'));
            expect(request.headers.containsKey('Authorization'), isFalse);
            return http.Response(jsonEncode(session.toJson()), 200);
          }),
        ),
      );
      expect(await repository.restoreSession(), isNull);
      await expectLater(
        repository.withAccessToken((_) async {
          calls++;
        }),
        throwsA(anything),
      );
      expect(calls, 0);
      await repository.login(
        const LoginRequest(
          email: 'parent@example.test',
          password: 'synthetic-password',
        ),
      );
      expect(calls, 1);
      expect((await repository.restoreSession())?.parent.id, 'hosted-parent');
      expect(
        await const FlutterSecureStorage().read(
          key: 'kingdom_kids.selected_kid_id',
        ),
        'legacy-child',
      );
    },
  );
}
