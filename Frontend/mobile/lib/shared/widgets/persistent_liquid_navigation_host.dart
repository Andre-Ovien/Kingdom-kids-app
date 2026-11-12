import 'package:flutter/material.dart';

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
  Widget build(BuildContext context) => LiquidNavigationScope(
    controller: controller,
    child: AnimatedBuilder(
      animation: controller,
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
              offstage: !controller.visible,
              child: ExcludeSemantics(
                excluding: !controller.visible,
                child: IgnorePointer(
                  ignoring: !controller.visible,
                  child: TickerMode(
                    enabled: controller.visible,
                    child: LiquidNavigationSurface(
                      key: const Key('persistent-liquid-navigation'),
                      selectedRoute: controller.selectedRoute,
                      activeProfile: controller.activeProfile,
                      onSelect: controller.select,
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
