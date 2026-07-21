import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../features/auth/domain/kid_profile.dart';
import '../../features/auth/presentation/kid_profile_avatar.dart';

class FloatingLiquidNav extends StatelessWidget {
  const FloatingLiquidNav({
    required this.selectedRoute,
    this.activeProfile,
    super.key,
  });

  final String selectedRoute;
  final KidProfile? activeProfile;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    return _PlaygroundDiscoveryNav(
      selectedRoute: selectedRoute,
      activeProfile: activeProfile,
      bottomPadding: bottomPadding,
    );
  }
}

class _PlaygroundDiscoveryNav extends StatelessWidget {
  const _PlaygroundDiscoveryNav({
    required this.selectedRoute,
    required this.activeProfile,
    required this.bottomPadding,
  });

  static const _ink = Color(0xFF14131B);

  final String selectedRoute;
  final KidProfile? activeProfile;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final profileSelected = selectedRoute == AppRoutes.profile;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding + 9),
      child: Row(
        children: [
          Expanded(
            child: Container(
              key: const Key('bottom-nav-main-dock'),
              height: 69,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _ink,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  _PlaygroundNavItem(
                    icon: Icons.home_rounded,
                    label: 'Home',
                    route: AppRoutes.home,
                    selectedRoute: selectedRoute,
                    color: const Color(0xFFF5C84C),
                  ),
                  _PlaygroundNavItem(
                    icon: Icons.auto_stories_rounded,
                    label: 'Stories',
                    route: AppRoutes.stories,
                    selectedRoute: selectedRoute,
                    color: const Color(0xFF9B87F5),
                  ),
                  _PlaygroundNavItem(
                    icon: Icons.play_circle_rounded,
                    label: 'Watch',
                    route: AppRoutes.videos,
                    selectedRoute: selectedRoute,
                    color: const Color(0xFF62C7F2),
                  ),
                  _PlaygroundNavItem(
                    icon: Icons.extension_rounded,
                    label: 'Games',
                    route: AppRoutes.games,
                    selectedRoute: selectedRoute,
                    color: const Color(0xFFFF7A59),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            button: true,
            selected: profileSelected,
            label: 'Profile',
            child: GestureDetector(
              key: const Key('bottom-nav-profile'),
              behavior: HitTestBehavior.opaque,
              onTap: profileSelected
                  ? null
                  : () => _openRoute(context, AppRoutes.profile, selectedRoute),
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                width: 69,
                height: 69,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: profileSelected
                      ? const Color(0xFFB7A5FF)
                      : Colors.white,
                  border: Border.all(color: _ink, width: 2),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: activeProfile == null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Image.asset(
                          'assets/images/characters/kai-avatar.png',
                          fit: BoxFit.cover,
                        ),
                      )
                    : KidProfileAvatar(profile: activeProfile!, size: 54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaygroundNavItem extends StatelessWidget {
  const _PlaygroundNavItem({
    required this.icon,
    required this.label,
    required this.route,
    required this.selectedRoute,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String route;
  final String selectedRoute;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF14131B);
    final selected = route == selectedRoute;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: selected
              ? null
              : () => _openRoute(context, route, selectedRoute),
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? color : Colors.transparent,
              borderRadius: BorderRadius.circular(17),
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: selected ? ink : Colors.white, size: 23),
                  const SizedBox(height: 2),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                          color: selected ? ink : Colors.white,
                          fontSize: 9.5,
                          height: 1,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
