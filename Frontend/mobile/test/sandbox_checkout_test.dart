import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/subscription/data/sandbox_checkout.dart';
import 'package:mobile/features/subscription/domain/subscription_plan.dart';
import 'package:mobile/features/subscription/presentation/subscription_parent_screen.dart';
import 'package:mobile/features/subscription/presentation/subscription_screen.dart';

const _configuration = SandboxCheckoutConfiguration(
  enabled: true,
  apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
);
const _kid = KidProfile(
  id: 'kid-1',
  parentId: '42',
  displayName: 'Maya',
  avatarKey: 'dove',
);
const _session = AuthSession(
  parent: ParentAccount(id: '42', email: 'parent@example.test'),
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
  profiles: [_kid],
);

Map<String, Object?> _payload({
  String state = 'unpaid',
  bool available = true,
}) => {
  'schema_version': 1,
  'parent_id': '42',
  'environment': 'sandbox',
  'evaluated_at': '2026-11-12T10:00:00+00:00',
  'access_state': state,
  'access_until': state == 'paid' ? '2026-12-12T10:00:00+00:00' : null,
  'parent_plan_routing_enabled': available,
  'checkout': {
    'state': available ? 'available' : 'unavailable',
    'reason_code': available ? 'sandbox_only' : 'not_enrolled',
  },
};

SandboxContentAccess _access({
  SandboxAccessState state = SandboxAccessState.unpaid,
  bool available = true,
}) => SandboxContentAccess(
  parentId: '42',
  state: state,
  checkoutAvailable: available,
);

