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
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/subscription/data/hosted_checkout_pending_store.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_controller.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_repository.dart';
import 'package:mobile/features/subscription/data/sandbox_checkout.dart';
import 'package:mobile/features/subscription/domain/subscription_plan.dart';
import 'package:mobile/features/subscription/presentation/hosted_subscription_scope.dart';

const _operation = '11111111-1111-4111-8111-111111111111';
const _attemptA = '22222222-2222-4222-8222-222222222222';
const _returnA = '33333333-3333-4333-8333-333333333333';
const _operationB = '44444444-4444-4444-8444-444444444444';
const _attemptB = '55555555-5555-4555-8555-555555555555';
const _returnB = '66666666-6666-4666-8666-666666666666';
const _configuration = SandboxCheckoutConfiguration(
  productionEnabled: true,
  hostedSubscriptionsEnabled: true,
  paymentEnvironment: 'production',
  apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionApiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionCheckoutUrl: SandboxCheckoutConfiguration.checkoutUrl,
);
AuthSession _session(String parent) => AuthSession(
  parent: ParentAccount(id: parent, email: '$parent@example.test'),
  accessToken: 'fixture-$parent',
  refreshToken: 'fixture-refresh-$parent',
);

class _Api extends Fake implements AuthApi {}

/// Controls the exact gap after an HTTP response and before its publication.
/// No account API, secure-storage plugin or actual network is invoked.
class _Auth extends AuthRepository {
  _Auth() : super(api: _Api(), sessionStore: MemoryAuthSessionStore());
  final Object backend = Object();
  AuthSession current = _session('A');
  bool afterResponse = false, switchAtSecondPostflightRead = false;
  int postflightReads = 0;
  Completer<void>? nextReadEntered, releaseRead;
  Object scopeFor(String parent) => (backend, parent, 0);
  void switchParent(String parent) {
    current = _session(parent);
    paidContentAccessState.selectScope(scopeFor(parent));
  }

  Future<({String parentId, Object scope})> _owner() async {
    if (nextReadEntered != null) {
      final entered = nextReadEntered!, release = releaseRead!;
      nextReadEntered = null;
      entered.complete();
      await release.future;
    }
    if (afterResponse &&
        ++postflightReads == 2 &&
        switchAtSecondPostflightRead) {
      switchParent('B');
    }
    final owner = (
      parentId: current.parent.id,
      scope: scopeFor(current.parent.id),
    );
    paidContentAccessState.selectScope(owner.scope);
    return owner;
  }

  @override
  Future<AuthSession?> restoreSession() async => current;
  @override
  Future<Object?> parentAccessScope() async => (await _owner()).scope;
  @override
  Future<({String parentId, Object scope})?> captureParentAccessOwner() =>
      _owner();
  @override
  Future<T> withAccessToken<T>(Future<T> Function(String token) operation) =>
      operation(current.accessToken);
}

Map<String, dynamic> _access(String parent, {required bool paid}) => {
  'schema_version': 1,
  'parent_id': parent,
  'environment': 'production',
  'evaluated_at': DateTime.now().toUtc().toIso8601String(),
  'access_state': paid ? 'paid' : 'unpaid',
  'access_until': paid
      ? DateTime.now().toUtc().add(const Duration(days: 29)).toIso8601String()
      : null,
  'content_enforcement_enabled': true,
  'parent_plan_routing_enabled': true,
  'checkout': {
    'state': paid ? 'unavailable' : 'available',
    'provider': 'square_hosted',
    'reason_code': 'production_hosted',
  },
  'hosted_checkout_recovery': null,
};

Map<String, dynamic> _quote() => {
  'schema_version': 1,
  'parent_id': 'A',
  'environment': 'production',
  'billing_period': 'monthly',
  'amount_minor': 999,
  'currency': 'USD',
  'policy_id': 'square-hosted-monthly-v1',
  'automatic_renewal': true,
  'billing_controller': 'square_hosted_subscriptions',
  'cadence': 'THIRTY_DAYS',
  'disclosure_version': 'hosted-monthly-v1',
  'disclosure_sha256': List.filled(64, 'a').join(),
  'disclosure': 'Square charges now and renews automatically until canceled.',
};

