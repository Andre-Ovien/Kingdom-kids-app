import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/core/network/feature_read_cache.dart';
import 'package:mobile/core/network/feature_view_state_cache.dart';
import 'package:mobile/core/network/paid_content_access_state.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/data/media_access_scope.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/subscription/data/parent_content_access_monitor.dart';
import 'package:mobile/features/subscription/data/app_store_storefront.dart';
import 'package:mobile/features/subscription/data/sandbox_checkout.dart';
import 'package:mobile/features/subscription/domain/subscription_plan.dart';
import 'package:mobile/features/subscription/presentation/subscription_screen.dart';
import 'package:mobile/shared/widgets/scoped_feature_page.dart';
import 'package:mobile/features/stories/data/story_api.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/data/story_narration_metadata_refresher.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/story_detail_screen.dart';

import '../tool/validate_app_store_release.dart';
import '../tool/validate_release_config.dart';

const _configuration = SandboxCheckoutConfiguration(
  productionEnabled: true,
  paymentEnvironment: 'production',
  apiBaseUrl: 'https://api.example.test/api',
  productionApiBaseUrl: 'https://api.example.test/api',
  productionCheckoutUrl: 'https://api.example.test/parent/checkout/',
);
const _session = AuthSession(
  parent: ParentAccount(id: '42', email: 'parent@example.test'),
  accessToken: 'fixture-access',
  refreshToken: 'fixture-refresh',
  profiles: [],
);
const _controlledConfiguration = SandboxCheckoutConfiguration(
  productionEnabled: true,
  controlledLiveEnabled: true,
  paymentEnvironment: 'production',
  apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionApiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionCheckoutUrl: SandboxCheckoutConfiguration.checkoutUrl,
);

Map<String, dynamic> _access({
  String state = 'unpaid',
  bool purchase = true,
}) => {
  'schema_version': 1,
  'parent_id': '42',
  'environment': 'production',
  'evaluated_at': DateTime.now().toUtc().toIso8601String(),
  'access_state': state,
  'access_until': state == 'paid'
      ? DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String()
      : null,
  'content_enforcement_enabled': true,
  'parent_plan_routing_enabled': true,
  'checkout': {
    'state': purchase ? 'available' : 'unavailable',
    'reason_code': purchase ? 'production_qualified' : 'not_qualified',
    'management_state': 'available',
    'management_reason_code': 'owned_purchase',
    'handoff_available': true,
    'management_handoff_available': true,
  },
};

Future<({AuthRepository auth, MemoryAuthSessionStore store})> _auth() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(_session);
  return (
    auth: AuthRepository(api: _AuthApi(), sessionStore: store),
    store: store,
  );
}

class _AuthApi extends Fake implements AuthApi {}

