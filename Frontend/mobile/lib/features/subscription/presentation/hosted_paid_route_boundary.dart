import 'package:flutter/material.dart';
import '../../../app/router.dart';
import '../../../core/network/paid_content_access_state.dart';
import '../data/sandbox_checkout.dart';
import 'hosted_subscription_scope.dart';

class HostedPaidRouteBoundary extends StatelessWidget {
  const HostedPaidRouteBoundary({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final controller = HostedSubscriptionScope.maybeOf(context);
    if (controller == null) return child;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, paidContentAccessState]),
      builder: (context, _) {
        final access = controller.access;
        if (!paidContentAccessState.isDenied &&
            access?.state == SandboxAccessState.paid &&
            access!.enforcementEnabled &&
            access.routingEnabled) {
          return child;
        }
        return Scaffold(
          key: const Key('hosted-access-required'),
          appBar: AppBar(title: const Text('Subscription')),
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (controller.checking) const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      controller.checking
                          ? 'Checking your subscription…'
                          : 'Choose a subscription to start exploring.',
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pushNamed(AppRoutes.subscription),
                      child: const Text('Subscription plans'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pushNamed(AppRoutes.parentalControls),
                      child: const Text('Parent account settings'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
