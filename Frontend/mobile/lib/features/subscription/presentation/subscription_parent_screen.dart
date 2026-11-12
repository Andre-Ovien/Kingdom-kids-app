import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/data/auth_repository.dart';
import '../../auth/presentation/adult_gate.dart';
import '../data/sandbox_checkout.dart';
import '../data/hosted_subscription_controller.dart';
import 'subscription_access_screen.dart';
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
  });

  final SandboxCheckoutConfiguration configuration;
  final AuthRepository? authRepository;
  final SandboxContentAccessRepository? accessRepository;
  final SandboxBrowserLauncher? browserLauncher;

  @override
  State<SubscriptionParentScreen> createState() =>
      _SubscriptionParentScreenState();
}

class _SubscriptionParentScreenState extends State<SubscriptionParentScreen>
    with WidgetsBindingObserver {
  AuthenticatedSandboxContentAccessRepository? _repository;
  SandboxCheckoutController? _checkout;
  bool _preparingHostedStack = false;
  void _prepareHostedStack(HostedSubscriptionController controller) {
    if (_preparingHostedStack ||
        controller.canBrowse ||
        ModalRoute.of(context)?.settings.arguments ==
            HostedPlansBackStack.prepared) {
      return;
    }
    _preparingHostedStack = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _preparingHostedStack = false;
      if (!controller.canBrowse &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        openHostedSubscriptionPlans(context);
      }
    });
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
    if (widget.configuration.isHostedProductionEnabled) {
      final controller = HostedSubscriptionScope.maybeOf(context);
      return controller == null
          ? const Scaffold(
              body: Center(child: Text('Checkout is unavailable.')),
            )
          : AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                _prepareHostedStack(controller);
                return controller.requiresParentGate
                    ? AdultGate(
                        repository:
                            widget.authRepository ??
                            HostedSubscriptionScope.authOf(context),
                        title: 'Subscription plans',
                        reason: 'A parent needs to open this area.',
                        protectedBuilder: (_) => HostedSubscriptionParentView(
                          controller: controller,
                        ),
                      )
                    : HostedSubscriptionParentView(controller: controller);
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
