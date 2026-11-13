import 'package:flutter/foundation.dart';

import '../../../app/router.dart';
import '../../auth/data/auth_repository.dart';
import '../../subscription/data/hosted_access_routing.dart';
import '../../subscription/data/hosted_startup_access_recovery.dart';
import 'first_launch_store.dart';

class StartupDestination {
  const StartupDestination(this.route, {this.arguments});

  final String route;
  final Object? arguments;
}

abstract interface class SplashDestinationResolver {
  Future<StartupDestination> resolve();
}

/// Chooses the first interactive screen from the saved family session.
/// A qualified hosted-payment build checks access before child navigation;
/// unavailable status keeps parent recovery and account controls reachable.
class StartupDestinationResolver implements SplashDestinationResolver {
  StartupDestinationResolver({
    AuthRepository? authRepository,
    HostedAccessRouting? accessRouting,
    FirstLaunchStore? firstLaunchStore,
    OnboardingReviewStore? onboardingReviewStore,
    this.onboardingReviewId = const String.fromEnvironment(
      'ONBOARDING_REVIEW_ID',
    ),
    this.allowOnboardingReview = !kReleaseMode,
  }) : _authRepository = authRepository ?? AuthRepository(),
       _accessRouting = accessRouting,
       _firstLaunchStore = firstLaunchStore ?? SecureFirstLaunchStore(),
       _reviewStore = onboardingReviewStore ?? SecureOnboardingReviewStore();

  final AuthRepository _authRepository;
  final HostedAccessRouting? _accessRouting;
  final FirstLaunchStore _firstLaunchStore;
  final OnboardingReviewStore _reviewStore;
  final String onboardingReviewId;
  final bool allowOnboardingReview;

  @override
  Future<StartupDestination> resolve() async {
    // The real main.dart may replay the welcome once for a deliberate physical
    // review build. This changes only routing and a separate marker; an owned
    // session, selected child, pending purchase and server progress stay intact.
    if (!kReleaseMode &&
        allowOnboardingReview &&
        RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(onboardingReviewId)) {
      try {
        if (await _reviewStore.claim(onboardingReviewId)) {
          return const StartupDestination(AppRoutes.onboarding);
        }
      } catch (_) {
        // Locked review storage must retain the normal saved-session startup.
      }
    }
    bool returningInstallation;
    try {
      returningInstallation = await _firstLaunchStore.hasLaunchedBefore();
    } catch (_) {
      // If protected storage cannot be read, avoid exposing child content and
      // take the adult to the safe sign-in boundary.
      return const StartupDestination(AppRoutes.login);
    }

    try {
      final session = await _authRepository.restoreSession();
      if (session == null) {
        if (!returningInstallation) {
          await _markLaunchedIfPossible();
          return const StartupDestination(AppRoutes.onboarding);
        }
        return const StartupDestination(AppRoutes.login);
      }
      if (session.accessToken.trim().isEmpty) {
        return const StartupDestination(AppRoutes.login);
      }

      // Upgrades and reinstalls may preserve a verified account while losing
      // this installation flag. The account is stronger returning evidence.
      if (!returningInstallation) await _markLaunchedIfPossible();

      final accessRouting =
          _accessRouting ??
          HostedAccessRouting(authRepository: _authRepository);
      final origin = accessRouting.configuration.isHostedProductionEnabled
          ? await _authRepository.captureParentAccessOwner()
          : null;
      if (accessRouting.configuration.isHostedProductionEnabled &&
          (origin == null || origin.parentId != session.parent.id)) {
        return const StartupDestination(AppRoutes.login);
      }
      final requiresPlans = await accessRouting.requiresPlans();
      if (!await accessRouting.isCurrentParent(session.parent.id)) {
        return const StartupDestination(AppRoutes.login);
      }
      if (origin != null) {
        final current = await _authRepository.captureParentAccessOwner();
        if (current?.scope != origin.scope ||
            current?.parentId != origin.parentId) {
          return const StartupDestination(AppRoutes.login);
        }
      }
      if (requiresPlans) {
        return StartupDestination(
          AppRoutes.subscription,
          arguments: origin == null
              ? null
              : HostedStartupAccessRecovery(
                  parentId: origin.parentId,
                  ownerScope: origin.scope,
                ),
        );
      }

      final activeKid = await _authRepository.currentKid();
      if (activeKid != null) {
        return const StartupDestination(AppRoutes.home);
      }

      if (session.profiles.isEmpty) {
        return const StartupDestination(AppRoutes.kidProfileSetup);
      }
      return StartupDestination(
        AppRoutes.profilePicker,
        arguments: session.profiles,
      );
    } catch (_) {
      // Corrupt or inaccessible local session data should fail closed at the
      // parent sign-in screen, never as a raw storage error.
      return const StartupDestination(AppRoutes.login);
    }
  }

  Future<void> _markLaunchedIfPossible() async {
    try {
      await _firstLaunchStore.markLaunched();
    } catch (_) {
      // A flag write failure cannot block onboarding or an existing account.
    }
  }
}
