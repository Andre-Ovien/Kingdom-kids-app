import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/network/paid_content_access_state.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/splash/data/first_launch_store.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/features/subscription/data/hosted_access_routing.dart';
import 'package:mobile/features/subscription/data/hosted_checkout_pending_store.dart';
import 'package:mobile/features/subscription/data/hosted_startup_access_recovery.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_controller.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_repository.dart';
import 'package:mobile/features/subscription/data/sandbox_checkout.dart';
import 'package:mobile/features/subscription/domain/subscription_plan.dart';
import 'package:mobile/features/subscription/presentation/hosted_paid_route_boundary.dart';
import 'package:mobile/features/subscription/presentation/hosted_subscription_scope.dart';

const _configuration = SandboxCheckoutConfiguration(
  productionEnabled: true,
  hostedSubscriptionsEnabled: true,
  paymentEnvironment: 'production',
  apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionApiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionCheckoutUrl: SandboxCheckoutConfiguration.checkoutUrl,
);
const _first = KidProfile(
  id: 'first-child',
  parentId: 'parent-1',
  displayName: 'First',
  avatarKey: 'lion',
);
const _second = KidProfile(
  id: 'second-child',
  parentId: 'parent-1',
  displayName: 'Second',
  avatarKey: 'dove',
);
const _session = AuthSession(
  parent: ParentAccount(id: 'parent-1', email: 'parent@example.test'),
  accessToken: 'fixture-access',
  refreshToken: 'fixture-refresh',
  profiles: [_first, _second],
);

