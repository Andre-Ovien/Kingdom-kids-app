import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/core/network/feature_view_state_cache.dart';
import 'package:mobile/core/network/paid_content_access_state.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/auth_requests.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/games/presentation/games_screen.dart';
import 'package:mobile/features/games/presentation/game_detail_screen.dart';
import 'package:mobile/features/bible/presentation/bible_screen.dart';
import 'package:mobile/features/home/presentation/home_screen.dart';
import 'package:mobile/features/milestones/presentation/level_milestone_screen.dart';
import 'package:mobile/features/profile/presentation/profile_screen.dart';
import 'package:mobile/features/stories/presentation/stories_screen.dart';
import 'package:mobile/features/stories/presentation/story_detail_screen.dart';
import 'package:mobile/features/stories/presentation/read_along_screen.dart';
import 'package:mobile/features/auth/presentation/profile_picker_screen.dart';
import 'package:mobile/features/auth/presentation/kid_profile_setup_screen.dart';
import 'package:mobile/features/streak/presentation/streak_screen.dart';
import 'package:mobile/features/subscription/data/hosted_checkout_pending_store.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_controller.dart';
import 'package:mobile/features/subscription/data/hosted_subscription_repository.dart';
import 'package:mobile/features/subscription/data/sandbox_checkout.dart';
import 'package:mobile/features/subscription/presentation/hosted_paid_route_boundary.dart';
import 'package:mobile/features/subscription/presentation/hosted_parent_authorization.dart';
import 'package:mobile/features/subscription/presentation/hosted_subscription_scope.dart';
import 'package:mobile/features/subscription/presentation/subscription_parent_screen.dart';
import 'package:mobile/features/videos/presentation/video_watch_screen.dart';
import 'package:mobile/features/videos/presentation/videos_screen.dart';
import 'package:mobile/shared/widgets/liquid_navigation_controller.dart';
import 'package:mobile/shared/widgets/persistent_liquid_navigation_host.dart';

const _configuration = SandboxCheckoutConfiguration(
  productionEnabled: true,
  hostedSubscriptionsEnabled: true,
  paymentEnvironment: 'production',
  apiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionApiBaseUrl: SandboxCheckoutConfiguration.approvedApiBaseUrl,
  productionCheckoutUrl: SandboxCheckoutConfiguration.checkoutUrl,
);
const _kid = KidProfile(
  id: 'kid-unpaid-navigation',
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

class _Api extends Fake implements AuthApi {
  AuthSession loginResult = _session;
  @override
  Future<AuthSession> login(LoginRequest request) async => loginResult;
  @override
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) async {}
}

class _DelayedSessionStore extends MemoryAuthSessionStore {
  bool holdAfterWrite = false;
  Completer<void>? releaseRead;
  @override
  Future<void> writeSession(AuthSession session) async {
    await super.writeSession(session);
    if (holdAfterWrite) releaseRead = Completer<void>();
  }

  @override
  Future<AuthSession?> readSession() async {
    final hold = releaseRead;
    if (hold != null) await hold.future;
    return super.readSession();
  }
}

class _Store implements HostedCheckoutPendingStore {
  @override
  Future<HostedPendingCheckout?> read(String parentId) async => null;
  @override
  Future<void> write(HostedPendingCheckout pending) async =>
      throw StateError('Navigation cannot create a checkout attempt.');
  @override
  Future<void> clear(String parentId) async {}
}

class _Repository extends Fake implements HostedSubscriptionRepository {
  SandboxAccessState state = SandboxAccessState.unpaid;
  DateTime? until;
  bool offline = false;
  int reads = 0;
  @override
  Future<({SandboxContentAccess access, Map<String, dynamic>? recovery})>
  access() async {
    reads++;
    if (offline) throw StateError('Offline fixture');
    return (
      access: SandboxContentAccess(
        parentId: '42',
        state: state,
        checkoutAvailable: state == SandboxAccessState.unpaid,
        accessUntil: until,
        enforcementEnabled: true,
        routingEnabled: true,
      ),
      recovery: null,
    );
  }
}

