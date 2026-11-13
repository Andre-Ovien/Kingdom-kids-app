import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/splash/data/first_launch_store.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/features/splash/presentation/splash_screen.dart';
import 'package:mobile/features/subscription/data/hosted_access_routing.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_repository.dart';
import 'package:mobile/features/subscription/data/sandbox_checkout.dart';

const _configuration = SandboxCheckoutConfiguration(
  productionEnabled: true,
  hostedSubscriptionsEnabled: true,
  paymentEnvironment: 'production',
  apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionApiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionCheckoutUrl: SandboxCheckoutConfiguration.checkoutUrl,
);
const _kid = KidProfile(
  id: 'child-1',
  parentId: 'parent-1',
  displayName: 'First child',
  avatarKey: 'lion',
);
const _session = AuthSession(
  parent: ParentAccount(id: 'parent-1', email: 'parent@example.test'),
  accessToken: 'fixture-access',
  refreshToken: 'fixture-refresh',
  profiles: [_kid],
);

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets(
      'saved paid family survives a slow access lookup (reduced motion: $reducedMotion)',
      (tester) async {
        final response = Completer<http.Response>();
        final fixture = await _fixture((_) => response.future);
        await tester.pumpWidget(
          _app(fixture.resolver, reducedMotion: reducedMotion),
        );
        await tester.pump();

        await tester.pump(const Duration(seconds: 6));
        expect(
          find.byKey(const Key('cinematic-splash-screen')),
          findsOneWidget,
        );
        expect(find.text('destination:${AppRoutes.login}'), findsNothing);
        expect(find.text('destination:${AppRoutes.home}'), findsNothing);
        expect(
          fixture.requests.single.url.path,
          '/api/billing/content-access/',
        );

        response.complete(_access('paid'));
        await tester.pumpAndSettle();
        expect(find.text('destination:${AppRoutes.home}'), findsOneWidget);
        expect(await fixture.store.readSession(), same(_session));
        expect(await fixture.store.readSelectedKidId(), _kid.id);
        expect(fixture.requests, hasLength(1));
      },
    );
  }

  testWidgets(
    'access request timeout keeps saved parent on plans without child access',
    (tester) async {
      final response = Completer<http.Response>();
      final fixture = await _fixture(
        (_) => response.future,
        requestTimeout: const Duration(seconds: 7),
      );
      await tester.pumpWidget(_app(fixture.resolver));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(
        find.text('destination:${AppRoutes.subscription}'),
        findsOneWidget,
      );
      expect(find.text('destination:${AppRoutes.login}'), findsNothing);
      expect(find.text('destination:${AppRoutes.home}'), findsNothing);
      expect(await fixture.store.readSession(), same(_session));
      expect(await fixture.store.readSelectedKidId(), _kid.id);
      response.complete(_access('paid'));
      await tester.pumpAndSettle();
      expect(
        find.text('destination:${AppRoutes.subscription}'),
        findsOneWidget,
      );
      expect(find.text('destination:${AppRoutes.home}'), findsNothing);
    },
  );

  for (final state in ['unpaid', 'unknown']) {
    test(
      'canonical $state saved parent goes to plans, preserving family',
      () async {
        final fixture = await _fixture((_) async => _access(state));
        expect(
          (await fixture.resolver.resolve()).route,
          AppRoutes.subscription,
        );
        expect(await fixture.store.readSession(), same(_session));
        expect(await fixture.store.readSelectedKidId(), _kid.id);
        expect(fixture.requests.single.method, 'GET');
      },
    );
  }

  test(
    'network outage keeps saved parent at plans instead of sign-in',
    () async {
      final fixture = await _fixture(
        (_) async => throw http.ClientException('Offline'),
      );
      expect((await fixture.resolver.resolve()).route, AppRoutes.subscription);
      expect(await fixture.store.readSession(), same(_session));
      expect(await fixture.store.readSelectedKidId(), _kid.id);
    },
  );

  for (final status in [400, 401]) {
    test(
      'authoritative refresh rejection $status still requires sign-in',
      () async {
        final fixture = await _fixture((request) async {
          if (request.url.path == '/api/accounts/token/refresh/') {
            return http.Response(jsonEncode({'detail': 'Rejected'}), status);
          }
          expect(request.url.path, '/api/billing/content-access/');
          return http.Response(jsonEncode({'code': 'token_not_valid'}), 401);
        });
        expect((await fixture.resolver.resolve()).route, AppRoutes.login);
        expect(await fixture.store.readSession(), isNull);
        expect(await fixture.store.readSelectedKidId(), isNull);
        expect(fixture.requests.map((r) => r.method), ['GET', 'POST']);
      },
    );
  }

  testWidgets(
    'a delayed old-parent status cannot route into either child shell',
    (tester) async {
      final response = Completer<http.Response>();
      final fixture = await _fixture((_) => response.future);
      await tester.pumpWidget(_app(fixture.resolver));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.requests, hasLength(1));
      const replacement = AuthSession(
        parent: ParentAccount(id: 'parent-2', email: 'other@example.test'),
        accessToken: 'other-access',
        refreshToken: 'other-refresh',
        profiles: [],
      );
      await fixture.store.writeSession(replacement);
      response.complete(_access('paid'));
      await tester.pumpAndSettle();

      expect(find.text('destination:${AppRoutes.login}'), findsOneWidget);
      expect(find.text('destination:${AppRoutes.home}'), findsNothing);
      expect(await fixture.store.readSession(), same(replacement));
    },
  );

  test(
    'paid startup never selects a child missing from the saved family',
    () async {
      final fixture = await _fixture((_) async => _access('paid'));
      await fixture.store.writeSelectedKidId('another-familys-child');
      final destination = await fixture.resolver.resolve();
      expect(destination.route, AppRoutes.profilePicker);
      expect(destination.arguments, [_kid]);
    },
  );
}

