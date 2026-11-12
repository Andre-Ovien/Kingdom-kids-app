import 'package:flutter/material.dart';
import '../../features/subscription/presentation/hosted_subscription_scope.dart';
import '../../core/network/paid_content_access_state.dart';

import 'floating_liquid_nav.dart';
import 'liquid_navigation_controller.dart';

/// One navigation surface lives above the replaceable Navigator routes.
class PersistentLiquidNavigationHost extends StatelessWidget {
  const PersistentLiquidNavigationHost({
    required this.controller,
    required this.child,
    super.key,
  });

  final LiquidNavigationController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final access = HostedSubscriptionScope.maybeOf(context);
    return LiquidNavigationScope(
      controller: controller,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          controller,
          ?access,
          paidContentAccessState,
        ]),
        child: child,
        builder: (context, navigator) => Stack(
          fit: StackFit.expand,
          children: [
            navigator!,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Offstage(
                offstage:
                    !(controller.visible &&
                        (access == null || access.canBrowse)),
                child: ExcludeSemantics(
                  excluding:
                      !(controller.visible &&
                          (access == null || access.canBrowse)),
                  child: IgnorePointer(
                    ignoring:
                        !(controller.visible &&
                            (access == null || access.canBrowse)),
                    child: TickerMode(
                      enabled:
                          (controller.visible &&
                          (access == null || access.canBrowse)),
                      child: LiquidNavigationSurface(
                        key: const Key('persistent-liquid-navigation'),
                        selectedRoute: controller.selectedRoute,
                        activeProfile: controller.activeProfile,
                        onSelect: (route) =>
                            (access == null || access.canBrowse) &&
                            controller.select(route),
                        currentRoute: () => controller.selectedRoute,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
