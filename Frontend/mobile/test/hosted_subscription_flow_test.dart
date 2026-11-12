import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/subscription/data/hosted_access_routing.dart';
import 'package:mobile/features/subscription/data/hosted_checkout_pending_store.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_controller.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_repository.dart';
import 'package:mobile/features/subscription/data/sandbox_checkout.dart';
import 'package:mobile/features/subscription/domain/hosted_checkout_return.dart';
import 'package:mobile/features/subscription/domain/hosted_subscription.dart';
import 'package:mobile/features/subscription/domain/subscription_plan.dart';
import 'package:mobile/features/subscription/presentation/checkout_error_notice.dart';
import 'package:mobile/features/subscription/presentation/hosted_paid_route_boundary.dart';
import 'package:mobile/features/subscription/presentation/hosted_parent_authorization.dart';
import 'package:mobile/features/subscription/presentation/hosted_subscription_scope.dart';
import 'package:mobile/features/subscription/presentation/subscription_screen.dart';

const _op = '11111111-1111-4111-8111-111111111111';
const _attempt = '22222222-2222-4222-8222-222222222222';
const _return = '33333333-3333-4333-8333-333333333333';
const _other = '44444444-4444-4444-8444-444444444444';
const _configuration = SandboxCheckoutConfiguration(
  productionEnabled: true,
  hostedSubscriptionsEnabled: true,
  paymentEnvironment: 'production',
  apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionApiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionCheckoutUrl: SandboxCheckoutConfiguration.checkoutUrl,
);
const _kid = KidProfile(
  id: 'kid',
  parentId: '42',
  displayName: 'Ada',
  avatarKey: 'dove',
);
const _session = AuthSession(
  parent: ParentAccount(id: '42', email: 'parent@example.test'),
  accessToken: 'fixture-access',
  refreshToken: 'fixture-refresh',
  profiles: [_kid],
);

Map<String, dynamic> _identity(SubscriptionBillingPeriod period) => {
  'schema_version': 1,
  'parent_id': '42',
  'environment': 'production',
  'attempt_id': _attempt,
  'operation_id': _op,
  'billing_period': period.name,
  'amount_minor': period.amountMinor,
  'currency': 'USD',
};
Map<String, dynamic> _quote(SubscriptionBillingPeriod period) => {
  ..._identity(period),
  'policy_id': 'square-hosted-${period.name}-v1',
  'automatic_renewal': true,
  'billing_controller': 'square_hosted_subscriptions',
  'cadence': period == SubscriptionBillingPeriod.monthly
      ? 'THIRTY_DAYS'
      : 'ANNUAL',
  'disclosure_version': 'hosted-v1',
  'disclosure_sha256': List.filled(64, 'a').join(),
  'disclosure':
      'Square charges now and automatically renews until canceled. Each paid term gives full access.',
};
Map<String, dynamic> _authorization(SubscriptionBillingPeriod period) => {
  ..._identity(period),
  'authorization_token': 'kkhost.${List.filled(43, 'a').join()}',
  'authorization_expires_at': DateTime.now()
      .toUtc()
      .add(const Duration(minutes: 9))
      .toIso8601String(),
};
Map<String, dynamic> _attemptJson(
  SubscriptionBillingPeriod period, {
  String state = 'pending',
  bool paid = false,
}) => {
  ..._identity(period),
  'state': state,
  'return_state': _return,
  'checkout_url': state == 'ready' ? 'https://square.link/u/Owned123' : null,
  'payment_confirmed': paid,
  'access_state': paid ? 'paid' : 'unknown',
  'access_until': paid
      ? DateTime.now().toUtc().add(const Duration(days: 29)).toIso8601String()
      : null,
  'renewals_enabled': paid,
};
SandboxContentAccess _access({bool paid = false, bool complimentary = false}) =>
    SandboxContentAccess(
      parentId: '42',
      state: paid ? SandboxAccessState.paid : SandboxAccessState.unpaid,
      checkoutAvailable: !paid,
      enforcementEnabled: true,
      routingEnabled: true,
      managementAvailable: paid && !complimentary,
      complimentaryAccess: complimentary,
      accessUntil: paid
          ? DateTime.now().toUtc().add(const Duration(days: 29))
          : null,
    );

class _AuthApi extends Fake implements AuthApi {}