void main() {
  Map<String, dynamic> controlledPayload() {
    final payload = _access();
    payload['content_enforcement_enabled'] = false;
    payload['parent_plan_routing_enabled'] = false;
    payload['checkout'] = <String, dynamic>{
      ...payload['checkout'] as Map<String, dynamic>,
      'reason_code': 'production_controlled',
      'controlled_parent_eligible': true,
    };
    return payload;
  }

  test(
    'controlled live mode requires its extra opt-in and the exact existing HTTPS origin',
    () {
      expect(_controlledConfiguration.isControlledProductionEnabled, isTrue);
      expect(_controlledConfiguration.environment, 'production');
      expect(
        const SandboxCheckoutConfiguration(
          controlledLiveEnabled: true,
        ).isEnabled,
        isFalse,
      );
      expect(
        const SandboxCheckoutConfiguration(
          productionEnabled: true,
          controlledLiveEnabled: true,
          paymentEnvironment: 'production',
          apiBaseUrl: 'https://other.example.test/api',
          productionApiBaseUrl: 'https://other.example.test/api',
          productionCheckoutUrl: 'https://other.example.test/parent/checkout/',
        ).isEnabled,
        isFalse,
      );
      expect(_configuration.isControlledProductionEnabled, isFalse);
    },
  );

  test(
    'controlled server capability needs matching parent, production environment and explicit eligibility without global enforcement',
    () {
      SandboxContentAccess parse(
        Map<String, dynamic> payload, {
        bool controlled = true,
      }) => SandboxContentAccess.fromJson(
        payload,
        expectedParentId: '42',
        expectedEnvironment: 'production',
        allowControlledProduction: controlled,
      );
      final payload = controlledPayload();
      final allowed = parse(payload);
      expect(allowed.checkoutAvailable, isTrue);
      expect(allowed.enforcementEnabled, isFalse);
      expect(allowed.routingEnabled, isFalse);
      expect(parse(payload, controlled: false).checkoutAvailable, isFalse);
      expect(parse(_access()).checkoutAvailable, isFalse);
      for (final eligible in [null, false, 'true']) {
        final denied = controlledPayload();
        (denied['checkout'] as Map)['controlled_parent_eligible'] = eligible;
        expect(parse(denied).checkoutAvailable, isFalse);
      }
      expect(
        parse({
          ...payload,
          'content_enforcement_enabled': true,
        }).checkoutAvailable,
        isFalse,
      );
      expect(
        () => parse({...payload, 'parent_id': 'other'}),
        throwsFormatException,
      );
      expect(
        () => parse({...payload, 'environment': 'sandbox'}),
        throwsFormatException,
      );
      expect(
        () => validateAppStoreRelease(
          {
            'API_BASE_URL': _configuration.apiBaseUrl,
            'CONTENT_MEDIA_HOSTS': '',
            'PRODUCTION_PAYMENT_FLOW_ENABLED': true,
            'CONTROLLED_LIVE_PAYMENT_FLOW_ENABLED': true,
            'PAYMENT_ENVIRONMENT': 'production',
            'PAYMENT_API_BASE_URL': _configuration.productionApiBaseUrl,
            'PAYMENT_CHECKOUT_URL': _configuration.productionCheckoutUrl,
          },
          approvedApiBaseUrl: _configuration.productionApiBaseUrl,
          approvedCheckoutUrl: _configuration.productionCheckoutUrl,
        ),
        throwsA(isA<ReleaseConfigurationException>()),
      );
    },
  );

  test(
    'controlled live checkout keeps production USA and single-use handoff requirements',
    () async {
      final fixture = await _auth();
      final payload = controlledPayload();
      var minted = 0;
      final launched = <Uri>[];
      final repository = AuthenticatedSandboxContentAccessRepository(
        configuration: _controlledConfiguration,
        authRepository: fixture.auth,
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode(payload), 200);
          }
          minted++;
          expect(request.url, _controlledConfiguration.handoffUri);
          expect(request.headers['Authorization'], 'Bearer fixture-access');
          expect(jsonDecode(request.body), {
            'purpose': 'purchase',
            'billing_period': 'monthly',
          });
          return http.Response(
            jsonEncode({
              'schema_version': 1,
              'parent_id': '42',
              'environment': 'production',
              'purpose': 'purchase',
              'billing_period': 'monthly',
              'code': List.filled(43, 'a').join(),
              'expires_in': 90,
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(seconds: 89))
                  .toIso8601String(),
            }),
            201,
          );
        }),
      );
      var country = 'CAN';
      final controller = SandboxCheckoutController(
        configuration: _controlledConfiguration,
        repository: repository,
        storefrontCountryProvider: () async => country,
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      addTearDown(controller.dispose);
      addTearDown(repository.dispose);
      await controller.refresh();
      expect(controller.canOpen, isTrue);
      await controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      expect(minted, 0);
      expect(launched, isEmpty);
      country = 'USA';
      await controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      expect(minted, 1);
      expect(
        launched.single.origin,
        'https://kingdom-kids-checkout-staging.onrender.com',
      );
      expect(launched.single.queryParameters, {'plan': 'monthly'});
      expect(launched.single.fragment, startsWith('handoff='));
      (payload['checkout'] as Map)['handoff_available'] = false;
      await controller.refresh();
      expect(controller.canOpen, isFalse);
    },
  );

  testWidgets(
    'controlled plan copy keeps prices and full periods while disclosing no automatic renewal',
    (tester) async {
      final controller = SandboxCheckoutController(
        configuration: _controlledConfiguration,
        repository: _Repository(
          SandboxContentAccess.fromJson(
            controlledPayload(),
            expectedParentId: '42',
            expectedEnvironment: 'production',
            allowControlledProduction: true,
          ),
        ),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionScreen(sandboxCheckout: controller)),
      );
      expect(find.text(r'$9.99'), findsOneWidget);
      expect(find.text('USD for 30 days'), findsOneWidget);
      expect(find.text('Automatic renewal is off'), findsOneWidget);
      expect(find.text('Every 30 days'), findsNothing);
      await tester.tap(find.byKey(const Key('subscription-yearly')));
      await tester.pumpAndSettle();
      expect(find.text(r'$99.90'), findsOneWidget);
      expect(find.text('USD for 12 months'), findsOneWidget);
      expect(find.text('12 calendar months of access'), findsOneWidget);
      expect(find.text('Every year after that'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('subscription-billing-details')),
      );
      await tester.tap(find.byKey(const Key('subscription-billing-details')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('renewing on your purchase anniversary'),
        findsNothing,
      );
      expect(
        find.textContaining('Automatic renewal is off.'),
        findsNWidgets(2),
      );
    },
  );
  test(
    'paid parent can mint only a management handoff while new purchases are paused',
    () async {
      final fixture = await _auth();
      final payload = _access(state: 'paid', purchase: false);
      (payload['checkout'] as Map)['handoff_available'] = false;
      var minted = 0;
      final launched = <Uri>[];
      final repository = AuthenticatedSandboxContentAccessRepository(
        configuration: _configuration,
        authRepository: fixture.auth,
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode(payload), 200);
          }
          minted++;
          expect(request.url, _configuration.handoffUri);
          expect(jsonDecode(request.body), {'purpose': 'manage'});
          return http.Response(
            jsonEncode({
              'schema_version': 1,
              'parent_id': '42',
              'environment': 'production',
              'purpose': 'manage',
              'billing_period': null,
              'code': List.filled(43, 'a').join(),
              'expires_in': 90,
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(seconds: 89))
                  .toIso8601String(),
            }),
            201,
          );
        }),
      );
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: repository,
        storefrontCountryProvider: () async => 'USA',
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      addTearDown(controller.dispose);
      addTearDown(repository.dispose);
      await controller.refresh();
      expect(controller.canOpen, isFalse);
      expect(controller.canManage, isTrue);
      await controller.openCheckout(
        billingPeriod: SubscriptionBillingPeriod.monthly,
      );
      expect(minted, 0);
      await controller.openManagement();
      expect(minted, 1);
      expect(launched.single.queryParameters, {'purpose': 'manage'});
      expect(launched.single.fragment, startsWith('handoff='));
      (payload['checkout'] as Map).remove('management_handoff_available');
      (payload['checkout'] as Map)['handoff_available'] = true;
      await controller.refresh();
      expect(controller.access!.managementHandoffAvailable, isFalse);
      expect(controller.canManage, isFalse);
      await controller.openManagement();
      expect(minted, 1);
      expect(controller.canOpen, isFalse);
    },
  );
  test(
    'a confirmed denial blocks cached private media and prepared narration scope',
    () async {
      final fixture = await _auth();
      const kid = KidProfile(
        id: 'kid',
        parentId: '42',
        displayName: 'Ada',
        avatarKey: 'dove',
      );
      await fixture.store.writeSession(
        const AuthSession(
          parent: ParentAccount(id: '42', email: 'parent@example.test'),
          accessToken: 'fixture-access',
          refreshToken: 'fixture-refresh',
          profiles: [kid],
        ),
      );
      await fixture.store.writeSelectedKidId(kid.id);
      final scope = (await fixture.auth.parentAccessScope())!;
      final media = MediaAccessScope(fixture.auth);
      final narration = StoryNarrationMetadataRefresher(
        story: const StoryDetail(
          id: 'story',
          slug: 'jonah',
          title: 'Jonah',
          author: 'Kingdom Kids',
          category: 'Bible',
          body: 'Previously loaded words.',
        ),
        authRepository: fixture.auth,
      );
      await media.requireCurrent();
      await narration.validateScope();
      paidContentAccessState.deny(scope);
      for (final denied in [
        media.requireCurrent(),
        narration.validateScope(),
      ]) {
        await expectLater(
          denied,
          throwsA(
            isA<AppException>().having(
              (error) => error.code,
              'code',
              'subscription_required',
            ),
          ),
        );
      }
      paidContentAccessState.allow(scope);
    },
  );

  test(
    'fresh canonical enforcement rollback clears a prior client denial without granting paid status',
    () async {
      final fixture = await _auth();
      final scope = (await fixture.auth.parentAccessScope())!;
      paidContentAccessState.deny(scope);
      final repository = AuthenticatedSandboxContentAccessRepository(
        configuration: _configuration,
        authRepository: fixture.auth,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              ..._access(),
              'content_enforcement_enabled': false,
              'parent_plan_routing_enabled': false,
            }),
            200,
          ),
        ),
      );
      final result = await repository.fetch();
      expect(result.state, SandboxAccessState.unpaid);
      expect(paidContentAccessState.isDenied, isFalse);
      repository.dispose();
      final controller = SandboxCheckoutController(
        configuration: _configuration,
        repository: _Repository(
          SandboxContentAccess.fromJson(
            _access(state: 'unknown'),
            expectedParentId: '42',
            expectedEnvironment: 'production',
          ),
        ),
      );
      await controller.refresh();
      expect(controller.canOpen, isFalse);
      controller.dispose();
    },
  );

  testWidgets('renewed canonical paid term cancels the previous expiry timer', (
    tester,
  ) async {
    final fixture = await _auth();
    final scope = (await fixture.auth.parentAccessScope())!;
    final repository = _HandoffRepository();
    SandboxContentAccess term(int seconds) => SandboxContentAccess(
      parentId: '42',
      state: SandboxAccessState.paid,
      checkoutAvailable: false,
      enforcementEnabled: true,
      routingEnabled: true,
      accessUntil: DateTime.now().toUtc().add(Duration(seconds: seconds)),
    );
    repository.value = term(2);
    final monitor = ParentContentAccessMonitor(
      configuration: _configuration,
      authRepository: fixture.auth,
      repository: repository,
    );
    addTearDown(monitor.dispose);
    await monitor.refresh();
    await tester.pump(const Duration(seconds: 1));
    repository.value = term(7);
    await monitor.refresh();
    await tester.pump(const Duration(seconds: 1));
    expect(paidContentAccessState.isDenied, isFalse);
    repository.fail = true;
    await tester.pump(const Duration(seconds: 6));
    expect(paidContentAccessState.isDenied, isTrue);
    monitor.dispose();
    paidContentAccessState.allow(scope);
  });
  testWidgets(
    'denied detail cannot resurrect old route arguments after family or child identity changes',
    (tester) async {
      for (final changeFamily in [true, false]) {
        final fixture = await _auth();
        final scope = (await fixture.auth.parentAccessScope())!;
        await tester.pumpWidget(
          MaterialApp(
            home: ScopedFeaturePage(
              key: ValueKey(changeFamily),
              route: '/games/play/private',
              identityBound: true,
              authRepository: fixture.auth,
              child: const Text('Original private game and family progress'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Original private game and family progress'),
          findsOneWidget,
        );
        paidContentAccessState.deny(scope);
        await tester.pumpAndSettle();
        if (changeFamily) {
          await fixture.store.writeSession(
            const AuthSession(
              parent: ParentAccount(
                id: 'new-parent',
                email: 'new@example.test',
              ),
              accessToken: 'new',
              refreshToken: 'new',
              profiles: [],
            ),
          );
        }
        // This is the notification emitted by the real sign-in/child switch.
        featureViewStateCache.clearIdentity();
        await fixture.auth.parentAccessScope();
        paidContentAccessState.allow(scope);
        await tester.pumpAndSettle();
        expect(
          find.text('Original private game and family progress'),
          findsNothing,
        );
        expect(
          find.text('This profile changed. Return to the library.'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  test(
    'production monitor handles temporary protected-storage failures without changing paid state',
    () async {
      final monitor = ParentContentAccessMonitor(
        configuration: _configuration,
        authRepository: _UnavailableStorageAuth(),
        repository: _Repository(
          SandboxContentAccess.fromJson(
            _access(),
            expectedParentId: '42',
            expectedEnvironment: 'production',
          ),
        ),
      );
      await expectLater(monitor.refresh(), completes);
      monitor.dispose();
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native storefront bridge returns actual three-letter region and fails closed when unavailable',
    () async {
      const channel = MethodChannel('kingdom_kids/storefront');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      for (final country in <String?>['USA', 'CAN', null]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'currentCountryCode');
          return country;
        });
        expect(await AppStoreStorefront.currentCountryCode(), country);
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect(await AppStoreStorefront.currentCountryCode(), isNull);
    },
  );

  test(
    'production link requires USA at mint and launch; paid Manage never purchases',
    () async {
      for (final countries in <List<String?>>[
        [null],
        ['CAN'],
        ['USA', 'CAN'],
        ['USA', 'USA'],
      ]) {
        final repository = _HandoffRepository();
        var calls = 0;
        final launches = <Uri>[];
        final controller = SandboxCheckoutController(
          configuration: _configuration,
          repository: repository,
          storefrontCountryProvider: () async =>
              countries[(calls++).clamp(0, countries.length - 1)],
          launcher: (uri) async {
            launches.add(uri);
            return true;
          },
        );
        await controller.refresh();
        await controller.openCheckout(
          billingPeriod: SubscriptionBillingPeriod.monthly,
        );
        expect(launches.length, countries.last == 'USA' ? 1 : 0);
        if (launches.isNotEmpty) {
          expect(launches.single.queryParameters, {'plan': 'monthly'});
        }
        repository.value = SandboxContentAccess.fromJson(
          _access(state: 'paid', purchase: false),
          expectedParentId: '42',
          expectedEnvironment: 'production',
        );
        await controller.refresh();
        expect(controller.canOpen, isFalse);
        expect(controller.canManage, isTrue);
        controller.dispose();
      }
    },
  );

  test('parent change during handoff mint prevents browser launch', () async {
    final fixture = await _auth();
    final response = Completer<http.Response>();
    final repository = AuthenticatedSandboxContentAccessRepository(
      configuration: _configuration,
      authRepository: fixture.auth,
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(jsonEncode(_access()), 200);
        }
        return response.future;
      }),
    );
    var launches = 0;
    final controller = SandboxCheckoutController(
      configuration: _configuration,
      repository: repository,
      storefrontCountryProvider: () async => 'USA',
      launcher: (_) async {
        launches++;
        return true;
      },
    );
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    await controller.refresh();
    final opening = controller.openCheckout(
      billingPeriod: SubscriptionBillingPeriod.monthly,
    );
    await Future<void>.delayed(Duration.zero);
    await fixture.store.clear();
    response.complete(
      http.Response(
        jsonEncode({
          'schema_version': 1,
          'parent_id': '42',
          'environment': 'production',
          'purpose': 'purchase',
          'billing_period': 'monthly',
          'code': List.filled(43, 'a').join(),
          'expires_in': 90,
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 89))
              .toIso8601String(),
        }),
        201,
      ),
    );
    await opening;
    expect(launches, 0);
  });

  testWidgets(
    'real retained story body survives temporary HTTP failure and disappears on subscription denial',
    (tester) async {
      for (final status in [503, 403]) {
        final fixture = await _auth();
        final pending = Completer<http.Response>();
        final repository = RemoteStoryRepository(
          authRepository: fixture.auth,
          api: HttpStoryApi(client: MockClient((_) => pending.future)),
        );
        const story = StoryDetail(
          id: 'private-story',
          slug: 'jonah',
          title: 'Jonah',
          author: 'Kingdom Kids',
          category: 'Bible',
          body: 'Private story text previously loaded.',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ScopedFeaturePage(
              key: ValueKey(status),
              route: '/stories/detail/jonah',
              identityBound: true,
              authRepository: fixture.auth,
              child: StoryDetailScreen(
                story: story,
                repository: repository,
                authRepository: fixture.auth,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text(story.body), findsOneWidget);
        pending.complete(
          http.Response(
            jsonEncode({
              'code': status == 403
                  ? 'subscription_required'
                  : 'temporary_error',
              'detail': 'Unavailable',
            }),
            status,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(story.body),
          status == 403 ? findsNothing : findsOneWidget,
        );
        if (status == 403) {
          paidContentAccessState.allow(
            (await fixture.auth.parentAccessScope())!,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  test(
    'production requires explicit mode, environment, and exact secure compiled endpoints',
    () {
      expect(_configuration.isProductionEnabled, isTrue);
      for (final configuration in [
        const SandboxCheckoutConfiguration(
          apiBaseUrl: 'https://api.example.test/api',
        ),
        const SandboxCheckoutConfiguration(
          productionEnabled: true,
          apiBaseUrl: 'https://api.example.test/api',
          productionApiBaseUrl: 'https://api.example.test/api',
          productionCheckoutUrl: 'https://api.example.test/parent/checkout/',
        ),
        const SandboxCheckoutConfiguration(
          productionEnabled: true,
          paymentEnvironment: 'production',
          apiBaseUrl: 'https://other.example.test/api',
          productionApiBaseUrl: 'https://api.example.test/api',
          productionCheckoutUrl: 'https://api.example.test/parent/checkout/',
        ),
      ]) {
        expect(configuration.isEnabled, isFalse);
      }
      for (final url in [
        'http://api.example.test/parent/checkout/',
        'https://user:password@api.example.test/parent/checkout/',
        'https://api.example.test/parent/checkout/?plan=monthly',
        'https://127.0.0.1/parent/checkout/',
        'https://api.example.test/parent/checkout/#handoff=anything',
        'https://other.example.test/parent/checkout/',
      ]) {
        expect(
          SandboxCheckoutConfiguration(
            productionEnabled: true,
            paymentEnvironment: 'production',
            apiBaseUrl: _configuration.apiBaseUrl,
            productionApiBaseUrl: _configuration.productionApiBaseUrl,
            productionCheckoutUrl: url,
          ).isEnabled,
          isFalse,
        );
      }
    },
  );

  test(
    'production parser separates entitlement, purchase and paused-checkout management',
    () {
      final paid = SandboxContentAccess.fromJson(
        _access(state: 'paid', purchase: false),
        expectedParentId: '42',
        expectedEnvironment: 'production',
      );
      expect(paid.state, SandboxAccessState.paid);
      expect(paid.checkoutAvailable, isFalse);
      expect(paid.managementAvailable, isTrue);
      expect(
        () => SandboxContentAccess.fromJson(_access(), expectedParentId: '42'),
        throwsFormatException,
      );
      final disabled = SandboxContentAccess.fromJson(
        {..._access(), 'content_enforcement_enabled': false},
        expectedParentId: '42',
        expectedEnvironment: 'production',
      );
      expect(disabled.checkoutAvailable, isFalse);
      expect(disabled.managementAvailable, isTrue);
    },
  );

  test(
    'handoff request uses bearer only at canonical API and fixed compiled browser destination',
    () async {
      final fixture = await _auth();
      var posts = 0;
      final repository = AuthenticatedSandboxContentAccessRepository(
        configuration: _configuration,
        authRepository: fixture.auth,
        client: MockClient((request) async {
          posts++;
          expect(request.url, _configuration.handoffUri);
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer fixture-access');
          final body = jsonDecode(request.body) as Map;
          return http.Response(
            jsonEncode({
              'schema_version': 1,
              'parent_id': '42',
              'environment': 'production',
              ...body,
              'billing_period': body['billing_period'],
              'code': List.filled(43, 'a').join(),
              'expires_in': 90,
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(seconds: 89))
                  .toIso8601String(),
            }),
            201,
          );
        }),
      );
      addTearDown(repository.dispose);
      final purchase = await repository.createHandoff(
        billingPeriod: SubscriptionBillingPeriod.yearly,
      );
      expect(
        purchase.removeFragment(),
        Uri.parse('https://api.example.test/parent/checkout/?plan=yearly'),
      );
      expect(purchase.fragment, 'handoff=${List.filled(43, 'a').join()}');
      final manage = await repository.createHandoff(manage: true);
      expect(manage.queryParameters, {'purpose': 'manage'});
      expect(await repository.canLaunchHandoff(), isTrue);
      await fixture.store.clear();
      expect(await repository.canLaunchHandoff(), isFalse);
      expect(posts, 2);
    },
  );

  test(
    'handoff rejects mismatched parent/environment/purpose, arbitrary destination, expired and malformed codes',
    () async {
      final fixture = await _auth();
      for (final change in <Map<String, Object?>>[
        {'parent_id': 'other'},
        {'environment': 'sandbox'},
        {'purpose': 'manage'},
        {'billing_period': 'yearly'},
        {'url': 'https://evil.example/'},
        {'code': 'bad'},
        {'expires_in': 91},
        {'expires_at': '2000-01-01T00:00:00Z'},
      ]) {
        final repository = AuthenticatedSandboxContentAccessRepository(
          configuration: _configuration,
          authRepository: fixture.auth,
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'schema_version': 1,
                'parent_id': '42',
                'environment': 'production',
                'purpose': 'purchase',
                'billing_period': 'monthly',
                'code': List.filled(43, 'a').join(),
                'expires_in': 90,
                'expires_at': DateTime.now()
                    .toUtc()
                    .add(const Duration(seconds: 89))
                    .toIso8601String(),
                ...change,
              }),
              201,
            ),
          ),
        );
        await expectLater(
          repository.createHandoff(
            billingPeriod: SubscriptionBillingPeriod.monthly,
          ),
          throwsFormatException,
        );
        expect(await repository.canLaunchHandoff(), isFalse);
        repository.dispose();
      }
    },
  );

  test(
    'a paid response started before a later denial cannot restore cached access',
    () async {
      final fixture = await _auth();
      final scope = (await fixture.auth.parentAccessScope())!;
      final pending = Completer<http.Response>();
      final repository = AuthenticatedSandboxContentAccessRepository(
        configuration: _configuration,
        authRepository: fixture.auth,
        client: MockClient((_) => pending.future),
      );
      final read = repository.fetch();
      final assertion = expectLater(read, throwsA(isA<AppException>()));
      await Future<void>.delayed(Duration.zero);
      paidContentAccessState.deny(scope);
      pending.complete(http.Response(jsonEncode(_access(state: 'paid')), 200));
      await assertion;
      expect(paidContentAccessState.isDenied, isTrue);
      paidContentAccessState.allow(scope);
      repository.dispose();
    },
  );

  testWidgets(
    'authoritative denial removes retained child content, preserves parent navigation and does not react to network errors',
    (tester) async {
      final fixture = await _auth();
      final scope = await fixture.auth.parentAccessScope();
      await tester.pumpWidget(
        MaterialApp(
          home: ScopedFeaturePage(
            route: '/stories/detail/fixture',
            identityBound: true,
            authRepository: fixture.auth,
            child: const Text('Previously loaded private story'),
          ),
          routes: {
            '/parental-controls': (_) =>
                const Text('Parent account deletion controls'),
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Previously loaded private story'), findsOneWidget);
      await expectLater(
        fixture.auth.withAccessToken(
          (_) async =>
              throw const AppException('Offline', code: 'network_error'),
        ),
        throwsA(isA<AppException>()),
      );
      await tester.pump();
      expect(find.text('Previously loaded private story'), findsOneWidget);
      final generation = featureReadCache.mediaGeneration;
      await expectLater(
        fixture.auth.withAccessToken(
          (_) async => throw const AppException(
            'Denied',
            statusCode: 403,
            code: 'subscription_required',
          ),
        ),
        throwsA(isA<AppException>()),
      );
      await tester.pumpAndSettle();
      expect(featureReadCache.mediaGeneration, greaterThan(generation));
      expect(find.text('Previously loaded private story'), findsNothing);
      expect(find.byKey(const Key('paid-content-parent-help')), findsOneWidget);
      await tester.tap(find.text('Parent account settings'));
      await tester.pumpAndSettle();
      expect(find.text('Parent account deletion controls'), findsOneWidget);
      paidContentAccessState.allow(scope!);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'old-family denial finishing after an account switch does not block the new parent',
    () async {
      final fixture = await _auth();
      final pending = Completer<String>();
      final operation = fixture.auth.withAccessToken((_) => pending.future);
      final assertion = expectLater(operation, throwsA(isA<AppException>()));
      await Future<void>.delayed(Duration.zero);
      await fixture.store.writeSession(
        const AuthSession(
          parent: ParentAccount(id: 'new', email: 'new@example.test'),
          accessToken: 'new',
          refreshToken: 'new',
          profiles: [],
        ),
      );
      pending.completeError(
        const AppException(
          'Denied',
          statusCode: 403,
          code: 'subscription_required',
        ),
      );
      await assertion;
      await fixture.auth.parentAccessScope();
      expect(paidContentAccessState.isDenied, isFalse);
    },
  );

  testWidgets('paid parent has Manage and never a new-charge action', (
    tester,
  ) async {
    final controller = SandboxCheckoutController(
      configuration: _configuration,
      repository: _Repository(
        SandboxContentAccess.fromJson(
          _access(state: 'paid', purchase: false),
          expectedParentId: '42',
          expectedEnvironment: 'production',
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    expect(controller.canOpen, isFalse);
    expect(controller.canManage, isTrue);
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionScreen(sandboxCheckout: controller)),
    );
    expect(find.text('Access active'), findsOneWidget);
    expect(find.text('Manage subscription'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('subscription-parent-continue')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'production monitor retains unexpired paid access on transient failure and blocks at original term end',
    (tester) async {
      final fixture = await _auth();
      final scope = await fixture.auth.parentAccessScope();
      final repository = _Repository(
        SandboxContentAccess(
          parentId: '42',
          state: SandboxAccessState.paid,
          checkoutAvailable: false,
          enforcementEnabled: true,
          routingEnabled: true,
          accessUntil: DateTime.now().toUtc().add(const Duration(seconds: 2)),
        ),
      );
      final monitor = ParentContentAccessMonitor(
        configuration: _configuration,
        authRepository: fixture.auth,
        repository: repository,
      );
      await monitor.refresh();
      repository.fail = true;
      await monitor.refresh();
      expect(paidContentAccessState.isDenied, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(paidContentAccessState.isDenied, isTrue);
      monitor.dispose();
      paidContentAccessState.allow(scope!);
    },
  );

  test(
    'App Store preflight rejects Sandbox/review input and unapproved live origins',
    () {
      final defines = <String, dynamic>{
        'APP_STORE_BUNDLE_ID': 'app.kingdom-kids.kingdomkids',
        'APP_STORE_TEAM_ID': 'GG228DP7G6',
        'API_BASE_URL': _configuration.apiBaseUrl,
        'CONTENT_MEDIA_HOSTS': '',
        'PRODUCTION_PAYMENT_FLOW_ENABLED': true,
        'PAYMENT_ENVIRONMENT': 'production',
        'PAYMENT_API_BASE_URL': _configuration.productionApiBaseUrl,
        'PAYMENT_CHECKOUT_URL': _configuration.productionCheckoutUrl,
      };
      void validate(Map<String, dynamic> value) => validateAppStoreRelease(
        value,
        approvedApiBaseUrl: _configuration.productionApiBaseUrl,
        approvedCheckoutUrl: _configuration.productionCheckoutUrl,
      );
      expect(() => validate(defines), returnsNormally);
      for (final change in <Map<String, dynamic>>[
        {'APP_STORE_BUNDLE_ID': 'com.andreovien.kingdomkids'},
        {'APP_STORE_TEAM_ID': 'VTV9889TNF'},
        {'APP_STORE_BUNDLE_ID': ''},
        {'APP_STORE_TEAM_ID': ''},
        {'SQUARE_SANDBOX_CHECKOUT_ENABLED': true},
        {'HOSTED_RETURN_SCHEME_ONLY_PREVIEW': true},
        {'SUBSCRIPTION_REVIEW_ID': 'local-preview'},
        {'ONBOARDING_REVIEW_ID': 'local-onboarding'},
        {'PAYMENT_ENVIRONMENT': 'sandbox'},
        {'PRODUCTION_PAYMENT_FLOW_ENABLED': false},
        {'PAYMENT_CHECKOUT_URL': 'https://other.example.test/parent/checkout/'},
      ]) {
        expect(
          () => validate({...defines, ...change}),
          throwsA(isA<ReleaseConfigurationException>()),
        );
      }
    },
  );
}

class _Repository implements SandboxContentAccessRepository {
  _Repository(this.value);
  final SandboxContentAccess value;
  bool fail = false;
  @override
  Future<SandboxContentAccess> fetch() async {
    if (fail) throw const AppException('Offline', code: 'network_error');
    return value;
  }
}

class _UnavailableStorageAuth extends AuthRepository {
  @override
  Future<Object?> parentAccessScope() async =>
      throw const AppException('Protected storage temporarily unavailable');
}

class _HandoffRepository
    implements SandboxContentAccessRepository, ParentCheckoutHandoffRepository {
  SandboxContentAccess value = SandboxContentAccess.fromJson(
    _access(),
    expectedParentId: '42',
    expectedEnvironment: 'production',
  );
  bool fail = false;
  @override
  Future<SandboxContentAccess> fetch() async {
    if (fail) throw const AppException('Offline', code: 'network_error');
    return value;
  }

  @override
  Future<Uri> createHandoff({
    SubscriptionBillingPeriod? billingPeriod,
    bool manage = false,
  }) async => _configuration
      .browserUri(period: billingPeriod, manage: manage)
      .replace(fragment: 'handoff=${List.filled(43, 'a').join()}');
  @override
  Future<bool> canLaunchHandoff() async => true;
}
