import 'package:flutter/material.dart';

import '../../app/router.dart';
import 'liquid_glass.dart';

class FloatingLiquidNav extends StatelessWidget {
  const FloatingLiquidNav({required this.selectedRoute, super.key});

  final String selectedRoute;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final profileSelected = selectedRoute == AppRoutes.profile;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, bottomPadding + 10),
      child: Row(
        children: [
          Expanded(
            child: LiquidGlass(
              borderRadius: 42,
              padding: const EdgeInsets.all(7),
              opacity: 0.02,
              blur: 28,
              borderOpacity: 0.34,
              child: Row(
                children: [
                  _LiquidNavItem(
                    icon: Icons.home_rounded,
                    label: 'Home',
                    route: AppRoutes.home,
                    selectedRoute: selectedRoute,
                  ),
                  _LiquidNavItem(
                    icon: Icons.auto_stories_rounded,
                    label: 'Stories',
                    route: AppRoutes.stories,
                    selectedRoute: selectedRoute,
                  ),
                  _LiquidNavItem(
                    icon: Icons.play_circle_rounded,
                    label: 'Watch',
                    route: AppRoutes.videos,
                    selectedRoute: selectedRoute,
                  ),
                  _LiquidNavItem(
                    icon: Icons.extension_rounded,
                    label: 'Games',
                    route: AppRoutes.games,
                    selectedRoute: selectedRoute,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          LiquidGlass(
            borderRadius: 34,
            opacity: 0.02,
            blur: 28,
            borderOpacity: 0.34,
            child: SizedBox.square(
              dimension: 66,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: profileSelected
                    ? null
                    : () =>
                          _openRoute(context, AppRoutes.profile, selectedRoute),
                child: Center(
                  child: Container(
                    width: 50,
                    height: 50,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: profileSelected
                            ? const Color(0xFFFF1F2D)
                            : Colors.white.withValues(
                                alpha: isDark ? 0.24 : 0.52,
                              ),
                        width: profileSelected ? 2 : 1,
                      ),
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/profile_avatar.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiquidNavItem extends StatelessWidget {
  const _LiquidNavItem({
    required this.icon,
    required this.label,
    required this.route,
    required this.selectedRoute,
  });

  final IconData icon;
  final String label;
  final String route;
  final String selectedRoute;

  @override
  Widget build(BuildContext context) {
    final selected = route == selectedRoute;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = selected
        ? const Color(0xFFFF1F2D)
        : isDark
        ? const Color(0xFFF8F3EF)
        : const Color(0xFF1F1208);

    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: selected
            ? null
            : () => _openRoute(context, route, selectedRoute),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(32),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 25),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  height: 1,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _openRoute(BuildContext context, String route, String selectedRoute) {
  Navigator.of(context).pushReplacementNamed(
    route,
    arguments: TabRouteTransition(fromRoute: selectedRoute),
  );
}