void main() {
  test('sandbox requires explicit opt-in and the exact approved HTTPS API', () {
    expect(
      const SandboxCheckoutConfiguration(
        apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
      ).isEnabled,
      isFalse,
    );
    for (final base in [
      'http://kingdom-kids-checkout-staging.onrender.com/api',
      'https://kingdom-kids-checkout-staging.onrender.com.evil.test/api',
      'https://kingdom-kids-checkout-staging.onrender.com:444/api',
      'https://name:secret@kingdom-kids-checkout-staging.onrender.com/api',
      '${SandboxCheckoutConfiguration.approvedApiBaseUrl}?token=secret',
      '${SandboxCheckoutConfiguration.approvedApiBaseUrl}#token',
      '${SandboxCheckoutConfiguration.approvedApiBaseUrl}/',
      'https://kingdom-kids-checkout-staging.onrender.com/api/../api',
      'https://other-deployment.test/api',
    ]) {
      expect(
        SandboxCheckoutConfiguration(enabled: true, apiBaseUrl: base).isEnabled,
        isFalse,
        reason: base,
      );
    }
    expect(_configuration.isEnabled, isTrue);
  });

  test('server access state and checkout capability remain independent', () {
    for (final state in SandboxAccessState.values) {
      final parsed = SandboxContentAccess.fromJson(
        _payload(state: state.name),
        expectedParentId: '42',
      );
      expect(parsed.state, state);
      expect(parsed.checkoutAvailable, isTrue);
    }
    final unenrolled = SandboxContentAccess.fromJson(
      _payload(state: 'paid', available: false),
      expectedParentId: '42',
    );
    expect(unenrolled.state, SandboxAccessState.paid);
    expect(unenrolled.checkoutAvailable, isFalse);
    for (final change in [
      {'parent_plan_routing_enabled': false},
      {
        'checkout': {'state': 'available', 'reason_code': 'production'},
      },
      {'checkout': null},
    ]) {
      expect(
        SandboxContentAccess.fromJson({
          ..._payload(),
          ...change,
        }, expectedParentId: '42').checkoutAvailable,
        isFalse,
      );
    }
  });

  test(
    'checkout destination accepts only the selected plan enum at the fixed origin',
    () {
      for (final period in SubscriptionBillingPeriod.values) {
        final uri = SandboxCheckoutConfiguration.checkoutUri(period);
        expect(uri.scheme, 'https');
        expect(uri.host, 'kingdom-kids-checkout-staging.onrender.com');
        expect(uri.path, '/parent/checkout/');
        expect(uri.userInfo, isEmpty);
        expect(uri.hasFragment, isFalse);
        expect(uri.queryParameters, {'plan': period.name});
        expect(uri.queryParametersAll.values, everyElement(hasLength(1)));
      }
    },
  );

  test(
    'wrong identity, environment, schema and invalid paid proof fail closed',
    () {
      for (final change in [
        {'parent_id': 'another-parent'},
        {'schema_version': 2},
        {'environment': 'production'},
        {'access_state': 'success'},
        {'evaluated_at': '2026-11-12T10:00:00'},
        {'access_state': 'paid', 'access_until': null},
        {'access_state': 'paid', 'access_until': '2026-11-11T10:00:00Z'},
      ]) {
        expect(
          () => SandboxContentAccess.fromJson({
            ..._payload(),
            ...change,
          }, expectedParentId: '42'),
          throwsFormatException,
          reason: change.toString(),
        );
      }
    },
  );

  test(
    'canonical read uses bearer header without redirect or child mutation',
    () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      await store.writeSelectedKidId(_kid.id);
      final repository = AuthenticatedSandboxContentAccessRepository(
        configuration: _configuration,
        authRepository: AuthRepository(sessionStore: store),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            '${SandboxCheckoutConfiguration.approvedApiBaseUrl}/billing/content-access/',
          );
          expect(request.url.hasQuery, isFalse);
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer old-access');
          return http.Response(jsonEncode(_payload()), 200);
        }),
      );
      addTearDown(repository.dispose);
      expect((await repository.fetch()).state, SandboxAccessState.unpaid);
      expect(await store.readSession(), same(_session));
      expect(await store.readSelectedKidId(), _kid.id);
    },
  );

  for (final signedOut in [false, true]) {
    test(
      'late canonical result is discarded after ${signedOut ? 'sign out' : 'parent switch'}',
      () async {
        final store = MemoryAuthSessionStore();
        await store.writeSession(_session);
        final requested = Completer<void>();
        final response = Completer<http.Response>();
        final repository = AuthenticatedSandboxContentAccessRepository(
          configuration: _configuration,
          authRepository: AuthRepository(sessionStore: store),
          client: MockClient((request) {
            requested.complete();
            return response.future;
          }),
        );
        addTearDown(repository.dispose);
        final result = repository.fetch();
        await requested.future;
        if (signedOut) {
          await store.clear();
        } else {
          await store.writeSession(
            _session.copyWith(
              parent: const ParentAccount(
                id: '43',
                email: 'other@example.test',
              ),
            ),
          );
        }
        final expectation = expectLater(result, throwsException);
        response.complete(
          http.Response(jsonEncode(_payload(state: 'paid')), 200),
        );
        await expectation;
      },
    );
  }

  test(
    'canonical 401 follows existing token refresh and preserves active child',
    () async {
      final store = MemoryAuthSessionStore();
      await store.writeSession(_session);
      await store.writeSelectedKidId(_kid.id);
      final auth = AuthRepository(
        sessionStore: store,
        api: HttpAuthApi(
          baseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
          client: MockClient((request) async {
            expect(request.url.path, '/api/accounts/token/refresh/');
            return http.Response(
              jsonEncode({'access': 'new-access', 'refresh': 'new-refresh'}),
              200,
            );
          }),
        ),
      );
      var reads = 0;
      final repository = AuthenticatedSandboxContentAccessRepository(
        configuration: _configuration,
        authRepository: auth,
        client: MockClient((request) async {
          reads++;
          if (reads == 1) return http.Response('{}', 401);
          expect(request.headers['Authorization'], 'Bearer new-access');
          return http.Response(jsonEncode(_payload()), 200);
        }),
      );
      addTearDown(repository.dispose);
      expect((await repository.fetch()).state, SandboxAccessState.unpaid);
      expect(reads, 2);
      expect((await store.readSession())?.parent.id, '42');
      expect((await store.readSession())?.profiles, [_kid]);
      expect(await store.readSelectedKidId(), _kid.id);
    },
  );

  test(
    'launch uses a constant browser URL and cannot grant paid access',
    () async {
      final repository = _ControlledRepository();
      final launches = <Uri>[];
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: repository,
        launcher: (uri) async {
          launches.add(uri);
          return true;
        },
      );
      addTearDown(controller.dispose);
      final first = controller.refresh();
      repository.requests.single.complete(_access());
      await first;
      final opening = controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      expect(launches, isEmpty);
      repository.requests.last.complete(_access());
      await opening;
      expect(
        launches.single.toString(),
        '${SandboxCheckoutConfiguration.checkoutUrl}?plan=monthly',
      );
      expect(launches.single.userInfo, isEmpty);
      expect(launches.single.queryParameters, {'plan': 'monthly'});
      expect(launches.single.hasFragment, isFalse);
      expect(controller.access?.state, SandboxAccessState.unpaid);
    },
  );

  test(
    'background invalidates paid status and resumed failure stays unknown',
    () async {
      final repository = _ControlledRepository();
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: repository,
      );
      addTearDown(controller.dispose);
      final first = controller.refresh();
      repository.requests.single.complete(
        _access(state: SandboxAccessState.paid),
      );
      await first;
      controller.background();
      expect(controller.access, isNull);
      expect(controller.canOpen, isFalse);
      final resumed = controller.resume();
      repository.requests.last.completeError(
        const FormatException('network failure'),
      );
      await resumed;
      expect(controller.access, isNull);
      expect(controller.error, contains('unknown'));
      expect(controller.canOpen, isFalse);
    },
  );

  test(
    'paid access disables Proceed and a newly paid preflight cannot launch',
    () async {
      final repository = _ControlledRepository();
      var launches = 0;
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: repository,
        launcher: (_) async {
          launches++;
          return true;
        },
      );
      addTearDown(controller.dispose);
      final initial = controller.refresh();
      repository.requests.single.complete(_access());
      await initial;
      expect(controller.canOpen, isTrue);
      final opening = controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.yearly,
      );
      repository.requests.last.complete(
        _access(state: SandboxAccessState.paid),
      );
      await opening;
      expect(launches, 0);
      expect(controller.canOpen, isFalse);
      final reads = repository.requests.length;
      await controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      expect(repository.requests.length, reads);
      expect(launches, 0);
    },
  );

  testWidgets(
    'Proceed passes the native monthly and yearly choices without changing the plan UI',
    (tester) async {
      final launches = <Uri>[];
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: _ImmediateRepository(),
        launcher: (uri) async {
          launches.add(uri);
          return true;
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionScreen(sandboxCheckout: controller)),
      );
      await tester.tap(find.byKey(const Key('subscription-parent-continue')));
      await tester.pumpAndSettle();
      expect(launches.single.queryParameters, {'plan': 'monthly'});
      await tester.ensureVisible(find.byKey(const Key('subscription-yearly')));
      await tester.tap(find.byKey(const Key('subscription-yearly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('subscription-parent-continue')));
      await tester.pumpAndSettle();
      expect(launches.last.queryParameters, {'plan': 'yearly'});
      expect(find.text('Proceed'), findsOneWidget);
    },
  );

  testWidgets(
    'active sandbox access has no financial Proceed and parent settings remain reachable',
    (tester) async {
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: _ImmediateRepository()..state = SandboxAccessState.paid,
        launcher: (_) async =>
            fail('Paid access must not open another payment.'),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionScreen(sandboxCheckout: controller)),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('subscription-parent-continue')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('Access active.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('subscription-billing-details')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Parent account settings'));
      expect(
        find.text('Parent account settings').hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets('platform launch requests an external system browser', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final controller = SandboxCheckoutController(
      configuration: _configuration,
      repository: _ImmediateRepository(),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await controller.openCheckout(
      billingPeriod: SubscriptionBillingPeriod.yearly,
    );
    expect(calls, hasLength(1));
    expect(calls.single.method, 'launch');
    final arguments = calls.single.arguments as Map;
    expect(
      arguments['url'],
      '${SandboxCheckoutConfiguration.checkoutUrl}?plan=yearly',
    );
    expect(arguments['useSafariVC'], isFalse);
    expect(arguments['useWebView'], isFalse);
    expect(arguments['headers'], isEmpty);
  });

  test(
    'old launch preflight cannot reopen browser after background and resume',
    () async {
      final repository = _ControlledRepository();
      var launches = 0;
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: repository,
        launcher: (_) async {
          launches++;
          return true;
        },
      );
      addTearDown(controller.dispose);
      final first = controller.refresh();
      repository.requests.single.complete(_access());
      await first;
      final opening = controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      final oldPreflight = repository.requests.last;
      controller.background();
      final resumed = controller.resume();
      repository.requests.last.complete(_access());
      await resumed;
      oldPreflight.complete(_access());
      await opening;
      expect(launches, 0);
    },
  );

  testWidgets(
    'stable route refreshes on resume while parent gate remains locked',
    (tester) async {
      final repository = _ImmediateRepository();
      final auth = _GateAuthRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionParentScreen(
            configuration: _configuration,
            authRepository: auth,
            accessRepository: repository,
            browserLauncher: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.reads, 1);
      await _unlock(tester);
      expect(
        find.byKey(const Key('subscription-sandbox-notice')),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      expect(find.byType(SubscriptionScreen), findsNothing);
      repository.state = SandboxAccessState.paid;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(repository.reads, 2);
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      await _unlock(tester);
      expect(find.textContaining('Access active.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('disabled and wrong-origin routes never read sandbox access', (
    tester,
  ) async {
    for (final configuration in [
      const SandboxCheckoutConfiguration(),
      const SandboxCheckoutConfiguration(
        enabled: true,
        apiBaseUrl: 'https://other.test/api',
      ),
    ]) {
      final repository = _ImmediateRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionParentScreen(
            key: UniqueKey(),
            configuration: configuration,
            authRepository: _GateAuthRepository(),
            accessRepository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _unlock(tester);
      expect(repository.reads, 0);
      expect(find.text('Checkout unavailable'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('review remains read-only with a ready sandbox controller', (
    tester,
  ) async {
    final controller = SandboxCheckoutController(
      configuration: _configuration,
      repository: _ImmediateRepository(),
      launcher: (_) async => fail('A preview must never launch checkout.'),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionScreen(reviewMode: true, sandboxCheckout: controller),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('subscription-parent-continue')),
          )
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('subscription-sandbox-notice')), findsNothing);
  });

  testWidgets('sandbox notice and parent controls fit 320px at 2.2x type', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final state in SandboxAccessState.values) {
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: _ImmediateRepository()..state = state,
      );
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2.2)),
            child: child!,
          ),
          home: SubscriptionScreen(
            key: UniqueKey(),
            sandboxCheckout: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('subscription-back')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('subscription-billing-details')),
      );
      expect(
        find.byKey(const Key('subscription-billing-details')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('subscription-check-access')),
      );
      expect(
        find.byKey(const Key('subscription-check-access')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('subscription-billing-details')),
      );
      await tester.tap(find.byKey(const Key('subscription-billing-details')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Parent account settings'));
      expect(
        find.text('Parent account settings').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });
}

Future<void> _unlock(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('adult-gate-password')),
    'test password',
  );
  await tester.tap(find.byKey(const Key('adult-gate-submit')));
  await tester.pumpAndSettle();
}

class _ControlledRepository implements SandboxContentAccessRepository {
  final requests = <Completer<SandboxContentAccess>>[];
  @override
  Future<SandboxContentAccess> fetch() {
    final request = Completer<SandboxContentAccess>();
    requests.add(request);
    return request.future;
  }
}

class _ImmediateRepository implements SandboxContentAccessRepository {
  int reads = 0;
  SandboxAccessState state = SandboxAccessState.unpaid;
  @override
  Future<SandboxContentAccess> fetch() async {
    reads++;
    return _access(state: state);
  }
}

class _GateAuthRepository extends AuthRepository {
  @override
  Future<void> reauthenticate(String password) async {}
}
