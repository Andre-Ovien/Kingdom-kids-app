import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/presentation/adult_gate.dart';
import '../data/hosted_startup_access_recovery.dart';
import '../data/hosted_subscription_controller.dart';
import '../data/sandbox_checkout.dart';
import 'subscription_account_actions.dart';
import 'subscription_screen.dart';
import 'hosted_subscription_scope.dart';
import 'hosted_subscription_parent_view.dart';

/// Preserves the existing password gate, including its background lock. Only
/// an explicitly opted-in payment configuration creates a coordinator.
class SubscriptionParentScreen extends StatefulWidget {
  const SubscriptionParentScreen({
    super.key,
    this.configuration = const SandboxCheckoutConfiguration(),
    this.authRepository,
    this.accessRepository,
    this.browserLauncher,
    this.startupRecovery,
  });

  final SandboxCheckoutConfiguration configuration;
  final AuthRepository? authRepository;
  final SandboxContentAccessRepository? accessRepository;
  final SandboxBrowserLauncher? browserLauncher;
  final HostedStartupAccessRecovery? startupRecovery;

  @override
  State<SubscriptionParentScreen> createState() =>
      _SubscriptionParentScreenState();
}

class _SubscriptionParentScreenState extends State<SubscriptionParentScreen>
    with WidgetsBindingObserver {
  AuthenticatedSandboxContentAccessRepository? _repository;
  SandboxCheckoutController? _checkout;
  bool _resumeScheduled = false, _resuming = false, _recoveryObsolete = false;

  bool _canResumeStartup(HostedSubscriptionController controller) =>
      !_recoveryObsolete &&
      controller.canBrowse &&
      controller.isAuthorizationCurrent(controller.authorizationRevision) &&
      !controller.busy &&
      controller.state == HostedFlowState.idle &&
      (controller.pending == null ||
          controller.access?.complimentaryAccess == true);

  void _scheduleStartupResume(HostedSubscriptionController controller) {
    if (widget.startupRecovery == null ||
        _resumeScheduled ||
        _resuming ||
        !_canResumeStartup(controller) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _resumeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resumeScheduled = false;
      if (mounted) unawaited(_resumeStartup(controller));
    });
  }

  Future<void> _resumeStartup(HostedSubscriptionController controller) async {
    final ticket = widget.startupRecovery;
    if (ticket == null || _resuming) return;
    _resuming = true;
    var childChanged = false;
    final auth =
        widget.authRepository ??
        HostedSubscriptionScope.authOf(context) ??
        AuthRepository();
    Future<bool> current() async {
      if (!mounted ||
          widget.startupRecovery != ticket ||
          !_canResumeStartup(controller) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return false;
      }
      final owner = await auth.captureParentAccessOwner();
      if (!mounted) return false;
      if (owner?.scope != ticket.ownerScope ||
          owner?.parentId != ticket.parentId ||
          controller.ownerScope != ticket.ownerScope) {
        _recoveryObsolete = true;
        return false;
      }
      return _canResumeStartup(controller) &&
          ModalRoute.of(context)?.isCurrent == true;
    }

    try {
      if (!await current()) return;
      final childScope = await auth.featureCacheScope();
      final session = await auth.restoreSession();
      final child = await auth.currentKid();
      final latestChildScope = await auth.featureCacheScope();
      if (!await current()) return;
      if (childScope != latestChildScope) {
        childChanged = true;
        return;
      }
      if (session?.parent.id != ticket.parentId) return;
      final profiles = session!.profiles;
      if (profiles.any((profile) => profile.parentId != ticket.parentId)) {
        return;
      }
      final route = child?.parentId == ticket.parentId
          ? AppRoutes.home
          : profiles.isEmpty
          ? AppRoutes.kidProfileSetup
          : AppRoutes.profilePicker;
      // Only this startup ticket is consumed. Parent-area authorization and
      // any pending checkout ledger remain untouched.
      _recoveryObsolete = true;
      if (!mounted) return;
      unawaited(
        Navigator.of(context).pushNamedAndRemoveUntil(
          route,
          (_) => false,
          arguments: route == AppRoutes.profilePicker ? profiles : null,
        ),
      );
    } catch (_) {
      // A failed owner/storage check retains the safe parent boundary.
    } finally {
      _resuming = false;
      if (mounted && childChanged) _scheduleStartupResume(controller);
    }
  }

  @override
  void initState() {
    super.initState();
    final configuration = widget.configuration;
    if (configuration.isEnabled && !configuration.isHostedProductionEnabled) {
      final repository =
          widget.accessRepository ??
          (_repository = AuthenticatedSandboxContentAccessRepository(
            configuration: configuration,
            authRepository: widget.authRepository,
          ));
      _checkout = SandboxCheckoutController(
        configuration: configuration,
        repository: repository,
        launcher: widget.browserLauncher,
      );
      WidgetsBinding.instance.addObserver(this);
      unawaited(_checkout!.refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkout?.resume());
    } else {
      _checkout?.background();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkout?.dispose();
    _repository?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = HostedSubscriptionScope.maybeOf(context);
    if (widget.configuration.isHostedProductionEnabled || controller != null) {
      return controller == null
          ? const Scaffold(
              body: Center(child: Text('Checkout is unavailable.')),
            )
          : AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                _scheduleStartupResume(controller);
                return PopScope(
                  canPop: controller.canBrowse,
                  child: controller.requiresParentGate
                      ? AdultGate(
                          repository:
                              widget.authRepository ??
                              HostedSubscriptionScope.authOf(context),
                          title: 'Subscription plans',
                          showBackButton: controller.canBrowse,
                          actions: controller.canBrowse
                              ? null
                              : const SubscriptionAccountActions(),
                          reason: 'A parent needs to open this area.',
                          protectedBuilder: (_) => HostedSubscriptionParentView(
                            controller: controller,
                          ),
                        )
                      : HostedSubscriptionParentView(controller: controller),
                );
              },
            );
    }
    return AdultGate(
      repository: widget.authRepository,
      title: 'Subscription plans',
      reason: 'Enter the parent password to view subscription plans.',
      protectedBuilder: (_) => SubscriptionScreen(sandboxCheckout: _checkout),
    );
  }
}