void main() {
  testWidgets(
    'paid startup survives a failed independent controller check and retry',
    (tester) async {
      final late = Completer<http.Response>();
      final f = await _fixture(
        controller: (index, _) async {
          if (index == 0) throw http.ClientException('Offline fixture');
          return late.future;
        },
      );
      await _start(tester, f);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(f.observer.top?.name, AppRoutes.home);
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      expect(find.text('Owned child:first-child'), findsNothing);

      late.complete(_access());
      await tester.pumpAndSettle();
      expect(find.text('Owned child:first-child'), findsOneWidget);
      expect(find.byKey(const Key('adult-gate-screen')), findsNothing);
      expect(f.controllerReads, 2);
      expect(f.startupReads, 1);
      expect(f.parentPasswordChecks, 0);
      await _finish(tester, f);
    },
  );

  for (final readyBeforePlans in [true, false]) {
    testWidgets(
      'startup fallback recovers owned access without unlocking parents (ready first: $readyBeforePlans)',
      (tester) async {
        final late = Completer<http.Response>();
        final f = await _fixture(
          startup: (_) async => throw http.ClientException('Offline fixture'),
          controller: (_, _) =>
              readyBeforePlans ? Future.value(_access()) : late.future,
        );
        await _start(tester, f);
        await tester.pump(const Duration(milliseconds: 1800));
        await tester.pumpAndSettle();
        if (!readyBeforePlans) {
          expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
          expect(find.text('Owned child:first-child'), findsNothing);
          late.complete(_access());
          await tester.pumpAndSettle();
        }
        expect(f.observer.top?.name, AppRoutes.home);
        expect(
          f.observer.history.any(
            (route) =>
                route.name == AppRoutes.subscription &&
                route.arguments is HostedStartupAccessRecovery,
          ),
          isTrue,
        );
        expect(find.text('Owned child:first-child'), findsOneWidget);
        expect(find.byKey(const Key('adult-gate-screen')), findsNothing);
        expect(f.parentPasswordChecks, 0);
        expect(f.checkout.successSequence, 0);
        // Recovering content does not authorize a subsequent parent-area visit.
        f.navigator.currentState!.pushNamed(AppRoutes.parentalControls);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
        expect(find.text('Parent settings'), findsWidgets);
        expect(f.parentPasswordChecks, 0);
        await _finish(tester, f);
      },
    );
  }

  testWidgets('unknown outage is bounded and never reveals child content', (
    tester,
  ) async {
    final f = await _fixture(
      startup: (_) async => throw http.ClientException('Offline fixture'),
      controller: (_, _) async => throw http.ClientException('Offline fixture'),
    );
    await _start(tester, f);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(f.controllerReads, 3);
    expect(f.observer.top?.name, AppRoutes.subscription);
    expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
    expect(find.textContaining('Owned child:'), findsNothing);
    expect((await f.sessions.readSession())?.parent.id, 'parent-1');
    expect(f.parentPasswordChecks, 0);
    await _finish(tester, f);
  });

  for (final state in ['unpaid', 'expired']) {
    testWidgets('canonical $state access never reveals child content', (
      tester,
    ) async {
      final f = await _fixture(
        startup: (_) async => _access(
          state: state == 'expired' ? 'paid' : 'unpaid',
          expired: state == 'expired',
        ),
        controller: (_, _) async => _access(
          state: state == 'expired' ? 'paid' : 'unpaid',
          expired: state == 'expired',
        ),
      );
      await _start(tester, f);
      final initialReads = f.controllerReads;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(f.controllerReads, state == 'expired' ? 3 : initialReads);
      expect(f.observer.top?.name, AppRoutes.subscription);
      expect(find.textContaining('Owned child:'), findsNothing);
      expect(f.checkout.canBrowse, isFalse);
      await _finish(tester, f);
    });
  }

  testWidgets(
    'authoritative rejected authentication goes to sign-in, not recovery',
    (tester) async {
      final f = await _fixture(
        startup: (_) async => http.Response('{"code":"token_not_valid"}', 401),
        controller: (_, _) async =>
            http.Response('{"code":"token_not_valid"}', 401),
        rejectRefresh: true,
      );
      await _start(tester, f);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(f.observer.top?.name, AppRoutes.login);
      expect(await f.sessions.readSession(), isNull);
      expect(find.textContaining('Owned child:'), findsNothing);
      await _finish(tester, f);
    },
  );

  testWidgets('old parent late proof cannot consume the new parent session', (
    tester,
  ) async {
    final late = Completer<http.Response>();
    final f = await _fixture(
      startup: (_) async => throw http.ClientException('Offline fixture'),
      controller: (_, _) => late.future,
    );
    await _start(tester, f);
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pumpAndSettle();
    const other = AuthSession(
      parent: ParentAccount(id: 'parent-2', email: 'other@example.test'),
      accessToken: 'other-access',
      refreshToken: 'other-refresh',
      profiles: [],
    );
    await f.sessions.writeSession(other);
    late.complete(_access());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.textContaining('Owned child:'), findsNothing);
    expect(await f.sessions.readSession(), same(other));
    expect(f.observer.top?.name, isNot(AppRoutes.home));
    await _finish(tester, f);
  });

  testWidgets(
    'background proof cannot navigate and a fresh resume can recover',
    (tester) async {
      final old = Completer<http.Response>();
      final f = await _fixture(
        startup: (_) async => throw http.ClientException('Offline fixture'),
        controller: (index, _) =>
            index == 0 ? old.future : Future.value(_access()),
      );
      await _start(tester, f);
      await tester.pump(const Duration(milliseconds: 1800));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      old.complete(_access());
      await tester.pumpAndSettle();
      expect(f.observer.top?.name, AppRoutes.subscription);
      expect(find.textContaining('Owned child:'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Owned child:first-child'), findsOneWidget);
      expect(f.parentPasswordChecks, 0);
      await _finish(tester, f);
    },
  );

  testWidgets(
    'a child switch during recovery resumes the current owned child',
    (tester) async {
      final old = Completer<http.Response>();
      final f = await _fixture(
        startup: (_) async => throw http.ClientException('Offline fixture'),
        controller: (index, _) =>
            index == 0 ? old.future : Future.value(_access()),
      );
      await _start(tester, f);
      await tester.pump(const Duration(milliseconds: 1800));
      await tester.pumpAndSettle();
      await f.auth.selectKid(_second);
      await tester.pumpAndSettle();
      old.complete(_access());
      await tester.pumpAndSettle();
      expect(find.text('Owned child:second-child'), findsOneWidget);
      expect(find.text('Owned child:first-child'), findsNothing);
      expect(await f.sessions.readSelectedKidId(), _second.id);
      expect(f.parentPasswordChecks, 0);
      await _finish(tester, f);
    },
  );

  for (final profiles in [
    const [_first, _second],
    const <KidProfile>[],
  ]) {
    testWidgets(
      'late access with ${profiles.length} profiles respects absent child selection',
      (tester) async {
        final f = await _fixture(
          startup: (_) async => throw http.ClientException('Offline fixture'),
          selected: 'deleted-child',
          profiles: profiles,
        );
        await _start(tester, f);
        await tester.pump(const Duration(milliseconds: 1800));
        await tester.pumpAndSettle();
        expect(
          f.observer.top?.name,
          profiles.isEmpty
              ? AppRoutes.kidProfileSetup
              : AppRoutes.profilePicker,
        );
        expect(find.textContaining('Owned child:'), findsNothing);
        if (profiles.isNotEmpty) expect(f.observer.top?.arguments, profiles);
        expect(f.parentPasswordChecks, 0);
        await _finish(tester, f);
      },
    );
  }

  testWidgets(
    'manual plans and parent settings never consume startup recovery',
    (tester) async {
      for (final entry in [
        (route: AppRoutes.subscription, arguments: null),
        (
          route: AppRoutes.subscription,
          arguments: {'parentId': 'parent-1', 'ownerScope': 'forged'},
        ),
        (route: AppRoutes.parentalControls, arguments: null),
      ]) {
        final f = await _fixture();
        await _start(
          tester,
          f,
          initialRoute: entry.route,
          arguments: entry.arguments,
        );
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(f.observer.top?.name, entry.route);
        expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
        expect(find.textContaining('Owned child:'), findsNothing);
        expect(f.parentPasswordChecks, 0);
        await _finish(tester, f);
      }
    },
  );

  testWidgets(
    'ordinary pending operation is retained and not auto-routed or rekeyed',
    (tester) async {
      const pending = HostedPendingCheckout(
        parentId: 'parent-1',
        operationId: '11111111-1111-4111-8111-111111111111',
        period: SubscriptionBillingPeriod.monthly,
      );
      final f = await _fixture(
        startup: (_) async => throw http.ClientException('Offline fixture'),
        controller: (_, _) async => _access(complimentary: false),
        pending: pending,
      );
      await _start(tester, f);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(f.observer.top?.name, AppRoutes.subscription);
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      expect(f.checkout.pending?.operationId, pending.operationId);
      expect(
        f.pendingStore.writes.every(
          (p) => p.operationId == pending.operationId,
        ),
        isTrue,
      );
      expect(f.pendingStore.clears, 0);
      expect(f.checkout.successSequence, 0);
      expect(f.financialRequests, 0);
      await _finish(tester, f);
    },
  );
}

http.Response _access({
  String state = 'paid',
  bool complimentary = true,
  bool expired = false,
}) => http.Response(
  jsonEncode({
    'schema_version': 1,
    'parent_id': 'parent-1',
    'environment': 'production',
    'evaluated_at': DateTime.now().toUtc().toIso8601String(),
    'access_state': state,
    'access_until': state == 'paid'
        ? DateTime.now()
              .toUtc()
              .add(Duration(days: expired ? -1 : 1))
              .toIso8601String()
        : null,
    'access_basis': complimentary ? 'complimentary' : 'payment',
    'reason_code': complimentary ? 'complimentary_access' : 'active_proof',
    'payment_confirmed': !complimentary,
    'content_enforcement_enabled': true,
    'parent_plan_routing_enabled': true,
    'checkout': {'state': 'unavailable', 'reason_code': 'complimentary_access'},
  }),
  200,
);

class _Store implements HostedCheckoutPendingStore {
  _Store(this.pending);
  final HostedPendingCheckout? pending;
  final writes = <HostedPendingCheckout>[];
  int clears = 0;
  @override
  Future<HostedPendingCheckout?> read(String parentId) async => pending;
  @override
  Future<void> write(HostedPendingCheckout value) async => writes.add(value);
  @override
  Future<void> clear(String parentId) async {
    clears++;
  }
}

class _Observer extends NavigatorObserver {
  RouteSettings? top;
  final history = <RouteSettings>[];
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    top = topRoute.settings;
    history.add(topRoute.settings);
  }
}