class _Harness {
  _Harness(this.auth, this.repository) {
    checkout = HostedSubscriptionController(
      configuration: _configuration,
      repository: repository,
      pendingStore: _Store(),
      authRepository: auth,
      launcher: (_) async =>
          throw StateError('Navigation cannot open the provider.'),
    );
    navigation = LiquidNavigationController(
      navigatorKey: navigator,
      onAcceptedSelection: () {},
      loadProfile: () async => _kid,
    );
    observer = LiquidNavigationObserver(navigation);
  }
  final AuthRepository auth;
  final _Repository repository;
  final navigator = GlobalKey<NavigatorState>();
  late final HostedSubscriptionController checkout;
  late final LiquidNavigationController navigation;
  late final LiquidNavigationObserver observer;
  String? topRoute;

  Route<dynamic> _route(RouteSettings settings) {
    // The router uses compile-time defaults. Inject the identical real plans
    // class here so this test never needs a hosted production build define.
    if (settings.name == AppRoutes.subscription) {
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => SubscriptionParentScreen(
          configuration: _configuration,
          authRepository: auth,
        ),
      );
    }
    return AppRouter.onGenerateRoute(settings);
  }

  Widget app(
    String initialRoute, {
    bool paidSentinel = false,
    double textScale = 1,
  }) => MaterialApp(
    debugShowCheckedModeBanner: false,
    navigatorKey: navigator,
    theme: buildKingdomKidsTheme().copyWith(platform: TargetPlatform.iOS),
    initialRoute: initialRoute,
    onGenerateInitialRoutes: (name) => [
      paidSentinel
          ? MaterialPageRoute<void>(
              settings: RouteSettings(name: name),
              builder: (_) => const HostedPaidRouteBoundary(
                child: Scaffold(body: Text('Paid child content')),
              ),
            )
          : _route(RouteSettings(name: name)),
    ],
    onGenerateRoute: _route,
    navigatorObservers: [observer, _TopRoute((name) => topRoute = name)],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: HostedSubscriptionScope(
        navigatorKey: navigator,
        configuration: _configuration,
        controller: checkout,
        authRepository: auth,
        initialReturn: Future.value(null),
        returnLinks: const Stream.empty(),
        child: PersistentLiquidNavigationHost(
          controller: navigation,
          child: child!,
        ),
      ),
    ),
  );

  void dispose() {
    checkout.dispose();
    navigation.dispose();
  }
}

class _TopRoute extends NavigatorObserver {
  _TopRoute(this.report);
  final void Function(String?) report;
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    report(topRoute.settings.name);
  }
}

Future<_Harness> _fixture({
  SandboxAccessState state = SandboxAccessState.unpaid,
  DateTime? until,
  bool offline = false,
  bool restored = false,
}) async {
  final sessions = MemoryAuthSessionStore();
  await sessions.writeSession(_session);
  await sessions.writeSelectedKidId(_kid.id);
  final auth = AuthRepository(api: _Api(), sessionStore: sessions);
  if (restored) {
    // Drop any fresh proof from earlier test sessions, then restore only the
    // persisted family/selected child as a cold process would do.
    await auth.logout();
    await sessions.writeSession(_session);
    await sessions.writeSelectedKidId(_kid.id);
  } else {
    await auth.login(
      const LoginRequest(email: 'parent@example.test', password: 'fixture'),
    );
  }
  final repository = _Repository()
    ..state = state
    ..until = until
    ..offline = offline;
  final fixture = _Harness(auth, repository);
  await fixture.checkout.refresh();
  return fixture;
}

