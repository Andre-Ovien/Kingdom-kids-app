import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/splash/data/first_launch_store.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/features/splash/presentation/splash_screen.dart';

const _parent = ParentAccount(id: 'parent-1', email: 'grownup@example.com');
const _kai = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Kai',
  avatarKey: 'lion',
);

void main() {
  group('startup destination', () {
    test(
      'one-time onboarding review preserves the family session and next startup',
      () async {
        final sessions = MemoryAuthSessionStore();
        await sessions.writeSession(_session(profiles: const [_kai]));
        await sessions.writeSelectedKidId(_kai.id);
        final marker = _ReviewMarker();
        final auth = _CountingStartupAuth(sessions);
        final resolver = StartupDestinationResolver(
          authRepository: auth,
          firstLaunchStore: MemoryFirstLaunchStore(launched: true),
          onboardingReviewStore: marker,
          onboardingReviewId: 'physical-hosted-20261112',
        );
        expect((await resolver.resolve()).route, AppRoutes.onboarding);
        expect(auth.restores, 0);
        expect(auth.childReads, 0);
        expect((await resolver.resolve()).route, AppRoutes.home);
        expect((await sessions.readSession())!.parent.id, _parent.id);
        expect((await sessions.readSession())!.profiles, const [_kai]);
        expect(await sessions.readSelectedKidId(), _kai.id);
        expect(marker.claims, 2);
        final nextReview = StartupDestinationResolver(
          authRepository: auth,
          firstLaunchStore: MemoryFirstLaunchStore(launched: true),
          onboardingReviewStore: marker,
          onboardingReviewId: 'physical-hosted-20261112-next',
        );
        expect((await nextReview.resolve()).route, AppRoutes.onboarding);
        expect((await nextReview.resolve()).route, AppRoutes.home);
      },
    );

    test(
      'disabled, invalid and unavailable review markers keep normal startup',
      () async {
        for (final scenario in [
          (id: 'physical-hosted-20261112', allowed: false, fails: false),
          (id: '', allowed: true, fails: false),
          (id: 'invalid/id', allowed: true, fails: false),
          (id: 'physical-hosted-20261112', allowed: true, fails: true),
        ]) {
          final sessions = MemoryAuthSessionStore();
          await sessions.writeSession(_session(profiles: const [_kai]));
          await sessions.writeSelectedKidId(_kai.id);
          final marker = _ReviewMarker(fails: scenario.fails);
          final resolver = StartupDestinationResolver(
            authRepository: AuthRepository(sessionStore: sessions),
            firstLaunchStore: MemoryFirstLaunchStore(launched: true),
            onboardingReviewStore: marker,
            onboardingReviewId: scenario.id,
            allowOnboardingReview: scenario.allowed,
          );
          expect((await resolver.resolve()).route, AppRoutes.home);
          expect(await sessions.readSelectedKidId(), _kai.id);
          expect((await sessions.readSession())!.parent.id, _parent.id);
        }
      },
    );

    for (final scenario in [
      (
        name: 'selected child',
        profiles: const [_kai],
        selected: _kai.id,
        route: AppRoutes.home,
      ),
      (
        name: 'family profiles',
        profiles: const [_kai],
        selected: null,
        route: AppRoutes.profilePicker,
      ),
      (
        name: 'family without profiles',
        profiles: const <KidProfile>[],
        selected: null,
        route: AppRoutes.kidProfileSetup,
      ),
    ]) {
      test(
        'restores ${scenario.name} even when the first-launch flag is missing',
        () async {
          final sessionStore = MemoryAuthSessionStore();
          await sessionStore.writeSession(
            _session(profiles: scenario.profiles),
          );
          if (scenario.selected case final selected?) {
            await sessionStore.writeSelectedKidId(selected);
          }
          final launch = MemoryFirstLaunchStore();
          final resolver = StartupDestinationResolver(
            authRepository: AuthRepository(sessionStore: sessionStore),
            firstLaunchStore: launch,
          );
          final destination = await resolver.resolve();
          expect(destination.route, scenario.route);
          expect(launch.launched, isTrue);
          if (scenario.route == AppRoutes.profilePicker) {
            expect(destination.arguments, const [_kai]);
          }
        },
      );
    }

    test(
      'unreadable session data fails closed even with a missing launch flag',
      () async {
        final destination = await StartupDestinationResolver(
          authRepository: _UnreadableSessionRepository(),
          firstLaunchStore: MemoryFirstLaunchStore(),
        ).resolve();
        expect(destination.route, AppRoutes.login);
      },
    );

    test(
      'unreadable launch storage fails closed for a stored account',
      () async {
        final sessionStore = MemoryAuthSessionStore();
        await sessionStore.writeSession(_session(profiles: const [_kai]));
        await sessionStore.writeSelectedKidId(_kai.id);
        final destination = await StartupDestinationResolver(
          authRepository: AuthRepository(sessionStore: sessionStore),
          firstLaunchStore: _FailingLaunchStore(failRead: true),
        ).resolve();
        expect(destination.route, AppRoutes.login);
      },
    );

    test(
      'failure to restore the launch flag keeps the valid selected account',
      () async {
        final sessionStore = MemoryAuthSessionStore();
        await sessionStore.writeSession(_session(profiles: const [_kai]));
        await sessionStore.writeSelectedKidId(_kai.id);
        final destination = await StartupDestinationResolver(
          authRepository: AuthRepository(sessionStore: sessionStore),
          firstLaunchStore: _FailingLaunchStore(),
        ).resolve();
        expect(destination.route, AppRoutes.home);
      },
    );

    test('shows onboarding once on the true first launch', () async {
      final firstLaunchStore = MemoryFirstLaunchStore();
      final resolver = StartupDestinationResolver(
        authRepository: AuthRepository(sessionStore: MemoryAuthSessionStore()),
        firstLaunchStore: firstLaunchStore,
      );

      final destination = await resolver.resolve();

      expect(destination.route, AppRoutes.onboarding);
      expect(firstLaunchStore.launched, isTrue);
    });

    test('sends a returning signed-out parent to sign in', () async {
      final destination = await _resolver().resolve();

      expect(destination.route, AppRoutes.login);
    });

    test('restores home when the selected child still exists', () async {
      final sessionStore = MemoryAuthSessionStore();
      await sessionStore.writeSession(_session(profiles: const [_kai]));
      await sessionStore.writeSelectedKidId(_kai.id);

      final destination = await _resolver(sessionStore: sessionStore).resolve();

      expect(destination.route, AppRoutes.home);
    });

    test('opens the profile picker when no child is selected', () async {
      final sessionStore = MemoryAuthSessionStore();
      await sessionStore.writeSession(_session(profiles: const [_kai]));

      final destination = await _resolver(sessionStore: sessionStore).resolve();

      expect(destination.route, AppRoutes.profilePicker);
      expect(destination.arguments, const [_kai]);
    });

    test(
      'opens child setup when the signed-in family has no profiles',
      () async {
        final sessionStore = MemoryAuthSessionStore();
        await sessionStore.writeSession(_session());

        final destination = await _resolver(
          sessionStore: sessionStore,
        ).resolve();

        expect(destination.route, AppRoutes.kidProfileSetup);
      },
    );
  });

  group('approved static wordmark splash', () {
    testWidgets('shows the approved static wordmark through first arrival', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const SplashScreen(
            destinationResolver: _FixedResolver(
              StartupDestination(AppRoutes.onboarding),
            ),
          ),
          routes: {
            AppRoutes.onboarding: (_) =>
                const Scaffold(body: Text('first onboarding destination')),
          },
        ),
      );
      await tester.pump();

      final poster = tester.widget<Image>(
        find.byKey(const Key('splash-poster-image')),
      );
      expect(
        (poster.image as AssetImage).assetName,
        'assets/images/splash/static-periwinkle-title-v3.png',
      );
      expect(find.text('Kingdom Kids'), findsNothing);
      expect(find.text('BIG STORIES. LITTLE HEARTS.'), findsNothing);
      expect(find.byKey(const Key('splash-rainbow-mark')), findsNothing);
      expect(find.byKey(const Key('splash-brand-lockup')), findsNothing);
      expect(
        tester
            .widget<Scaffold>(find.byKey(const Key('cinematic-splash-screen')))
            .backgroundColor,
        kingdomKidsSplashBackgroundColor,
      );

      await tester.pump(const Duration(milliseconds: 5999));
      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('first onboarding destination'), findsOneWidget);
    });
  });

  group('cinematic splash', () {
    testWidgets('uses the short 1.8-second arrival for a returning route', (
      tester,
    ) async {
      final video = _FakeSplashVideoController(failInitialization: true);
      await tester.pumpWidget(
        KingdomKidsApp(
          initialRoute: AppRoutes.splash,
          splashDestinationResolver: const _FixedResolver(
            StartupDestination(AppRoutes.home),
          ),
          splashVideoControllerFactory: () => video,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);
      expect(find.text('Hey, explorer!'), findsNothing);
      expect(video.initializeCount, 0);

      await tester.pump(const Duration(milliseconds: 1799));
      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);
      expect(find.text('Hey, explorer!'), findsNothing);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Hey, explorer!'), findsOneWidget);
    });

    testWidgets('keeps the full 10.5-second arrival for onboarding', (
      tester,
    ) async {
      final video = _FakeSplashVideoController(failInitialization: true);
      await tester.pumpWidget(
        _testApp(
          destination: const StartupDestination(AppRoutes.onboarding),
          video: video,
          displayDuration: const Duration(milliseconds: 10500),
          returningDisplayDuration: const Duration(milliseconds: 1800),
        ),
      );
      await tester.pump();

      expect(video.initializeCount, 1);
      await tester.pump(const Duration(milliseconds: 10499));
      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.text('destination:${AppRoutes.onboarding}'), findsOneWidget);
    });

    testWidgets('plays onboarding video and then removes splash history', (
      tester,
    ) async {
      final video = _FakeSplashVideoController();
      await tester.pumpWidget(
        _testApp(
          destination: const StartupDestination(AppRoutes.onboarding),
          video: video,
          displayDuration: const Duration(milliseconds: 80),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);
      expect(find.byKey(const Key('fake-splash-video')), findsOneWidget);
      expect(find.byKey(const Key('splash-brand-lockup')), findsNothing);
      expect(video.playCount, 1);

      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();

      expect(find.text('destination:${AppRoutes.onboarding}'), findsOneWidget);
      expect(find.byKey(const Key('cinematic-splash-screen')), findsNothing);
      expect(video.disposeCount, 1);

      final popped = await tester.binding.handlePopRoute();
      await tester.pump();
      expect(popped, isFalse);
      expect(find.text('destination:${AppRoutes.onboarding}'), findsOneWidget);
    });

    testWidgets('uses the polished poster when video initialization fails', (
      tester,
    ) async {
      final video = _FakeSplashVideoController(failInitialization: true);
      await tester.pumpWidget(
        _testApp(
          destination: const StartupDestination(AppRoutes.onboarding),
          video: video,
          displayDuration: const Duration(milliseconds: 90),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('splash-poster-image')), findsOneWidget);
      expect(find.byKey(const Key('fake-splash-video')), findsNothing);
      expect(find.byKey(const Key('splash-brand-lockup')), findsNothing);

      await tester.pump(const Duration(milliseconds: 90));
      await tester.pump();

      expect(find.text('destination:${AppRoutes.onboarding}'), findsOneWidget);
      expect(video.disposeCount, 1);
    });

    testWidgets('times out a stuck video without delaying navigation', (
      tester,
    ) async {
      final video = _FakeSplashVideoController(hangInitialization: true);
      await tester.pumpWidget(
        _testApp(
          destination: const StartupDestination(AppRoutes.onboarding),
          video: video,
          displayDuration: const Duration(milliseconds: 70),
          videoInitializationTimeout: const Duration(milliseconds: 15),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byKey(const Key('splash-poster-image')), findsOneWidget);
      expect(video.disposeCount, 1);

      await tester.pump(const Duration(milliseconds: 54));
      await tester.pump();

      expect(find.text('destination:${AppRoutes.onboarding}'), findsOneWidget);
    });

    testWidgets('times out a stuck onboarding playback start', (tester) async {
      final video = _FakeSplashVideoController(hangPlaybackStart: true);
      await tester.pumpWidget(
        _testApp(
          destination: const StartupDestination(AppRoutes.onboarding),
          video: video,
          displayDuration: const Duration(milliseconds: 70),
          videoInitializationTimeout: const Duration(milliseconds: 15),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(video.initializeCount, 1);
      expect(video.playCount, 1);
      expect(video.disposeCount, 1);
      expect(find.byKey(const Key('splash-poster-image')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 54));
      await tester.pump();

      expect(find.text('destination:${AppRoutes.onboarding}'), findsOneWidget);
    });

    testWidgets('reduced motion stays static and never initializes video', (
      tester,
    ) async {
      final video = _FakeSplashVideoController();
      await tester.pumpWidget(
        _testApp(
          destination: const StartupDestination(AppRoutes.onboarding),
          video: video,
          displayDuration: const Duration(seconds: 1),
          reducedMotionDisplayDuration: const Duration(milliseconds: 50),
          disableAnimations: true,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('splash-poster-image')), findsOneWidget);
      expect(find.byKey(const Key('splash-brand-lockup')), findsNothing);
      expect(video.initializeCount, 0);

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(find.text('destination:${AppRoutes.onboarding}'), findsOneWidget);
    });

    testWidgets('blocks back navigation while startup is still resolving', (
      tester,
    ) async {
      await tester.pumpWidget(
        _testApp(
          destination: const StartupDestination(AppRoutes.login),
          video: _FakeSplashVideoController(failInitialization: true),
          displayDuration: const Duration(milliseconds: 120),
        ),
      );
      await tester.pump();

      final popped = await tester.binding.handlePopRoute();
      await tester.pump();

      expect(popped, isTrue);
      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
    });

    testWidgets('caps a stalled destination lookup at the short budget', (
      tester,
    ) async {
      final video = _FakeSplashVideoController(failInitialization: true);
      await tester.pumpWidget(
        _testApp(
          resolver: _NeverResolver(),
          video: video,
          displayDuration: const Duration(milliseconds: 60),
          destinationResolutionTimeout: const Duration(seconds: 1),
        ),
      );

      await tester.pump(const Duration(milliseconds: 59));
      expect(find.byKey(const Key('cinematic-splash-screen')), findsOneWidget);
      expect(video.initializeCount, 0);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.text('destination:${AppRoutes.login}'), findsOneWidget);
    });
  });
}

AuthSession _session({List<KidProfile> profiles = const []}) {
  return AuthSession(
    parent: _parent,
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    profiles: profiles,
  );
}

StartupDestinationResolver _resolver({MemoryAuthSessionStore? sessionStore}) {
  return StartupDestinationResolver(
    authRepository: AuthRepository(
      sessionStore: sessionStore ?? MemoryAuthSessionStore(),
    ),
    firstLaunchStore: MemoryFirstLaunchStore(launched: true),
  );
}

Widget _testApp({
  StartupDestination? destination,
  SplashDestinationResolver? resolver,
  required _FakeSplashVideoController video,
  required Duration displayDuration,
  Duration? returningDisplayDuration,
  Duration reducedMotionDisplayDuration = Duration.zero,
  Duration videoInitializationTimeout = const Duration(milliseconds: 20),
  Duration destinationResolutionTimeout = const Duration(seconds: 1),
  bool disableAnimations = false,
}) {
  return MaterialApp(
    initialRoute: AppRoutes.splash,
    builder: (context, child) {
      return MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      );
    },
    onGenerateRoute: (settings) {
      if (settings.name == AppRoutes.splash) {
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => SplashScreen(
            destinationResolver:
                resolver ??
                _FixedResolver(
                  destination ?? const StartupDestination(AppRoutes.login),
                ),
            videoControllerFactory: () => video,
            displayDuration: displayDuration,
            returningDisplayDuration:
                returningDisplayDuration ?? displayDuration,
            reducedMotionDisplayDuration: reducedMotionDisplayDuration,
            videoInitializationTimeout: videoInitializationTimeout,
            destinationResolutionTimeout: destinationResolutionTimeout,
          ),
        );
      }
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) =>
            Scaffold(body: Center(child: Text('destination:${settings.name}'))),
      );
    },
  );
}