Future<({AuthRepository auth, MemoryAuthSessionStore session})> _auth() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(_session);
  await store.writeSelectedKidId(_kid.id);
  return (
    auth: AuthRepository(api: _AuthApi(), sessionStore: store),
    session: store,
  );
}

class _Store implements HostedCheckoutPendingStore {
  final values = <String, HostedPendingCheckout>{};
  @override
  Future<HostedPendingCheckout?> read(String parentId) async =>
      values[parentId];
  @override
  Future<void> write(HostedPendingCheckout pending) async {
    values[pending.parentId] = pending;
  }

  @override
  Future<void> clear(String parentId) async {
    values.remove(parentId);
  }
}

class _Repository implements HostedSubscriptionRepository {
  int authorizations = 0, preparations = 0, reconciliations = 0, reads = 0;
  bool paid = false,
      complimentary = false,
      prepareTimeout = false,
      accessFails = false;
  SubscriptionBillingPeriod selected = SubscriptionBillingPeriod.monthly;
  final operations = <String>[];
  Completer<HostedAttempt>? heldPrepare;
  @override
  Future<({SandboxContentAccess access, Map<String, dynamic>? recovery})>
  access() async {
    reads++;
    if (accessFails) throw const AppException('Offline', code: 'network_error');
    return (
      access: _access(paid: paid, complimentary: complimentary),
      recovery: null,
    );
  }

  @override
  Future<HostedQuote> quote(SubscriptionBillingPeriod period) async =>
      HostedQuote.fromJson(_quote(period), '42', period);
  @override
  Future<HostedAuthorization> authorize(
    HostedQuote quote,
    String operationId,
  ) async {
    authorizations++;
    operations.add(operationId);
    selected = quote.period;
    return HostedAuthorization.fromJson(
      _authorization(selected),
      '42',
      operationId,
      selected,
    );
  }

  @override
  Future<HostedAttempt> prepare(HostedAuthorization authorization) async {
    preparations++;
    if (heldPrepare != null) return heldPrepare!.future;
    if (prepareTimeout) throw TimeoutException('fixture timeout');
    return HostedAttempt.fromJson(
      _attemptJson(selected, state: 'ready'),
      '42',
      operationId: _op,
      period: selected,
    );
  }

  @override
  Future<HostedAttempt> reconcile(
    String attemptId,
    String operationId,
    SubscriptionBillingPeriod period, {
    String? expectedParentId,
    Object? expectedScope,
  }) async {
    reconciliations++;
    expect(attemptId, _attempt);
    expect(operationId, _op);
    return HostedAttempt.fromJson(
      _attemptJson(period, state: paid ? 'paid' : 'pending', paid: paid),
      '42',
      operationId: _op,
      period: period,
    );
  }

  @override
  Future<HostedAttempt> cancel(
    String attemptId,
    String operationId,
    SubscriptionBillingPeriod period,
    String password, {
    String? expectedParentId,
    Object? expectedScope,
  }) async => HostedAttempt.fromJson(
    _attemptJson(period, state: 'canceled', paid: true),
    '42',
    operationId: operationId,
    period: period,
  );
}

HostedSubscriptionController _controller(
  _Repository repo,
  _Store store,
  AuthRepository auth, {
  List<Uri>? launches,
  String country = 'USA',
}) {
  final controller = HostedSubscriptionController(
    configuration: _configuration,
    repository: repo,
    pendingStore: store,
    authRepository: auth,
    operationId: () => _op,
    pollDelays: const [Duration.zero, Duration.zero],
    storefrontCountryProvider: () async => country,
    launcher: (uri) async {
      launches?.add(uri);
      return true;
    },
  );
  controller.authorizeParent = (quote, authorize) async {
    await authorize();
    return true;
  };
  return controller;
}