void _expectNoChildShell() {
  expect(find.text('Subscription required'), findsNothing);
  for (final type in [
    HomeScreen,
    StoriesScreen,
    GamesScreen,
    GameDetailScreen,
    BibleScreen,
    ProfileScreen,
    VideoWatchScreen,
    VideosScreen,
    StoryDetailScreen,
    ReadAlongScreen,
    ProfilePickerScreen,
    KidProfileSetupScreen,
    StreakScreen,
    LevelMilestoneScreen,
  ]) {
    expect(find.byType(type), findsNothing, reason: '$type must not mount.');
  }
  expect(find.byKey(const Key('bottom-nav-main-dock')), findsNothing);
  expect(find.byKey(const Key('bottom-nav-profile')), findsNothing);
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    paidContentAccessState.selectScope(null);
    featureViewStateCache.clearIdentity();
  });
  tearDown(() => paidContentAccessState.selectScope(null));

  for (final route in [
    AppRoutes.home,
    AppRoutes.stories,
    AppRoutes.games,
    AppRoutes.gameDetail,
    AppRoutes.bible,
    AppRoutes.profile,
    AppRoutes.videos,
    AppRoutes.videoDetail,
    AppRoutes.storyDetail,
    AppRoutes.storyReadAlong,
    AppRoutes.profilePicker,
    AppRoutes.kidProfileSetup,
    AppRoutes.parentalControls,
    AppRoutes.streak,
    AppRoutes.levelMilestone,
    '/an-unknown-child-route',
  ]) {
    testWidgets('authoritative unpaid direct route $route has no child shell', (
      tester,
    ) async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app(route));
      await _pump(tester);
      expect(
        find.byKey(const Key('subscription-required-carousel')),
        findsOneWidget,
      );
      _expectNoChildShell();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final systemBack in [false, true]) {
    testWidgets(
      'unpaid plans ${systemBack ? 'system' : 'app bar'} back ends on standalone access page',
      (tester) async {
        final fixture = await _fixture();
        addTearDown(fixture.dispose);
        await tester.pumpWidget(fixture.app(AppRoutes.home));
        await _pump(tester);
        unawaited(
          fixture.navigator.currentState!.pushNamed(AppRoutes.subscription),
        );
        await _pump(tester);
        expect(find.byKey(const Key('subscription-back')), findsOneWidget);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byKey(const Key('subscription-back')));
        }
        await _pump(tester);
        expect(
          find.byKey(const Key('subscription-required-carousel')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('subscription-required-view-plans')),
          findsOneWidget,
        );
        expect(fixture.topRoute, isNot(AppRoutes.parentalControls));
        expect(fixture.topRoute, isNot(AppRoutes.home));
        _expectNoChildShell();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('unpaid swipe back cannot expose an underlying child route', (
    tester,
  ) async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(AppRoutes.games));
    await _pump(tester);
    unawaited(
      fixture.navigator.currentState!.pushNamed(AppRoutes.subscription),
    );
    await _pump(tester);
    await tester.dragFrom(const Offset(1, 280), const Offset(650, 0));
    await _pump(tester);
    _expectNoChildShell();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final offline in [false, true]) {
    testWidgets(
      '${offline ? 'offline' : 'unknown'} status is never an unpaid claim',
      (tester) async {
        final fixture = await _fixture(
          state: SandboxAccessState.unknown,
          offline: offline,
        );
        addTearDown(fixture.dispose);
        await tester.pumpWidget(fixture.app(AppRoutes.home));
        await _pump(tester);
        expect(
          find.byKey(const Key('subscription-required-carousel')),
          findsNothing,
        );
        expect(find.byKey(const Key('hosted-access-unknown')), findsOneWidget);
        expect(
          find.text('We could not verify your subscription.'),
          findsOneWidget,
        );
        for (final control in [
          'Sign out',
          'Privacy',
          'Password help',
          'Delete account',
        ]) {
          expect(find.text(control), findsOneWidget);
        }
        _expectNoChildShell();
        expect(fixture.checkout.canOpen, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('unexpired canonical paid access bypasses gate and shows dock', (
    tester,
  ) async {
    final fixture = await _fixture(
      state: SandboxAccessState.paid,
      until: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(AppRoutes.home, paidSentinel: true));
    await _pump(tester);
    expect(fixture.checkout.canBrowse, isTrue);
    expect(find.text('Paid child content'), findsOneWidget);
    expect(find.byKey(const Key('bottom-nav-main-dock')), findsOneWidget);
    expect(
      find.byKey(const Key('subscription-required-carousel')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'expired canonical paid snapshot cannot bypass access boundary',
    () async {
      final fixture = await _fixture(
        state: SandboxAccessState.paid,
        until: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      );
      addTearDown(fixture.dispose);
      expect(fixture.checkout.canBrowse, isFalse);
    },
  );

  testWidgets(
    'identity change hides old paid pixels while secure owner read is delayed',
    (tester) async {
      final sessions = _DelayedSessionStore();
      await sessions.writeSession(_session);
      final api = _Api();
      final auth = AuthRepository(api: api, sessionStore: sessions);
      final repository = _Repository()
        ..state = SandboxAccessState.paid
        ..until = DateTime.now().toUtc().add(const Duration(hours: 1));
      final fixture = _Harness(auth, repository);
      addTearDown(fixture.dispose);
      await fixture.checkout.refresh();
      await tester.pumpWidget(fixture.app(AppRoutes.home, paidSentinel: true));
      await _pump(tester);
      expect(find.text('Paid child content'), findsOneWidget);
      sessions.holdAfterWrite = true;
      api.loginResult = const AuthSession(
        parent: ParentAccount(id: 'other-parent', email: 'other@example.test'),
        accessToken: 'other-fixture-access',
        refreshToken: 'other-fixture-refresh',
      );
      await auth.login(
        const LoginRequest(email: 'other@example.test', password: 'fixture'),
      );
      final release = sessions.releaseRead!;
      try {
        await tester.pump();
        expect(fixture.checkout.canBrowse, isFalse);
        expect(find.text('Paid child content'), findsNothing);
        expect(find.byKey(const Key('bottom-nav-main-dock')), findsNothing);
      } finally {
        repository.state = SandboxAccessState.unpaid;
        release.complete();
        await _pump(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'standalone unpaid gate keeps controls reachable at 320px and 2.2x text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.app(AppRoutes.subscriptionRequired, textScale: 2.2),
      );
      await _pump(tester);
      expect(
        find.byKey(const Key('subscription-required-carousel')),
        findsOneWidget,
      );
      for (final key in [
        'subscription-required-view-plans',
        'subscription-required-sign-out',
        'subscription-required-delete-account',
      ]) {
        final control = find.byKey(Key(key));
        await tester.ensureVisible(control);
        await tester.pump();
        expect(control.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      _expectNoChildShell();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('restored selected-child plans require the real adult gate', (
    tester,
  ) async {
    final fixture = await _fixture(restored: true);
    addTearDown(fixture.dispose);
    expect(fixture.checkout.requiresParentGate, isTrue);
    await tester.pumpWidget(fixture.app(AppRoutes.subscription));
    await _pump(tester);
    expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
    expect(find.byKey(const Key('adult-gate-password')), findsOneWidget);
    expect(find.byKey(const Key('subscription-back')), findsNothing);
    _expectNoChildShell();
    await tester.tap(find.byTooltip('Back'));
    await _pump(tester);
    expect(fixture.topRoute, AppRoutes.subscriptionRequired);
    expect(
      find.byKey(const Key('subscription-required-carousel')),
      findsOneWidget,
    );
    _expectNoChildShell();
    await tester.tap(find.byKey(const Key('subscription-required-view-plans')));
    await _pump(tester);
    expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _pump(tester);
    expect(fixture.topRoute, AppRoutes.subscriptionRequired);
    expect(
      find.byKey(const Key('subscription-required-carousel')),
      findsOneWidget,
    );
    _expectNoChildShell();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  if (const bool.fromEnvironment('CAPTURE_NATIVE_GATE')) {
    testWidgets('render the actual three bundled subscription gate slides', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final avenir = File('/System/Library/Fonts/Avenir Next.ttc');
        final data = ByteData.sublistView(await avenir.readAsBytes());
        await (FontLoader('Avenir Next')..addFont(Future.value(data))).load();
        await (FontLoader('Roboto')..addFont(Future.value(data))).load();
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                await rootBundle.load('fonts/MaterialIcons-Regular.otf'),
              ),
            ))
            .load();
      });
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: fixture.app(AppRoutes.subscriptionRequired),
        ),
      );
      await _pump(tester);
      await tester.runAsync(() async {
        final context = tester.element(
          find.byKey(const Key('subscription-required-carousel')),
        );
        for (final name in ['stories', 'games', 'together']) {
          await precacheImage(
            AssetImage('assets/images/subscription/access-$name-v1.png'),
            context,
          );
        }
      });
      final carousel = tester.widget<PageView>(
        find.byKey(const Key('subscription-required-carousel')),
      );
      for (var slide = 0; slide < 3; slide++) {
        carousel.controller!.jumpToPage(slide);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(carousel.controller!.page, slide.toDouble());
        expect(
          find.text(
            const [
              'Wonderful stories await',
              'Play, discover, and grow',
              'Every adventure, one subscription',
            ][slide],
          ),
          findsOneWidget,
        );
        expect(find.text('Subscription required'), findsNothing);
        expect(
          find
              .byKey(const Key('subscription-required-view-plans'))
              .hitTestable(),
          findsOneWidget,
        );
        _expectNoChildShell();
        expect(tester.takeException(), isNull);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final bitmap = await boundary.toImage(pixelRatio: 3);
          final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            '../../output/subscription-gate-20261112',
          ).absolute;
          await output.create(recursive: true);
          final file = File('${output.path}/gate-slide-${slide + 1}.png');
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          bitmap.dispose();
          stdout.writeln('Saved ${file.path}');
        });
      }
      // Public monthly disclosure fixture from hosted_policies.disclosure.
      // This is a layout render: its callback must never authorize a purchase.
      var authorizationCalls = 0;
      final consent = showHostedParentAuthorization(
        tester.element(
          find.byKey(const Key('subscription-required-view-plans')),
        ),
        title: 'Subscription terms',
        disclosure:
            r'Square will charge $9.99 USD now and automatically every 30 days until you cancel. '
            'Each successful payment provides 30 days of access to all stories and games, starting when payment completes. '
            'Square saves your card and manages recurring payments on its secure payment page. '
            'There is no free period or proration. Renewal billing follows Square’s subscription dates; '
            'it is not promised to occur at the same time of day as your first payment. '
            'You can stop future renewals in parent account settings. Canceling keeps your verified already-paid access until its original end.',
        authorize: () async {
          authorizationCalls++;
        },
      );
      bool? consentResult;
      unawaited(
        consent.then((value) {
          consentResult = value;
        }),
      );
      await tester.pumpAndSettle();
      final checkbox = find.byKey(const Key('hosted-subscription-consent'));
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      expect(find.byKey(const Key('hosted-parent-password')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('hosted-authorize-continue')),
            )
            .onPressed,
        isNotNull,
      );
      expect(authorizationCalls, 0);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final bitmap = await boundary.toImage(pixelRatio: 3);
        final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '../../output/subscription-gate-20261112/consent-terms.png',
        ).absolute;
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        bitmap.dispose();
        stdout.writeln('Saved ${file.path}');
      });
      fixture.navigator.currentState!.pop(false);
      await tester.pumpAndSettle();
      expect(consentResult, isFalse);
      expect(authorizationCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