class _Store implements HostedCheckoutPendingStore {
  final values = <String, HostedPendingCheckout>{};
  Completer<void>? writeEntered, releaseWrite;
  Completer<void>? clearEntered, releaseClear;
  @override
  Future<HostedPendingCheckout?> read(String parent) async => values[parent];
  @override
  Future<void> write(HostedPendingCheckout pending) async {
    values[pending.parentId] = pending;
    if (writeEntered != null) {
      final entered = writeEntered!, release = releaseWrite!;
      writeEntered = null;
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<void> clear(String parent) async {
    values.remove(parent);
    if (parent == 'A' && clearEntered != null) {
      final entered = clearEntered!, release = releaseClear!;
      clearEntered = null;
      entered.complete();
      await release.future;
    }
  }
}

class _UnusedRepository extends Fake implements HostedSubscriptionRepository {}

class _SuccessController extends HostedSubscriptionController {
  _SuccessController(_Auth auth)
    : originalOwner = auth.scopeFor('A'),
      super(
        configuration: _configuration,
        repository: _UnusedRepository(),
        pendingStore: _Store(),
        authRepository: auth,
        launcher: (_) async => false,
      );
  final Object originalOwner;
  int sequence = 0;
  @override
  Object? get ownerScope => originalOwner;
  @override
  int get successSequence => sequence;
  @override
  HostedFlowState get state => HostedFlowState.paid;
  @override
  Future<bool> refresh() async => true;
  void completeForA() {
    sequence++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => paidContentAccessState.selectScope(null));

  for (final paid in [true, false]) {
    test(
      'parent A ${paid ? 'paid' : 'unpaid'} response cannot change parent B access at postflight scope switch',
      () async {
        final auth = _Auth();
        auth.switchParent('B');
        if (paid) paidContentAccessState.deny(auth.scopeFor('B'));
        auth.switchParent('A');
        auth.switchAtSecondPostflightRead = true;
        var requests = 0;
        final repository = HttpHostedSubscriptionRepository(
          configuration: _configuration,
          authRepository: auth,
          client: MockClient((_) async {
            requests++;
            auth.afterResponse = true;
            return http.Response(jsonEncode(_access('A', paid: paid)), 200);
          }),
        );
        addTearDown(repository.dispose);
        try {
          await repository.access();
        } catch (_) {
          // Rejecting the stale response is expected. With no publication await
          // at all, it may instead finish safely before the switch occurs.
        }
        auth.switchParent('B');
        expect(requests, 1);
        expect(auth.postflightReads, greaterThanOrEqualTo(1));
        expect(paidContentAccessState.isDenied, paid);
      },
    );
  }

  test(
    'a parent switch during pending storage cannot send A password under B JWT',
    () async {
      final auth = _Auth(), posted = <http.Request>[];
      final repository = HttpHostedSubscriptionRepository(
        configuration: _configuration,
        authRepository: auth,
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posted.add(request);
            return http.Response('{}', 400);
          }
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/quote/')
                  ? _quote()
                  : _access(auth.current.parent.id, paid: false),
            ),
            200,
          );
        }),
      );
      addTearDown(repository.dispose);
      final store = _Store(),
          entered = Completer<void>(),
          release = Completer<void>();
      final controller = HostedSubscriptionController(
        configuration: _configuration,
        repository: repository,
        pendingStore: store,
        authRepository: auth,
        operationId: () => _operation,
        storefrontCountryProvider: () async => 'USA',
        launcher: (_) async =>
            throw StateError('A stale parent must not launch checkout'),
      );
      addTearDown(controller.dispose);
      controller.authorizeParent = (quote, authorize) async {
        await authorize('fixture-A-password');
        return true;
      };
      await controller.refresh();
      expect(controller.canOpen, isTrue);
      store.writeEntered = entered;
      store.releaseWrite = release;
      final opening = controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      await entered.future.timeout(const Duration(seconds: 2));
      auth.switchParent('B');
      release.complete();
      await opening;
      expect(posted, isEmpty);
      expect(controller.successSequence, 0);
      expect(store.values['B'], isNull);
    },
  );

  test(
    'A completion held at storage cleanup cannot clear B pending or signal B success',
    () async {
      final auth = _Auth(), store = _Store();
      const savedA = HostedPendingCheckout(
        parentId: 'A',
        operationId: _operation,
        period: SubscriptionBillingPeriod.monthly,
        attemptId: _attemptA,
        returnState: _returnA,
      );
      const savedB = HostedPendingCheckout(
        parentId: 'B',
        operationId: _operationB,
        period: SubscriptionBillingPeriod.monthly,
        attemptId: _attemptB,
        returnState: _returnB,
      );
      store.values.addAll({'A': savedA, 'B': savedB});
      var aPaid = false;
      final repository = HttpHostedSubscriptionRepository(
        configuration: _configuration,
        authRepository: auth,
        client: MockClient((request) async {
          final parent = auth.current.parent.id;
          if (request.url.path.endsWith('/reconcile/')) {
            final a = parent == 'A';
            if (a) aPaid = true;
            return http.Response(
              jsonEncode({
                'schema_version': 1,
                'parent_id': parent,
                'environment': 'production',
                'attempt_id': a ? _attemptA : _attemptB,
                'operation_id': a ? _operation : _operationB,
                'billing_period': 'monthly',
                'amount_minor': 999,
                'currency': 'USD',
                'return_state': a ? _returnA : _returnB,
                'state': a ? 'paid' : 'pending',
                'checkout_url': null,
                'payment_confirmed': a,
                'access_state': a ? 'paid' : 'unknown',
                'access_until': a
                    ? DateTime.now()
                          .toUtc()
                          .add(const Duration(days: 29))
                          .toIso8601String()
                    : null,
                'renewals_enabled': a,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(_access(parent, paid: parent == 'A' && aPaid)),
            200,
          );
        }),
      );
      addTearDown(repository.dispose);
      final controller = HostedSubscriptionController(
        configuration: _configuration,
        repository: repository,
        pendingStore: store,
        authRepository: auth,
        launcher: (_) async => false,
      );
      addTearDown(controller.dispose);
      final entered = Completer<void>(), release = Completer<void>();
      store.clearEntered = entered;
      store.releaseClear = release;
      final oldCompletion = controller.refresh();
      await entered.future.timeout(const Duration(seconds: 2));
      auth.switchParent('B');
      await controller.refresh();
      expect(controller.pending?.parentId, 'B');
      expect(controller.pending?.operationId, _operationB);
      release.complete();
      await oldCompletion;
      expect(controller.pending?.parentId, 'B');
      expect(controller.pending?.operationId, _operationB);
      expect(controller.successSequence, 0);
      expect(controller.state, HostedFlowState.pending);
      expect(store.values['B']?.operationId, _operationB);
    },
  );

  testWidgets(
    'a queued A success cannot show active subscription or navigate for B',
    (tester) async {
      final auth = _Auth();
      final ownedController = _SuccessController(auth);
      addTearDown(ownedController.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Original plans route')),
          routes: {
            AppRoutes.kidProfileSetup: (_) =>
                const Scaffold(body: Text('Unexpected B route')),
            AppRoutes.login: (_) =>
                const Scaffold(body: Text('Unexpected login route')),
          },
          builder: (context, child) => HostedSubscriptionScope(
            navigatorKey: navigator,
            configuration: _configuration,
            controller: ownedController,
            authRepository: auth,
            initialReturn: Future.value(null),
            returnLinks: const Stream.empty(),
            child: child!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final entered = Completer<void>(), release = Completer<void>();
      auth.nextReadEntered = entered;
      auth.releaseRead = release;
      ownedController.completeForA();
      await tester.pump();
      expect(entered.isCompleted, isTrue);
      auth.switchParent('B');
      release.complete();
      await tester.pumpAndSettle();
      expect(find.text('Subscription active'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Original plans route'), findsOneWidget);
      expect(find.text('Unexpected B route'), findsNothing);
      expect(find.text('Unexpected login route'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