http.Response _access(String state) => http.Response(
  jsonEncode({
    'schema_version': 1,
    'parent_id': _session.parent.id,
    'environment': 'production',
    'evaluated_at': DateTime.now().toUtc().toIso8601String(),
    'access_state': state,
    'access_until': state == 'paid'
        ? DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String()
        : null,
    'content_enforcement_enabled': true,
    'parent_plan_routing_enabled': true,
    'checkout': {
      'state': 'available',
      'provider': 'square_hosted',
      'reason_code': 'production_hosted',
    },
  }),
  200,
);

Future<_Fixture> _fixture(
  Future<http.Response> Function(http.Request) handle, {
  Duration requestTimeout = const Duration(seconds: 20),
}) async {
  final requests = <http.Request>[];
  final client = MockClient((request) {
    requests.add(request);
    return handle(request);
  });
  addTearDown(client.close);
  final store = MemoryAuthSessionStore();
  await store.writeSession(_session);
  await store.writeSelectedKidId(_kid.id);
  final auth = AuthRepository(
    api: HttpAuthApi(baseUrl: _configuration.apiBaseUrl, client: client),
    sessionStore: store,
  );
  final repository = HttpHostedSubscriptionRepository(
    configuration: _configuration,
    authRepository: auth,
    client: client,
    timeout: requestTimeout,
  );
  final resolver = StartupDestinationResolver(
    authRepository: auth,
    firstLaunchStore: MemoryFirstLaunchStore(launched: true),
    accessRouting: HostedAccessRouting(
      configuration: _configuration,
      authRepository: auth,
      repository: repository,
    ),
  );
  return _Fixture(store, resolver, requests);
}

class _Fixture {
  const _Fixture(this.store, this.resolver, this.requests);
  final MemoryAuthSessionStore store;
  final StartupDestinationResolver resolver;
  final List<http.Request> requests;
}

Widget _app(
  StartupDestinationResolver resolver, {
  bool reducedMotion = false,
}) => MaterialApp(
  initialRoute: AppRoutes.splash,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
    child: child!,
  ),
  onGenerateRoute: (settings) => MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => settings.name == AppRoutes.splash
        ? SplashScreen(destinationResolver: resolver)
        : Scaffold(body: Text('destination:${settings.name}')),
  ),
);