class _UnreadableSessionRepository extends AuthRepository {
  @override
  Future<AuthSession?> restoreSession() async =>
      throw const FormatException('Corrupt local session');
}

class _FailingLaunchStore implements FirstLaunchStore {
  _FailingLaunchStore({this.failRead = false});
  final bool failRead;
  @override
  Future<bool> hasLaunchedBefore() async {
    if (failRead) throw StateError('Protected storage is unavailable');
    return false;
  }

  @override
  Future<void> markLaunched() async => throw StateError('Cannot persist flag');
}

class _FixedResolver implements SplashDestinationResolver {
  const _FixedResolver(this.destination);

  final StartupDestination destination;

  @override
  Future<StartupDestination> resolve() async => destination;
}

class _NeverResolver implements SplashDestinationResolver {
  @override
  Future<StartupDestination> resolve() =>
      Completer<StartupDestination>().future;
}

class _FakeSplashVideoController implements SplashVideoController {
  _FakeSplashVideoController({
    this.failInitialization = false,
    this.hangInitialization = false,
    this.hangPlaybackStart = false,
  });

  final bool failInitialization;
  final bool hangInitialization;
  final bool hangPlaybackStart;
  bool _initialized = false;
  int initializeCount = 0;
  int playCount = 0;
  int disposeCount = 0;