class _Fixture {
  final sessions = MemoryAuthSessionStore();
  final navigator = GlobalKey<NavigatorState>();
  final observer = _Observer();
  late AuthRepository auth;
  late HostedSubscriptionController checkout;
  late StartupDestinationResolver resolver;
  late _Store pendingStore;
  final clients = <http.Client>[];
  int controllerReads = 0,
      startupReads = 0,
      parentPasswordChecks = 0,
      financialRequests = 0;
  bool disposed = false;
  Widget app(String initialRoute, Object? arguments) => MaterialApp(
    navigatorKey: navigator,
    initialRoute: initialRoute,
    onGenerateInitialRoutes: (name) => [
      _route(RouteSettings(name: name, arguments: arguments)),
    ],
    onGenerateRoute: _route,
    navigatorObservers: [observer],
    builder: (context, child) => HostedSubscriptionScope(
      navigatorKey: navigator,
      configuration: _configuration,
      controller: checkout,
      authRepository: auth,
      initialReturn: Future.value(null),
      returnLinks: const Stream.empty(),
      child: child!,
    ),
  );
  Route<dynamic> _route(RouteSettings settings) {
    if ([
      AppRoutes.home,
      AppRoutes.profilePicker,
      AppRoutes.kidProfileSetup,
    ].contains(settings.name)) {
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => HostedPaidRouteBoundary(
          child: settings.name == AppRoutes.home
              ? FutureBuilder<KidProfile?>(
                  future: auth.currentKid(),
                  builder: (_, value) => Scaffold(
                    body: Text('Owned child:${value.data?.id ?? "loading"}'),
                  ),
                )
              : Scaffold(body: Text('Owned destination:${settings.name}')),
        ),
      );
    }
    return AppRouter.onGenerateRoute(
      settings,
      splashDestinationResolver: resolver,
    );
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    checkout.dispose();
    for (final client in clients) {
      client.close();
    }
  }
}

