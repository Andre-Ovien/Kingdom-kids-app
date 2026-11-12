import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:mobile/features/subscription/presentation/hosted_subscription_scope.dart';
import 'package:mobile/features/subscription/presentation/subscription_parent_screen.dart';
import 'package:mobile/features/subscription/presentation/subscription_screen.dart';
import 'package:mobile/features/privacy/presentation/privacy_policy_screen.dart';
import 'package:mobile/features/auth/presentation/password_reset_screen.dart';
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
  bool offline = false, complimentary = false;
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
        complimentaryAccess: complimentary,
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
  bool complimentary = false,
  bool signedIn = true,
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
  if (!signedIn) await auth.logout();
  final repository = _Repository()
    ..state = state
    ..until = until
    ..offline = offline
    ..complimentary = complimentary;
  final fixture = _Harness(auth, repository);
  await fixture.checkout.refresh();
  return fixture;
}

void _expectNoChildShell() {
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

void _expectLockedPlans() {
  expect(find.byType(SubscriptionScreen), findsOneWidget);
  expect(find.text('Monthly'), findsOneWidget);
  expect(find.text('Yearly'), findsOneWidget);
  expect(find.byKey(const Key('subscription-back')), findsNothing);
  expect(find.byType(BackButton), findsNothing);
  expect(find.byTooltip('Back'), findsNothing);
  expect(find.byTooltip('Close'), findsNothing);
  _expectNoChildShell();
}

Finder _menuOption(String label) => find.descendant(
  of: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
  matching: find.text(label),
);

Future<void> _openAccountOptions(WidgetTester tester) async {
  // A short error toast can finish before this intentional account action.
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('subscription-account-actions')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    paidContentAccessState.selectScope(null);
    featureViewStateCache.clearIdentity();
    for (final channel in [
      'flutter_timezone',
      'dexterous.com/flutter/local_notifications',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async =>
                throw PlatformException(code: 'unavailable_in_fixture'),
          );
    }
  });
  tearDown(() {
    paidContentAccessState.selectScope(null);
    for (final channel in [
      'flutter_timezone',
      'dexterous.com/flutter/local_notifications',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

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
    testWidgets('unpaid direct route $route stays on real locked plans', (
      tester,
    ) async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app(route));
      await _pump(tester);
      _expectLockedPlans();
      await tester.binding.handlePopRoute();
      await _pump(tester);
      _expectLockedPlans();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'unpaid plans expose no back and consume system, navigator and swipe escape',
    (tester) async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app(AppRoutes.games));
      await _pump(tester);
      unawaited(
        fixture.navigator.currentState!.pushNamed(AppRoutes.subscription),
      );
      await _pump(tester);
      _expectLockedPlans();
      expect(find.byKey(const Key('subscription-check-access')), findsNothing);
      expect(find.byKey(const Key('subscription-manage')), findsNothing);
      expect(
        find.byKey(const Key('subscription-billing-details')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('subscription-privacy-policy')),
        findsOneWidget,
      );
      final route = fixture.topRoute;
      expect(await fixture.navigator.currentState!.maybePop(), isTrue);
      await tester.binding.handlePopRoute();
      await tester.dragFrom(const Offset(1, 280), const Offset(650, 0));
      await _pump(tester);
      expect(fixture.topRoute, route);
      _expectLockedPlans();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final offline in [false, true]) {
    testWidgets(
      '${offline ? 'offline' : 'unknown'} stays neutral with automatic resume refresh and account options',
      (tester) async {
        final fixture = await _fixture(
          state: SandboxAccessState.unknown,
          offline: offline,
        );
        addTearDown(fixture.dispose);
        await tester.pumpWidget(fixture.app(AppRoutes.home));
        await _pump(tester);
        _expectLockedPlans();
        expect(find.textContaining('No active subscription.'), findsNothing);
        expect(fixture.checkout.canOpen, isFalse);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('subscription-parent-continue')),
              )
              .onPressed,
          isNull,
        );
        expect(find.text('Check access'), findsNothing);
        expect(find.text('Manage subscription'), findsNothing);
        final reads = fixture.repository.reads;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await _pump(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _pump(tester);
        expect(fixture.repository.reads, greaterThan(reads));
        await _openAccountOptions(tester);
        for (final control in [
          'Sign out',
          'Privacy Policy',
          'Password help',
          'Delete account',
        ]) {
          expect(_menuOption(control), findsOneWidget);
        }
        fixture.navigator.currentState!.pop();
        await _pump(tester);
        _expectLockedPlans();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final complimentary in [false, true]) {
    testWidgets(
      '${complimentary ? 'complimentary' : 'paid'} canonical access still browses normally',
      (tester) async {
        final fixture = await _fixture(
          state: SandboxAccessState.paid,
          until: DateTime.now().toUtc().add(const Duration(hours: 1)),
          complimentary: complimentary,
        );
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.app(AppRoutes.home, paidSentinel: true),
        );
        await _pump(tester);
        expect(fixture.checkout.canBrowse, isTrue);
        expect(find.text('Paid child content'), findsOneWidget);
        expect(find.byKey(const Key('bottom-nav-main-dock')), findsOneWidget);
        expect(find.byType(SubscriptionScreen), findsNothing);
        expect(fixture.checkout.canOpen, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test('expired paid proof cannot browse', () async {
    final fixture = await _fixture(
      state: SandboxAccessState.paid,
      until: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
    );
    addTearDown(fixture.dispose);
    expect(fixture.checkout.canBrowse, isFalse);
  });

  testWidgets(
    'identity switch hides old paid pixels while secure owner read is delayed',
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
        _expectLockedPlans();
      } finally {
        repository.state = SandboxAccessState.unpaid;
        release.complete();
        await _pump(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'locked plans and account options stay reachable at 320px and 2.2x text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.app(AppRoutes.subscription, textScale: 2.2),
      );
      await _pump(tester);
      _expectLockedPlans();
      await _openAccountOptions(tester);
      for (final control in [
        'Sign out',
        'Privacy Policy',
        'Password help',
        'Delete account',
      ]) {
        final option = _menuOption(control);
        await tester.ensureVisible(option);
        expect(option.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'restored child adult gate has no back and keeps recovery available',
    (tester) async {
      final fixture = await _fixture(restored: true);
      addTearDown(fixture.dispose);
      expect(fixture.checkout.requiresParentGate, isTrue);
      await tester.pumpWidget(fixture.app(AppRoutes.subscription));
      await _pump(tester);
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      expect(find.byKey(const Key('adult-gate-password')), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      final route = fixture.topRoute;
      await tester.binding.handlePopRoute();
      await tester.dragFrom(const Offset(1, 280), const Offset(650, 0));
      await _pump(tester);
      expect(fixture.topRoute, route);
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      _expectNoChildShell();
      await _openAccountOptions(tester);
      await tester.tap(_menuOption('Password help'));
      await _pump(tester);
      expect(find.byType(PasswordResetScreen), findsOneWidget);
      _expectNoChildShell();
      await tester.binding.handlePopRoute();
      await _pump(tester);
      expect(find.byKey(const Key('adult-gate-screen')), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      _expectNoChildShell();
      final nativeCleanup = Completer<Object?>();
      var cleanupStarted = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_timezone'),
        (_) {
          cleanupStarted = true;
          return nativeCleanup.future;
        },
      );
      await _openAccountOptions(tester);
      await tester.tap(_menuOption('Sign out'));
      await _pump(tester);
      expect(await fixture.auth.restoreSession(), isNull);
      expect(cleanupStarted, isTrue);
      expect(find.byKey(const Key('adult-gate-screen')), findsNothing);
      nativeCleanup.completeError(
        PlatformException(code: 'unavailable_in_fixture'),
      );
      await _pump(tester);
      expect(fixture.topRoute, AppRoutes.login);
      _expectNoChildShell();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'locked plans allow privacy and recovery then return to the same locked plans',
    (tester) async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app(AppRoutes.subscription));
      await _pump(tester);
      await _openAccountOptions(tester);
      await tester.tap(_menuOption('Privacy Policy'));
      await _pump(tester);
      expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
      _expectNoChildShell();
      await tester.binding.handlePopRoute();
      await _pump(tester);
      _expectLockedPlans();
      await _openAccountOptions(tester);
      await tester.tap(_menuOption('Password help'));
      await _pump(tester);
      expect(find.byType(PasswordResetScreen), findsOneWidget);
      _expectNoChildShell();
      await tester.binding.handlePopRoute();
      await _pump(tester);
      _expectLockedPlans();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final signedIn in [true, false]) {
    testWidgets(
      'explicit sign out reaches login with ${signedIn ? 'owned' : 'already cleared'} session',
      (tester) async {
        final fixture = await _fixture(signedIn: signedIn);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(fixture.app(AppRoutes.subscription));
        await _pump(tester);
        _expectLockedPlans();
        await _openAccountOptions(tester);
        await tester.tap(_menuOption('Sign out'));
        await _pump(tester);
        expect(fixture.topRoute, AppRoutes.login);
        expect(await fixture.auth.restoreSession(), isNull);
        _expectNoChildShell();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'delete-account confirmation is reachable without exposing child screens',
    (tester) async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app(AppRoutes.subscription));
      await _pump(tester);
      await _openAccountOptions(tester);
      await tester.tap(_menuOption('Delete account'));
      await _pump(tester);
      expect(find.text('Permanently delete family account?'), findsOneWidget);
      expect(find.byKey(const Key('settings-delete-password')), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('settings-confirm-delete-account')),
      );
      await _pump(tester);
      expect(find.text('Enter your current password.'), findsOneWidget);
      expect(await fixture.auth.restoreSession(), isNotNull);
      _expectNoChildShell();
      await tester.tap(find.text('Keep account'));
      await _pump(tester);
      _expectLockedPlans();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
