import 'package:flutter/material.dart';
import '../../../core/network/paid_content_access_state.dart';
import 'subscription_parent_screen.dart';
import 'hosted_subscription_scope.dart';

class HostedPaidRouteBoundary extends StatelessWidget {
  const HostedPaidRouteBoundary({
    required this.child,
    this.childContext = true,
    super.key,
  });
  final bool childContext;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final controller = HostedSubscriptionScope.maybeOf(context);
    if (controller == null) return child;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, paidContentAccessState]),
      builder: (context, _) {
        if (controller.canBrowse) {
          if (childContext) controller.noteChildContext();
          return child;
        }
        return SubscriptionParentScreen(
          configuration: controller.configuration,
          authRepository: HostedSubscriptionScope.authOf(context),
        );
      },
    );
  }
}