Future<_Fixture> _fixture({
  Future<http.Response> Function(http.Request)? startup,
  Future<http.Response> Function(int, http.Request)? controller,
  bool rejectRefresh = false,
  String? selected = 'first-child',
  List<KidProfile> profiles = const [_first, _second],
  HostedPendingCheckout? pending,
}) async {
  // Each fixture represents a new cold process, with no in-memory prior denial.
  paidContentAccessState.selectScope(null);
  final f = _Fixture();
  await f.sessions.writeSession(_session.copyWith(profiles: profiles));
  if (selected != null) await f.sessions.writeSelectedKidId(selected);
  final authClient = MockClient((request) async {
    if (request.url.path.endsWith('/token/refresh/')) {
      expect(rejectRefresh, isTrue);
      return http.Response('{"detail":"Rejected"}', 401);
    }
    f.parentPasswordChecks++;
    throw StateError('Recovery must not authenticate a parent password.');
  });
  f.auth = AuthRepository(
    api: HttpAuthApi(baseUrl: _configuration.apiBaseUrl, client: authClient),
    sessionStore: f.sessions,
  );
  // Remove a prior test's in-memory denial for this otherwise identical scope.
  // The new controller still has no access model until its real HTTP fixture
  // responds; clearing this test state cannot itself enable child navigation.
  final owner = await f.auth.captureParentAccessOwner();
  if (owner != null) paidContentAccessState.allow(owner.scope);
  final controllerClient = MockClient((request) async {
    if (request.method != 'GET' ||
        request.url.path != '/api/billing/content-access/') {
      f.financialRequests++;
      throw StateError('Recovery may only read canonical access.');
    }
    final index = f.controllerReads++;
    return controller == null ? _access() : controller(index, request);
  });
  final startupClient = MockClient((request) async {
    expect(request.method, 'GET');
    expect(request.url.path, '/api/billing/content-access/');
    f.startupReads++;
    return startup == null ? _access() : startup(request);
  });
  f.clients.addAll([authClient, controllerClient, startupClient]);
  f.pendingStore = _Store(pending);
  f.checkout = HostedSubscriptionController(
    configuration: _configuration,
    repository: HttpHostedSubscriptionRepository(
      configuration: _configuration,
      authRepository: f.auth,
      client: controllerClient,
    ),
    pendingStore: f.pendingStore,
    authRepository: f.auth,
    launcher: (_) async => throw StateError('Recovery cannot open a provider.'),
  );
  f.resolver = StartupDestinationResolver(
    authRepository: f.auth,
    firstLaunchStore: MemoryFirstLaunchStore(launched: true),
    accessRouting: HostedAccessRouting(
      configuration: _configuration,
      authRepository: f.auth,
      repository: HttpHostedSubscriptionRepository(
        configuration: _configuration,
        authRepository: f.auth,
        client: startupClient,
      ),
    ),
  );
  addTearDown(f.dispose);
  return f;
}

Future<void> _start(
  WidgetTester tester,
  _Fixture f, {
  String initialRoute = AppRoutes.splash,
  Object? arguments,
}) async {
  await tester.pumpWidget(f.app(initialRoute, arguments));
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

Future<void> _finish(WidgetTester tester, _Fixture f) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  f.dispose();
}
