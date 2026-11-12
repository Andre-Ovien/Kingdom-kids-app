import '../../../app/router.dart';
import '../../auth/data/auth_repository.dart';
import '../../subscription/data/hosted_access_routing.dart';
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
    FirstLaunchStore? firstLaunchStore,
  }) : _authRepository = authRepository ?? AuthRepository(),
       _firstLaunchStore = firstLaunchStore ?? SecureFirstLaunchStore();

  final AuthRepository _authRepository;
  final FirstLaunchStore _firstLaunchStore;

  @override
  Future<StartupDestination> resolve() async {
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

      final accessRouting = HostedAccessRouting(
        authRepository: _authRepository,
      );
      final requiresPlans = await accessRouting.requiresPlans();
      if (!await accessRouting.isCurrentParent(session.parent.id)) {
        return const StartupDestination(AppRoutes.login);
      }
      if (requiresPlans) {
        return const StartupDestination(AppRoutes.subscription);
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