Future<void> _drain() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'canonical complimentary access is finite owned access, never a purchase capability',
    () {
      final now = DateTime.now().toUtc();
      final json = <String, dynamic>{
        'schema_version': 1,
        'parent_id': '42',
        'environment': 'production',
        'evaluated_at': now.toIso8601String(),
        'access_state': 'paid',
        'access_until': now.add(const Duration(days: 30)).toIso8601String(),
        'access_basis': 'complimentary',
        'reason_code': 'complimentary_access',
        'payment_confirmed': false,
        'content_enforcement_enabled': true,
        'parent_plan_routing_enabled': true,
        'checkout': {
          'state': 'available',
          'provider': 'square_hosted',
          'reason_code': 'production_hosted',
          'management_state': 'available',
          'management_reason_code': 'owned_purchase',
        },
      };
      final access = SandboxContentAccess.fromJson(
        json,
        expectedParentId: '42',
        expectedEnvironment: 'production',
        allowHostedProduction: true,
      );
      expect(access.complimentaryAccess, isTrue);
      expect(access.checkoutAvailable, isFalse);
      expect(access.managementAvailable, isFalse);
      expect(
        () => SandboxContentAccess.fromJson(
          {...json, 'access_until': null},
          expectedParentId: '42',
          expectedEnvironment: 'production',
          allowHostedProduction: true,
        ),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'complimentary grant bypasses payment reconcile without fake success or deleting a frozen attempt',
    (tester) async {
      final fixture = await _auth();
      final repo = _Repository()
        ..paid = true
        ..complimentary = true;
      final store = _Store();
      await store.write(
        const HostedPendingCheckout(
          parentId: '42',
          operationId: _op,
          period: SubscriptionBillingPeriod.monthly,
          attemptId: _attempt,
          returnState: _return,
        ),
      );
      final controller = _controller(repo, store, fixture.auth);
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.verifyPending();
      expect(controller.canBrowse, isTrue);
      expect(controller.canOpen, isFalse);
      expect(controller.canManage, isFalse);
      expect(repo.reconciliations, 0);
      expect(controller.successSequence, 0);
      expect((await store.read('42'))!.operationId, _op);
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionScreen(sandboxCheckout: controller)),
      );
      expect(
        find.byKey(const Key('complimentary-access-screen')),
        findsOneWidget,
      );
      expect(find.text('Complimentary access active'), findsOneWidget);
      expect(find.text('Subscription active'), findsNothing);
      expect(find.text('Manage subscription'), findsNothing);
      expect(find.text('Monthly plan'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'hosted configuration and capability stay separate from old SDK/controlled profiles',
    () {
      expect(_configuration.isHostedProductionEnabled, isTrue);
      expect(
        const SandboxCheckoutConfiguration(
          hostedSubscriptionsEnabled: true,
        ).isEnabled,
        isFalse,
      );
      expect(
        const SandboxCheckoutConfiguration(
          productionEnabled: true,
          controlledLiveEnabled: true,
          hostedSubscriptionsEnabled: true,
          paymentEnvironment: 'production',
          apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
          productionApiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
          productionCheckoutUrl: SandboxCheckoutConfiguration.checkoutUrl,
        ).isEnabled,
        isFalse,
      );
      final payload = {
        'schema_version': 1,
        'parent_id': '42',
        'environment': 'production',
        'evaluated_at': DateTime.now().toUtc().toIso8601String(),
        'access_state': 'unpaid',
        'access_until': null,
        'content_enforcement_enabled': true,
        'parent_plan_routing_enabled': true,
        'checkout': {
          'state': 'available',
          'provider': 'square_hosted',
          'reason_code': 'production_hosted',
          'handoff_available': false,
        },
      };
      expect(
        SandboxContentAccess.fromJson(
          payload,
          expectedParentId: '42',
          expectedEnvironment: 'production',
          allowHostedProduction: true,
        ).checkoutAvailable,
        isTrue,
      );
      expect(
        SandboxContentAccess.fromJson(
          payload,
          expectedParentId: '42',
          expectedEnvironment: 'production',
        ).checkoutAvailable,
        isFalse,
      );
    },
  );

  test(
    'strict non-auth return routes reject credentials, fragments, duplicates and unrelated links',
    () {
      for (final base in [
        'https://kingdom-kids.app/payments/return/',
        'kingdomkids://payments/return/',
      ]) {
        expect(
          HostedCheckoutReturn.parse(
            '$base?attempt=$_attempt&state=$_return',
          )?.attemptId,
          _attempt,
        );
        for (final suffix in [
          '?attempt=$_attempt&state=$_return&state=$_return',
          '?attempt=$_attempt&state=$_return&access_token=secret',
          '?attempt=$_attempt&state=$_return#paid',
          '?attempt=not-a-uuid&state=$_return',
        ]) {
          expect(HostedCheckoutReturn.parse('$base$suffix'), isNull);
        }
      }
      for (final url in [
        'http://kingdom-kids.app/payments/return/?attempt=$_attempt&state=$_return',
        'https://evil.example/payments/return/?attempt=$_attempt&state=$_return',
        'https://user:password@kingdom-kids.app/payments/return/?attempt=$_attempt&state=$_return',
        'https://kingdom-kids.app/parent/checkout/?attempt=$_attempt&state=$_return',
      ]) {
        expect(HostedCheckoutReturn.parse(url), isNull);
      }
    },
  );

  test('only exact Square HTTPS paths can launch, without app credentials', () {
    expect(
      hostedProviderUri('https://square.link/u/Owned123')?.host,
      'square.link',
    );
    expect(
      hostedProviderUri(
        'https://checkout.square.site/merchant/M123/order/O123',
      )?.host,
      'checkout.square.site',
    );
    for (final url in [
      'http://square.link/u/Owned123',
      'https://square.link.evil.test/u/Owned123',
      'https://square.link/u/Owned123?token=secret',
      'https://square.link/u/Owned123#secret',
      'https://user:secret@square.link/u/Owned123',
      'https://squareup.com/checkout/anything',
      'https://square.link/other',
    ]) {
      expect(() => hostedProviderUri(url), throwsFormatException);
    }
  });

  test(
    'verified parent consent precedes provider Pay; canonical paid return completes once',
    () async {
      final fixture = await _auth();
      final repo = _Repository(), store = _Store(), launches = <Uri>[];
      final controller = _controller(
        repo,
        store,
        fixture.auth,
        launches: launches,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.yearly,
      );
      expect(repo.authorizations, 1);
      expect(repo.preparations, 1);
      expect(repo.selected, SubscriptionBillingPeriod.yearly);
      expect(launches.single, Uri.parse('https://square.link/u/Owned123'));
      expect(
        store.values['42']!.toJson().keys,
        unorderedEquals([
          'parent_id',
          'operation_id',
          'billing_period',
          'attempt_id',
          'return_state',
        ]),
      );
      expect(controller.state, HostedFlowState.awaitingProvider);
      repo.paid = true;
      expect(
        await controller.handleReturn(
          const HostedCheckoutReturn(_attempt, _return),
        ),
        isTrue,
      );
      await _drain();
      expect(controller.state, HostedFlowState.paid);
      expect(controller.successSequence, 1);
      expect(repo.authorizations, 1);
      expect(repo.preparations, 1);
      expect(store.values, isEmpty);
      expect(
        await controller.handleReturn(
          const HostedCheckoutReturn(_attempt, _return),
        ),
        isFalse,
      );
      expect(controller.successSequence, 1);
    },
  );

  test(
    'prepare timeout and cold recovery never mint another operation or call prepare again',
    () async {
      final fixture = await _auth();
      final repo = _Repository()..prepareTimeout = true;
      final store = _Store();
      final first = _controller(repo, store, fixture.auth);
      await first.refresh();
      await first.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      expect(first.state, HostedFlowState.pending);
      expect(first.error, isNull);
      expect(store.values['42']!.operationId, _op);
      first.dispose();
      final resumed = _controller(repo, store, fixture.auth);
      addTearDown(resumed.dispose);
      await resumed.verifyPending();
      expect(resumed.state, HostedFlowState.pending);
      expect(resumed.canOpen, isFalse);
      expect(repo.authorizations, 1);
      expect(repo.preparations, 1);
      expect(repo.operations, [_op]);
      expect(repo.reconciliations, greaterThan(0));
    },
  );

  test(
    'spoofed return cannot reconcile or replace a different active attempt',
    () async {
      final fixture = await _auth();
      final repo = _Repository(), store = _Store();
      final controller = _controller(repo, store, fixture.auth);
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      final count = repo.reconciliations;
      expect(
        await controller.handleReturn(
          const HostedCheckoutReturn(_other, _return),
        ),
        isFalse,
      );
      expect(
        await controller.handleReturn(
          const HostedCheckoutReturn(_attempt, _other),
        ),
        isFalse,
      );
      expect(repo.reconciliations, count);
      expect(store.values['42']!.attemptId, _attempt);
      expect(controller.successSequence, 0);
    },
  );

  test('USA guard and parent switch stop provider launch', () async {
    final fixture = await _auth();
    final repo = _Repository(), store = _Store(), launches = <Uri>[];
    final outside = _controller(
      repo,
      store,
      fixture.auth,
      country: 'CAN',
      launches: launches,
    );
    await outside.refresh();
    await outside.openCheckout(
      billingPeriod: SubscriptionBillingPeriod.monthly,
    );
    expect(repo.authorizations, 0);
    expect(launches, isEmpty);
    outside.dispose();
    repo.heldPrepare = Completer<HostedAttempt>();
    final controller = _controller(
      repo,
      store,
      fixture.auth,
      launches: launches,
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    final opening = controller.openCheckout(
      billingPeriod: SubscriptionBillingPeriod.monthly,
    );
    await _drain();
    await fixture.session.writeSession(
      const AuthSession(
        parent: ParentAccount(id: 'other', email: 'other@example.test'),
        accessToken: 'new',
        refreshToken: 'new',
        profiles: [],
      ),
    );
    repo.heldPrepare!.complete(
      HostedAttempt.fromJson(
        _attemptJson(SubscriptionBillingPeriod.monthly, state: 'ready'),
        '42',
        operationId: _op,
        period: SubscriptionBillingPeriod.monthly,
      ),
    );
    await opening;
    expect(launches, isEmpty);
    expect(controller.successSequence, 0);
  });

  test(
    'startup routes unpaid and unknown to plans while paid parents skip',
    () async {
      final fixture = await _auth();
      final repo = _Repository();
      final routing = HostedAccessRouting(
        configuration: _configuration,
        authRepository: fixture.auth,
        repository: repo,
      );
      expect(await routing.requiresPlans(), isTrue);
      repo.paid = true;
      expect(await routing.requiresPlans(), isFalse);
      repo.accessFails = true;
      expect(await routing.requiresPlans(), isTrue);
      expect(
        await HostedAccessRouting(repository: repo).requiresPlans(),
        isFalse,
      );
      expect(repo.authorizations, 0);
    },
  );

  test(
    'pending metadata is securely isolated by parent and API origin',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = SecureHostedCheckoutPendingStore(_configuration.apiBaseUrl),
          other = SecureHostedCheckoutPendingStore(
            'https://other.example.test/api',
          );
      await store.write(
        const HostedPendingCheckout(
          parentId: '42',
          operationId: _op,
          period: SubscriptionBillingPeriod.monthly,
          attemptId: _attempt,
          returnState: _return,
        ),
      );
      await store.write(
        const HostedPendingCheckout(
          parentId: 'other',
          operationId: _other,
          period: SubscriptionBillingPeriod.yearly,
        ),
      );
      await store.clear('42');
      expect(await store.read('42'), isNull);
      expect((await store.read('other'))!.operationId, _other);
      expect(await other.read('other'), isNull);
    },
  );

  testWidgets(
    'native error toast lasts five seconds, shrinks right to left and fades without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var visible = true;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2.2)),
              child: Stack(
                children: [
                  const Scaffold(),
                  if (visible)
                    Positioned.fill(
                      child: CheckoutErrorNotice(
                        message: 'We could not connect. Please try again.',
                        onDismiss: () => setState(() => visible = false),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final first = tester.getRect(
        find.byKey(const Key('checkout-error-countdown')),
      );
      await tester.pump(const Duration(milliseconds: 2500));
      final half = tester.getRect(
        find.byKey(const Key('checkout-error-countdown')),
      );
      expect(half.left, first.left);
      expect(half.width, lessThan(first.width));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pump();
      expect(find.byKey(const Key('checkout-error-notice')), findsNothing);
    },
  );

  testWidgets(
    'parent consent requires terms acceptance, no password, and a pill CTA before its one server check',
    (tester) async {
      var calls = 0;
      final submitted = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHostedParentAuthorization(
                context,
                title: 'For parents',
                disclosure:
                    'Square charges now and automatically renews until canceled.',
                authorize: () async {
                  calls++;
                  if (calls == 1) {
                    throw const AppException('Please try continuing again.');
                  }
                  await submitted.future;
                },
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('hosted-authorize-continue')),
            )
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('hosted-parent-password')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('hosted-authorize-continue')),
            )
            .style!
            .shape!
            .resolve({}),
        isA<StadiumBorder>(),
      );
      await tester.tap(find.byKey(const Key('hosted-subscription-consent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('hosted-authorize-continue')));
      await tester.pump();
      expect(calls, 1);
      expect(find.byKey(const Key('checkout-error-notice')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Please try continuing again.'),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(const Key('checkout-error-notice')), findsNothing);
      await tester.tap(find.byKey(const Key('hosted-authorize-continue')));
      await tester.pump();
      expect(calls, 2);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('hosted-authorize-continue')),
            )
            .onPressed,
        isNull,
      );
      submitted.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('hosted-parent-authorization')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'owned verified success returns to current child library without reopening a parent gate',
    (tester) async {
      final fixture = await _auth();
      final repo = _Repository()..paid = true;
      final store = _Store();
      await store.write(
        const HostedPendingCheckout(
          parentId: '42',
          operationId: _op,
          period: SubscriptionBillingPeriod.monthly,
          attemptId: _attempt,
          returnState: _return,
        ),
      );
      final controller = _controller(repo, store, fixture.auth);
      addTearDown(controller.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          initialRoute: '/plans',
          routes: {
            '/plans': (_) => const Scaffold(body: Text('Plans entry')),
            AppRoutes.home: (_) =>
                const Scaffold(body: Text('Current child library')),
          },
          builder: (context, child) => HostedSubscriptionScope(
            navigatorKey: navigator,
            configuration: _configuration,
            controller: controller,
            authRepository: fixture.auth,
            returnLinks: const Stream.empty(),
            initialReturn: Future.value(
              'https://kingdom-kids.app/payments/return/?attempt=$_attempt&state=$_return',
            ),
            child: child!,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('Subscription active'), findsOneWidget);
      expect(find.byKey(const Key('adult-gate-screen')), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Current child library'), findsOneWidget);
      expect(repo.authorizations, 0);
    },
  );

  testWidgets(
    'unpaid route never builds child content and retains parent account controls',
    (tester) async {
      final fixture = await _auth();
      final repo = _Repository(), store = _Store();
      final controller = _controller(repo, store, fixture.auth);
      addTearDown(controller.dispose);
      await controller.refresh();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const HostedPaidRouteBoundary(
            child: Text('Private child story'),
          ),
          builder: (context, child) => HostedSubscriptionScope(
            navigatorKey: navigator,
            configuration: _configuration,
            controller: controller,
            authRepository: fixture.auth,
            returnLinks: const Stream.empty(),
            initialReturn: Future.value(null),
            child: child!,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Private child story'), findsNothing);
      expect(find.text('Parent account settings'), findsNothing);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.text('Delete account'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'HTTP quote/authorization/prepare use canonical bearer headers and exact body fields only',
    () async {
      final fixture = await _auth();
      final methods = <String>[];
      final repo = HttpHostedSubscriptionRepository(
        configuration: _configuration,
        authRepository: fixture.auth,
        client: MockClient((request) async {
          methods.add(request.method);
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer fixture-access');
          expect(
            request.url.origin,
            'https://kingdom-kids-checkout-staging.onrender.com',
          );
          if (request.url.path.endsWith('/quote/')) {
            return http.Response(
              jsonEncode(_quote(SubscriptionBillingPeriod.monthly)),
              200,
            );
          }
          final body = jsonDecode(request.body) as Map;
          if (request.url.path.endsWith('/authorize/')) {
            expect(
              body.keys,
              unorderedEquals([
                'operation_id',
                'billing_period',
                'accepted',
                'disclosure_version',
                'disclosure_sha256',
              ]),
            );
            expect(body['accepted'], isTrue);
            return http.Response(
              jsonEncode(_authorization(SubscriptionBillingPeriod.monthly)),
              200,
            );
          }
          expect(
            body.keys,
            unorderedEquals([
              'operation_id',
              'billing_period',
              'authorization_token',
            ]),
          );
          return http.Response(
            jsonEncode(
              _attemptJson(SubscriptionBillingPeriod.monthly, state: 'ready'),
            ),
            200,
          );
        }),
      );
      addTearDown(repo.dispose);
      final quote = await repo.quote(SubscriptionBillingPeriod.monthly);
      final grant = await repo.authorize(quote, _op);
      final prepared = await repo.prepare(grant);
      expect(prepared.checkoutUri!.host, 'square.link');
      expect(methods, ['GET', 'POST', 'POST']);
    },
  );
}