  @override
  double get aspectRatio => 9 / 16;

  @override
  bool get isInitialized => _initialized;

  @override
  Widget buildView() {
    return const ColoredBox(key: Key('fake-splash-video'), color: Colors.blue);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }

  @override
  Future<void> initialize() async {
    initializeCount += 1;
    if (failInitialization) {
      throw StateError('Missing test video');
    }
    if (hangInitialization) {
      await Completer<void>().future;
    }
    _initialized = true;
  }

  @override
  Future<void> play() async {
    playCount += 1;
    if (hangPlaybackStart) {
      await Completer<void>().future;
    }
  }
}

class _ReviewMarker implements OnboardingReviewStore {
  _ReviewMarker({this.fails = false});
  final bool fails;
  int claims = 0;
  String? consumed;
  @override
  Future<bool> claim(String reviewId) async {
    claims++;
    if (fails) throw StateError('Storage unavailable');
    if (consumed == reviewId) return false;
    consumed = reviewId;
    return true;
  }
}

class _CountingStartupAuth extends AuthRepository {
  _CountingStartupAuth(AuthSessionStore store) : super(sessionStore: store);
  int restores = 0, childReads = 0;
  @override
  Future<AuthSession?> restoreSession() {
    restores++;
    return super.restoreSession();
  }

  @override
  Future<KidProfile?> currentKid() {
    childReads++;
    return super.currentKid();
  }
}
