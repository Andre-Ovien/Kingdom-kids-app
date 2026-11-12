import '../../auth/data/auth_repository.dart';
import 'hosted_subscription_repository.dart';
import 'sandbox_checkout.dart';

/// A new hosted-profile session must establish access before child selection.
/// Unknown status goes to plans/recovery; it never becomes an unpaid claim.
class HostedAccessRouting {
  HostedAccessRouting({
    this.configuration = const SandboxCheckoutConfiguration(),
    AuthRepository? authRepository,
    HostedSubscriptionRepository? repository,
  }) : _auth = authRepository ?? AuthRepository(),
       _repository = repository;
  final SandboxCheckoutConfiguration configuration;
  final AuthRepository _auth;
  final HostedSubscriptionRepository? _repository;
  Future<bool> isCurrentParent(String parentId) async {
    if (!configuration.isHostedProductionEnabled) return true;
    return (await _auth.captureParentAccessOwner())?.parentId == parentId;
  }

  Future<bool> requiresPlans() async {
    if (!configuration.isHostedProductionEnabled) return false;
    final owned = _repository == null
        ? HttpHostedSubscriptionRepository(
            configuration: configuration,
            authRepository: _auth,
          )
        : null;
    try {
      final result = await (_repository ?? owned!).access();
      return result.access.state != SandboxAccessState.paid ||
          !result.access.enforcementEnabled ||
          !result.access.routingEnabled;
    } catch (_) {
      return true;
    } finally {
      owned?.dispose();
    }
  }
}
